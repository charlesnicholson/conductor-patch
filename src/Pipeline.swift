import Darwin
import Foundation

/// Where everything lives.
enum Paths {
    /// The pristine install. Never written to, except by an adopt-back after Conductor
    /// updates itself. `--source` points it elsewhere, which is how a downloaded release
    /// gets checked with `--doctor` before it lands in /Applications.
    nonisolated(unsafe) static var source = URL(fileURLWithPath: "/Applications/Conductor.app")

    static let workDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/conductor-qol", isDirectory: true)

    /// The ephemeral patched clone. Same basename as the original so the app's own
    /// bundle-relative logic sees nothing unusual.
    static let work = workDirectory.appendingPathComponent("Conductor.app", isDirectory: true)

    /// Whatever CFBundleExecutable names: `Conductor` for the Electron builds, `conductor`
    /// for the Tauri builds before them. Read rather than assumed, because Conductor's
    /// updater can install either over the other.
    static func executable(in bundle: URL) -> URL {
        let name = (try? infoDictionary(of: bundle))?["CFBundleExecutable"] as? String
        return bundle.appendingPathComponent("Contents/MacOS/\(name ?? "Conductor")")
    }

    static func infoPlist(in bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Info.plist")
    }

    static func asar(in bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Resources/app.asar")
    }

    static func infoDictionary(of bundle: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: infoPlist(in: bundle))
        guard
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else {
            throw PatchError("\(bundle.lastPathComponent): Info.plist is not a dictionary")
        }
        return plist
    }
}

/// The three files the patches need, each located independently.
struct Frontend {
    typealias Located = (file: AsarArchive.File, content: Data)

    let archive: AsarArchive

    /// Where the width rules are appended: the Tailwind stylesheet.
    let stylesheet: Located?
    /// The biggest chunk of application JavaScript; only the corpus for checking that the
    /// CSS rules still have something to match.
    let mainScript: Located?
    /// Whichever chunk still contains the sidebar header assignment -- searched for rather
    /// than assumed to be the main chunk, since Vite is free to split it out.
    let sidebarHost: Located?
}

enum Pipeline {
    // MARK: - Bundle lifecycle

    /// Deletes the work bundle, refusing anything that is not recognisably ours.
    ///
    /// This runs `rm -rf` on a path in a teardown handler, so it checks three independent
    /// things rather than trusting the constant: inside our cache directory, named
    /// Conductor.app, and containing the executable we expect.
    static func removeWorkBundle() throws {
        let manager = FileManager.default
        let path = Paths.work.standardizedFileURL.path
        guard manager.fileExists(atPath: path) else { return }

        let cacheRoot = Paths.workDirectory.standardizedFileURL.path
        guard path.hasPrefix(cacheRoot + "/"),
            Paths.work.lastPathComponent == "Conductor.app",
            manager.fileExists(atPath: Paths.executable(in: Paths.work).path)
        else {
            throw PatchError("refusing to delete \(path): does not look like our work bundle")
        }

        // Never yank a bundle out from under a live process: the executable is mapped, but
        // the helpers and the native server are exec'd from it on demand and would vanish.
        let running = Launcher.processes(under: Paths.work)
        guard running.isEmpty else {
            throw PatchError(
                "refusing to delete \(path): \(running.count) process(es) still running from it")
        }

        try manager.removeItem(at: Paths.work)
        Log.debug("removed stale work bundle at \(path)")
    }

    /// APFS clone of the source bundle. Both paths are on the Data volume, so this is a
    /// copy-on-write clone rather than a 400 MB copy.
    static func cloneBundle() throws {
        try FileManager.default.createDirectory(
            at: Paths.workDirectory, withIntermediateDirectories: true)

        let result = Profile.shared.measure("clone bundle") {
            clonefile(Paths.source.path, Paths.work.path, 0)
        }
        guard result == 0 else {
            throw PatchError(
                "clonefile(\(Paths.source.path) -> \(Paths.work.path)) failed: "
                    + String(cString: strerror(errno)))
        }
    }

