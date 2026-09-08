import Darwin
import Foundation

/// Where everything lives.
enum Paths {
    /// The pristine install. Never written to, except by an adopt-back after Conductor
    /// updates itself.
    static let source = URL(fileURLWithPath: "/Applications/Conductor.app")

    static let workDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/conductor-qol", isDirectory: true)

    /// The ephemeral patched clone. Same basename as the original so the app's own
    /// bundle-relative logic sees nothing unusual.
    static let work = workDirectory.appendingPathComponent("Conductor.app", isDirectory: true)

    static func executable(in bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/MacOS/conductor")
    }

    static func infoPlist(in bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Info.plist")
    }
}

/// The decoded frontend: every asset that decompresses, plus the ones the patches care
/// about, each located independently.
struct Frontend {
    let entries: [AssetEntry]
    let decoded: [(entry: AssetEntry, content: Data)]
    let usedFallback: Bool

    var decodableLabels: Set<String> { Set(decoded.map { $0.entry.label }) }

    func first(containingAny needles: [String]) -> (entry: AssetEntry, content: Data)? {
        for needle in needles {
            let target = Data(needle.utf8)
            if let hit = decoded.first(where: { $0.content.range(of: target) != nil }) {
                return hit
            }
        }
        return nil
    }

    /// The stylesheet. Filename first, content second -- Vite has always emitted one
    /// `.css` asset here, but the anchors mean a rename or a split does not matter.
    var stylesheet: (entry: AssetEntry, content: Data)? {
        decoded.first { $0.entry.key.hasSuffix(".css") }
            ?? first(containingAny: Patches.stylesheetAnchors)
    }

    /// The biggest chunk of application JavaScript, used only as the corpus for checking
    /// that the CSS rules still have something to match.
    var mainScript: (entry: AssetEntry, content: Data)? {
        decoded
            .filter { entry, content in
                entry.key.hasSuffix(".js")
                    || Patches.scriptAnchors.contains { content.range(of: Data($0.utf8)) != nil }
            }
            .max { $0.content.count < $1.content.count }
    }

    /// Whichever asset still contains the sidebar header assignment. Searched across all
    /// of them rather than assuming it lives in the main chunk, since Vite is free to
    /// split it out at any time.
    var sidebarHost: (entry: AssetEntry, content: Data)? {
        decoded.first { Patches.findHeader(in: $0.content) != nil }
    }
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