    static func bundleVersion(of bundle: URL) throws -> String {
        guard let version = try Paths.infoDictionary(of: bundle)["CFBundleShortVersionString"]
            as? String
        else {
            throw PatchError("\(bundle.lastPathComponent): no CFBundleShortVersionString")
        }
        return version
    }

    // MARK: - Discovery

    static func openArchive(in bundle: URL) throws -> AsarArchive {
        let url = Paths.asar(in: bundle)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatchError(
                "\(bundle.path) has no Contents/Resources/app.asar. This tool patches the "
                    + "Electron builds of Conductor (0.95 and later); this does not look like one.")
        }
        return try Profile.shared.measure("read app.asar") { try AsarArchive(contentsOf: url) }
    }

    /// Finds the files the patches need among the frontend's ~3000, reading as few as
    /// possible: one stylesheet, the largest script, and -- usually that same script --
    /// whichever chunk holds the sidebar header.
    static func locate(in archive: AsarArchive) -> Frontend {
        Profile.shared.measure("locate assets") {
            let frontend = archive.files.filter { $0.path.hasPrefix("frontend/") }
            func bySize(_ suffix: String) -> [AsarArchive.File] {
                frontend.filter { $0.path.hasSuffix(suffix) }.sorted { $0.size > $1.size }
            }
            func raw(_ file: AsarArchive.File) -> Data {
                let start = archive.dataStart + file.offset
                return archive.bytes[start ..< start + file.size]
            }

            let stylesheets = bySize(".css")
            let stylesheet = (stylesheets.first {
                raw($0).range(of: Data(Patches.stylesheetAnchor.utf8)) != nil
            } ?? stylesheets.first).map { ($0, archive.contents(of: $0)) }

            let scripts = bySize(".js")
            let mainScript = scripts.first.map { ($0, archive.contents(of: $0)) }

            var sidebarHost: Frontend.Located?
            let anchor = Data(Patches.headerAnchor.utf8)
            for file in scripts where raw(file).range(of: anchor) != nil {
                let content = file.path == mainScript?.0.path
                    ? mainScript!.1 : archive.contents(of: file)
                if Patches.findHeader(in: content) != nil {
                    sidebarHost = (file, content)
                    break
                }
            }

            return Frontend(
                archive: archive, stylesheet: stylesheet, mainScript: mainScript,
                sidebarHost: sidebarHost)
        }
    }

    // MARK: - Patching

    /// Rewrites the cloned bundle's app.asar, points Info.plist at the new header, and
    /// re-signs the bundle.
    ///
    /// Returns what did and did not apply. Only a structural failure -- no frontend at
    /// all, a broken integrity check, a failed signature -- throws; a patch whose anchor
    /// has moved is reported and skipped so the rest still land. When it throws, the clone
    /// is left as shipped.
    @discardableResult
    static func patch(options: Patches.Options) throws -> [PatchOutcome] {
        let archive = try openArchive(in: Paths.work)
        Log.debug("app.asar: \(archive.files.count) files, \(humanBytes(archive.bytes.count))")
        let frontend = locate(in: archive)

        guard let corpus = frontend.mainScript?.content else {
            throw PatchError("could not find any application JavaScript in app.asar")
        }
        let targets = [frontend.stylesheet, frontend.mainScript, frontend.sidebarHost]
        guard !targets.contains(where: { $0.map { Patches.alreadyPatched($0.content) } ?? false })
        else {
            throw PatchError("this app.asar is already patched; refusing to patch it twice")
        }

        var outcomes: [PatchOutcome] = []
        var replacements: [String: Data] = [:]

        // Widths, via rules appended to the stylesheet.
        if var stylesheet = frontend.stylesheet?.content, let file = frontend.stylesheet?.file {
            let widthOutcomes = Patches.injectStyles(
                stylesheet: &stylesheet, script: corpus, options: options)
            outcomes += widthOutcomes
            if widthOutcomes.contains(where: { $0.status != .disabled }) {
                replacements[file.path] = stylesheet
            }
        } else {
            outcomes.append(
                PatchOutcome(
                    name: "chat column", status: .missing, detail: "no stylesheet found"))
        }

        // Sidebar repository names, in whichever chunk still carries the header.
        if options.qualifyRepoNames {
            if var host = frontend.sidebarHost?.content, let file = frontend.sidebarHost?.file {
                let outcome = Patches.qualifyRepoNames(in: &host, options: options)
                outcomes.append(outcome)
                if outcome.status == .applied { replacements[file.path] = host }
            } else {
                outcomes.append(
                    PatchOutcome(
                        name: "repository names", status: .missing,
                        detail: "no script contains the sidebar header assignment"))
            }
        } else {
            outcomes.append(
                PatchOutcome(
                    name: "repository names", status: .disabled, detail: "--no-repo-names"))
        }

        guard !replacements.isEmpty else {
            // Nothing to write, so nothing to re-sign: launch the release exactly as shipped,
            // Developer ID signature and all.
            Log.info("nothing to patch; leaving the clone as shipped")
            return outcomes
        }

        try install(replacements, from: archive)
        return outcomes
    }

    /// Writes the patched archive beside the clone, checks it, then swaps it in along with
    /// the new Info.plist hash and signature.
    ///
    /// Everything that could fail on a bad archive happens before the bundle is touched.
    /// From the swap onwards the shipped files are kept in a rollback directory, so a
    /// failed signature puts the clone back as it was -- which matters after an update
    /// that could not be adopted, when the clone is the only copy of the new release.
    private static func install(_ replacements: [String: Data], from archive: AsarArchive) throws {
        let entitlements = prepareEntitlements(of: Paths.work)

        let staged = Paths.workDirectory.appendingPathComponent("app.asar.staged")
        try? FileManager.default.removeItem(at: staged)
        defer { try? FileManager.default.removeItem(at: staged) }

        let headerHash = try Profile.shared.measure("write app.asar") {
            try archive.write(to: staged, replacing: replacements)
        }
        for (path, content) in replacements.sorted(by: { $0.key < $1.key }) {
            let original = archive.files.first { $0.path == path }?.size ?? 0
            Log.info(
                "\((path as NSString).lastPathComponent): \(humanBytes(original)) -> "
                    + humanBytes(content.count))
        }
        try Profile.shared.measure("integrity check") {
            try verify(original: archive, patched: staged, replacements: replacements, headerHash: headerHash)
        }

        let rollback = try Rollback(
            saving: [
                Paths.asar(in: Paths.work), Paths.infoPlist(in: Paths.work),
                Paths.executable(in: Paths.work),
                Paths.work.appendingPathComponent("Contents/_CodeSignature/CodeResources"),
            ])
        do {
            guard rename(staged.path, Paths.asar(in: Paths.work).path) == 0 else {
                throw PatchError("could not move the patched app.asar into place: "
                    + String(cString: strerror(errno)))
            }
            try setAsarHeaderHash(headerHash, in: Paths.work)
            try sign(entitlements: entitlements)
            rollback.discard()
        } catch {
            Log.warn("could not finish patching; restoring the clone as shipped")
            rollback.restore()
            throw error
        }
    }

    /// Proves the rewrite touched nothing it did not mean to, by reading the staged archive
    /// back as Electron will.
    ///
    /// The data region is compared byte for byte against the original's, every entry not
    /// being replaced must come back with the same offset, size and integrity, and every
    /// replacement must read back as exactly the content intended and match its own
    /// integrity hash. Cheap: it is a memcmp and a dictionary walk, not 3000 re-hashes.
    private static func verify(
        original: AsarArchive, patched url: URL, replacements: [String: Data], headerHash: String
    ) throws {
        let patched = try AsarArchive(contentsOf: url)
        guard patched.headerHash == headerHash else {
            throw PatchError("integrity check failed: header hash changed after writing")
        }

        let originalData = original.bytes[original.dataStart...]
        let carried = patched.bytes[patched.dataStart ..< patched.dataStart + originalData.count]
        guard originalData == carried else {
            throw PatchError("integrity check failed: the existing file data did not survive")
        }

        let before = Dictionary(uniqueKeysWithValues: original.files.map { ($0.path, $0) })
        let after = Dictionary(uniqueKeysWithValues: patched.files.map { ($0.path, $0) })
        guard Set(before.keys) == Set(after.keys) else {
            throw PatchError("integrity check failed: the set of files changed")
        }

        for (path, old) in before {
            let new = after[path]!
            if let content = replacements[path] {
                guard patched.contents(of: new) == content else {
                    throw PatchError("\(path): stored contents do not match what was written")
                }
                let expected = AsarArchive.integrity(
                    of: content,
                    blockSize: (patched.integrity(of: path)?["blockSize"] as? Int)
                        ?? AsarArchive.defaultBlockSize)
                guard patched.integrity(of: path) == expected else {
                    throw PatchError("\(path): integrity does not match the stored contents")
                }
            } else {
                guard old.offset == new.offset, old.size == new.size,
                    original.integrity(of: path) == patched.integrity(of: path)
                else {
                    throw PatchError("integrity check failed: \(path) moved or changed")
                }
            }
        }

        Log.info(
            "integrity: \(replacements.count) file(s) rewritten, "
                + "\(before.count - replacements.count) carried across unchanged")
    }

    /// Points Info.plist's `ElectronAsarIntegrity` at the rewritten header. With the
    /// embedded-integrity fuse on, a stale hash kills the app as it opens app.asar.
    private static func setAsarHeaderHash(_ hash: String, in bundle: URL) throws {
        let url = Paths.infoPlist(in: bundle)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard
            let plist = try PropertyListSerialization.propertyList(
                from: try Data(contentsOf: url), options: .mutableContainers, format: &format)
                as? NSMutableDictionary
        else {
            throw PatchError("Info.plist is not a dictionary")
        }
        guard
            let entry = (plist["ElectronAsarIntegrity"] as? NSDictionary)?["Resources/app.asar"]
                as? NSMutableDictionary
        else {
            Log.debug("Info.plist has no ElectronAsarIntegrity entry; nothing to update")
            return
        }
        entry["hash"] = hash
        try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
            .write(to: url, options: .atomic)
        Log.debug("ElectronAsarIntegrity -> \(hash)")
    }

    // MARK: - Doctor

    /// Reports what the patcher can still find, without cloning, patching or signing.
    /// With `dump`, also writes the files it found there, which is the raw material for
    /// re-anchoring against a new release.
    static func doctor(dump: URL? = nil) throws {
        print("Conductor \(try bundleVersion(of: Paths.source))  \(Paths.source.path)")
        let archive = try openArchive(in: Paths.source)
        print("  app.asar          \(archive.files.count) files, \(humanBytes(archive.bytes.count))")

        let frontend = locate(in: archive)
        func describe(_ label: String, _ located: Frontend.Located?) {
            let padded = label.padding(toLength: 18, withPad: " ", startingAt: 0)
            guard let located else {
                print("  \(padded)NOT FOUND")
                return
            }
            print("  \(padded)\(located.file.path)  \(humanBytes(located.content.count))")
        }
        describe("stylesheet", frontend.stylesheet)
        describe("main script", frontend.mainScript)
        describe("sidebar host", frontend.sidebarHost)

        if let dump {
            try FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true)
            var written = Set<String>()
            for located in [frontend.stylesheet, frontend.mainScript, frontend.sidebarHost] {
                guard let located else { continue }
                let name = (located.file.path as NSString).lastPathComponent
                guard written.insert(name).inserted else { continue }
                try located.content.write(to: dump.appendingPathComponent(name))
            }
            print("  dumped            \(written.sorted().joined(separator: ", ")) -> \(dump.path)")
        }

        print("\nanchors")
        guard let corpus = frontend.mainScript?.content else {
            print("  (no application JavaScript found; nothing to check)")
            return
        }
        for rule in Patches.allStyleRules {
            let ok = Patches.evidenceFound(for: rule, in: corpus)
            print("  \(ok ? "ok     " : "MISSING")  \(rule.name): \(rule.selector)")
        }
        if let host = frontend.sidebarHost?.content, let header = Patches.findHeader(in: host) {
            print("  ok       repository names: \(header.original)")
        } else {
            print("  MISSING  repository names: sidebar header assignment not found")
        }
    }

    // MARK: - Signing

    /// The release's own entitlements, read from the work bundle before anything touches
    /// it, plus `disable-library-validation`.
    ///
    /// Read from the clone because, when Conductor has just updated itself in place, it is
    /// a pristine copy of a release that is not the one in /Applications.
    ///
    /// The extra entitlement is what lets an ad-hoc main executable start at all. The
    /// hardened runtime's library validation only admits libraries signed by Apple or by
    /// the process's own team, an ad-hoc signature has no team, and Electron Framework --
    /// left alone, still signed by Conductor's -- is loaded by the main executable at
    /// launch.
    private static func prepareEntitlements(of bundle: URL) -> URL? {
        let file = Paths.workDirectory.appendingPathComponent("entitlements.plist")
        try? FileManager.default.removeItem(at: file)
        do {
            try run("/usr/bin/codesign", ["-d", "--entitlements", file.path, "--xml", bundle.path])
            let entitlements =
                (FileManager.default.fileExists(atPath: file.path)
                    ? try PropertyListSerialization.propertyList(
                        from: Data(contentsOf: file), format: nil) as? [String: Any]
                    : nil) ?? [:]
            var amended = entitlements
            amended["com.apple.security.cs.disable-library-validation"] = true
            try PropertyListSerialization.data(fromPropertyList: amended, format: .xml, options: 0)
                .write(to: file)
            Log.debug("entitlements: \(amended.keys.sorted().joined(separator: ", "))")
            return file
        } catch {
            Log.warn("could not read entitlements from \(bundle.path): \(error)")
            return nil
        }
    }

    /// Ad-hoc re-sign of the bundle's own code and resource seal.
    ///
    /// Unavoidable: app.asar and Info.plist are both sealed by Conductor's Developer ID
    /// signature. Deliberately not `--deep` -- the helper apps, Electron Framework, the
    /// native server and the sidecars in Resources/bin keep their own valid signatures and
    /// are only sealed by hash.
    ///
    /// Without recovered entitlements the hardened runtime is left off rather than applied
    /// bare: without `allow-jit` V8 cannot run under it.
    private static func sign(entitlements: URL?) throws {
        var arguments = ["--force", "--sign", "-"]
        if let entitlements {
            arguments += ["--options", "runtime", "--entitlements", entitlements.path]
        } else {
            Log.warn("no entitlements recovered; signing without the hardened runtime")
        }
        arguments.append(Paths.work.path)

        try Profile.shared.measure("codesign") { try run("/usr/bin/codesign", arguments) }
        try Profile.shared.measure("codesign --verify") {
            try run("/usr/bin/codesign", ["--verify", "--strict", Paths.work.path])
        }
        Log.info(
            entitlements == nil
                ? "signed ad-hoc" : "signed ad-hoc, hardened runtime and entitlements preserved")
    }
}

// MARK: - Rollback

/// The shipped copies of the files `install` overwrites, so a failure part-way through
/// can put them back. Each is cloned aside before anything is written, which on APFS costs
/// nothing until the original is replaced.
private struct Rollback {
    private let saved: [(original: URL, copy: URL)]
    private let directory: URL

    init(saving files: [URL]) throws {
        directory = Paths.workDirectory.appendingPathComponent("rollback", isDirectory: true)
        let manager = FileManager.default
        try? manager.removeItem(at: directory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        var saved: [(URL, URL)] = []
        for (index, file) in files.enumerated() where manager.fileExists(atPath: file.path) {
            let copy = directory.appendingPathComponent("\(index)-\(file.lastPathComponent)")
            guard clonefile(file.path, copy.path, 0) == 0 else {
                throw PatchError(
                    "could not save \(file.path) for rollback: " + String(cString: strerror(errno)))
            }
            saved.append((file, copy))
        }
        self.saved = saved
    }

    func restore() {
        for (original, copy) in saved where rename(copy.path, original.path) != 0 {
            Log.warn("could not restore \(original.path): \(String(cString: strerror(errno)))")
        }
        discard()
    }

    func discard() {
        try? FileManager.default.removeItem(at: directory)
    }
}