        try manager.removeItem(at: Paths.work)
        Log.debug("removed stale work bundle at \(path)")
    }

    /// APFS clone of the source bundle. Both paths are on the Data volume, so this is a
    /// copy-on-write clone rather than a 196 MB copy.
    static func cloneBundle() throws {
        try FileManager.default.createDirectory(
            at: Paths.workDirectory, withIntermediateDirectories: true)

        let result = clonefile(Paths.source.path, Paths.work.path, 0)
        guard result == 0 else {
            throw PatchError(
                "clonefile(\(Paths.source.path) -> \(Paths.work.path)) failed: "
                    + String(cString: strerror(errno)))
        }
    }

    static func bundleVersion(of bundle: URL) throws -> String {
        let data = try Data(contentsOf: Paths.infoPlist(in: bundle))
        guard
            let plist = try PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any],
            let version = plist["CFBundleShortVersionString"] as? String
        else {
            throw PatchError("\(bundle.lastPathComponent): no CFBundleShortVersionString")
        }
        return version
    }

    // MARK: - Discovery

    /// Decodes every embedded asset so each patch can find its own target.
    ///
    /// Keyed table first; if that yields neither a stylesheet nor a script, retry over raw
    /// `(pointer, length)` pairs, which assumes nothing about the record layout.
    static func locate(in image: Data, macho: MachOImage) throws -> Frontend {
        let table = try AssetTable(macho)
        Log.debug(
            "pointers: \(macho.hasChainedFixups ? "chained fixups" : "classic rebases"), "
                + "image base 0x\(String(macho.imageBase, radix: 16))")

        let entries = table.entries(in: image)
        Log.info("asset table: \(entries.count) keyed entries")

        var frontend = Frontend(
            entries: entries, decoded: decode(entries, in: image), usedFallback: false)

        if frontend.stylesheet == nil || frontend.mainScript == nil {
            Log.warn("keyed asset scan came up short; falling back to a raw slice scan")
            let slices = table.slices(in: image)
            Log.info("raw slice scan: \(slices.count) candidates")
            frontend = Frontend(
                entries: entries, decoded: decode(slices, in: image), usedFallback: true)
        }
        return frontend
    }

    private static func decode(_ entries: [AssetEntry], in image: Data)
        -> [(entry: AssetEntry, content: Data)]
    {
        entries.compactMap { entry in
            (try? Brotli.decompress(image[entry.dataRange])).map { (entry, $0) }
        }
    }

    // MARK: - Patching

    /// Rewrites the cloned executable in place, then re-signs the bundle.
    ///
    /// Returns what did and did not apply. Only a structural failure -- no assets at all,
    /// a blob that will not fit, a broken integrity sweep -- throws; a patch whose anchor
    /// has moved is reported and skipped so the rest still land.
    @discardableResult
    static func patch(options: Patches.Options) throws -> [PatchOutcome] {
        let executable = Paths.executable(in: Paths.work)
        var image = try Data(contentsOf: executable)
        Log.debug("read \(humanBytes(image.count)) executable")

        let macho = try MachOImage(image)
        let frontend = try locate(in: image, macho: macho)

        guard let corpus = frontend.mainScript?.content else {
            throw PatchError("could not find any application JavaScript in the asset table")
        }
        guard !frontend.decoded.contains(where: { Patches.alreadyPatched($0.content) }) else {
            throw PatchError("this image is already patched; refusing to patch it twice")
        }

        let before = frontend.decodableLabels
        Log.debug("\(before.count) of \(frontend.entries.count) entries decode before patching")

        var outcomes: [PatchOutcome] = []

        // Widths, via rules appended to the stylesheet.
        if var stylesheet = frontend.stylesheet?.content, let entry = frontend.stylesheet?.entry {
            let widthOutcomes = Patches.widen(
                stylesheet: &stylesheet, script: corpus, options: options)
            outcomes += widthOutcomes
            if widthOutcomes.contains(where: { $0.status != .disabled }) {
                try recompress(stylesheet, into: &image, at: entry)
            }
        } else {
            outcomes.append(
                PatchOutcome(
                    name: "chat column", status: .missing, detail: "no stylesheet asset found"))
        }

        // Sidebar repository names, in whichever chunk still carries the header.
        if options.qualifyRepoNames {
            if var host = frontend.sidebarHost?.content, let entry = frontend.sidebarHost?.entry {
                let outcome = Patches.qualifyRepoNames(in: &host, options: options)
                outcomes.append(outcome)
                if outcome.status == .applied { try recompress(host, into: &image, at: entry) }
            } else {
                outcomes.append(
                    PatchOutcome(
                        name: "repository names", status: .missing,
                        detail: "no asset contains the sidebar header assignment"))
            }
        } else {
            outcomes.append(
                PatchOutcome(
                    name: "repository names", status: .disabled, detail: "--no-repo-names"))
        }

        // Verify against the freshly written image rather than the in-memory expectation:
        // this catches a bad length field or an off-by-one in the write, the class of bug
        // that would otherwise surface as a blank window at runtime.
        let table = try AssetTable(macho)
        let after = Set(decode(table.entries(in: image), in: image).map { $0.entry.label })
        guard after == before else {
            throw PatchError(
                "integrity check failed after patching; broken assets: "
                    + "\(before.subtracting(after).sorted().prefix(5))")
        }
        Log.info("integrity: all \(after.count) decodable assets still decode")

        try image.write(to: executable, options: .atomic)
        try sign()
        return outcomes
    }

    private static func recompress(_ content: Data, into image: inout Data, at entry: AssetEntry)
        throws
    {
        let blob = try Brotli.compress(content)
        Log.info(
            "\(entry.label): \(humanBytes(content.count)) source -> \(humanBytes(blob.count)) "
                + "(slot holds \(humanBytes(entry.dataLength)))")
        try image.writeAsset(blob, to: entry)
    }

    // MARK: - Doctor

    /// Reports what the patcher can still find, without cloning, patching or signing.
    static func doctor() throws {
        let image = try Data(contentsOf: Paths.executable(in: Paths.source))
        let macho = try MachOImage(image)

        print("Conductor \(try bundleVersion(of: Paths.source))  \(Paths.source.path)")
        print("  pointers          \(macho.hasChainedFixups ? "chained fixups" : "classic rebases")")

        let frontend = try locate(in: image, macho: macho)
        print("  keyed entries     \(frontend.entries.count)")
        print("  decoded           \(frontend.decoded.count)")
        print("  slice fallback    \(frontend.usedFallback ? "USED" : "not needed")")

        func describe(_ label: String, _ located: (entry: AssetEntry, content: Data)?) {
            let padded = label.padding(toLength: 18, withPad: " ", startingAt: 0)
            guard let located else {
                print("  \(padded)NOT FOUND")
                return
            }
            print("  \(padded)\(located.entry.label)  \(humanBytes(located.content.count))")
        }
        describe("stylesheet", frontend.stylesheet)
        describe("main script", frontend.mainScript)
        describe("sidebar host", frontend.sidebarHost)

        print("\nanchors")
        guard let corpus = frontend.mainScript?.content else {
            print("  (no application JavaScript found; nothing to check)")
            return
        }
        for rule in Patches.transcriptRules + Patches.bubbleRules {
            let ok = Patches.evidenceFound(for: rule, in: corpus)
            print("  \(ok ? "ok     " : "MISSING")  \(rule.name): \(rule.selector)")
        }
        if let host = frontend.sidebarHost?.content, let header = Patches.findHeader(in: host) {
            print("  ok       repository names: \(header.repoVariable).name")
        } else {
            print("  MISSING  repository names: sidebar header assignment not found")
        }
    }

    // MARK: - Signing

    /// Ad-hoc re-sign, carrying the original entitlements and hardened runtime across.
    ///
    /// Unavoidable: touching a byte of the executable invalidates Conductor's Developer ID
    /// signature, and macOS will not run an arm64 binary whose signature does not verify.
    /// Deliberately not `--deep` -- the sidecars in Resources/bin (gh, watchexec,
    /// conductor-runtime) keep their own valid signatures and are only sealed by hash.
    private static func sign() throws {
        let entitlements = Paths.workDirectory.appendingPathComponent("entitlements.plist")
        try? FileManager.default.removeItem(at: entitlements)
        try run(
            "/usr/bin/codesign",
            ["-d", "--entitlements", entitlements.path, "--xml", Paths.source.path])

        var arguments = ["--force", "--sign", "-", "--options", "runtime"]
        if FileManager.default.fileExists(atPath: entitlements.path) {
            arguments += ["--entitlements", entitlements.path]
        } else {
            Log.warn("no entitlements recovered from \(Paths.source.path); signing without")
        }
        arguments.append(Paths.work.path)

        try run("/usr/bin/codesign", arguments)
        try run("/usr/bin/codesign", ["--verify", "--strict", Paths.work.path])
        Log.info("signed ad-hoc, hardened runtime preserved")
    }
}
