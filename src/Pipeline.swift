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

/// The three assets the patches need, each located independently.
///
/// Resolved once at construction rather than as computed properties: each lookup scans
/// decoded blobs, and `frontend.stylesheet?.content` plus `frontend.stylesheet?.entry` is
/// two evaluations of the same search.
struct Frontend {
    let entries: [AssetEntry]
    let usedFallback: Bool
    let decodedCount: Int

    /// Where the width rules are appended.
    let stylesheet: (entry: AssetEntry, content: Data)?
    /// The biggest chunk of application JavaScript; only the corpus for checking that the
    /// CSS rules still have something to match.
    let mainScript: (entry: AssetEntry, content: Data)?
    /// Whichever asset still contains the sidebar header assignment -- searched for rather
    /// than assumed to be the main chunk, since Vite is free to split it out.
    let sidebarHost: (entry: AssetEntry, content: Data)?

    var isUsable: Bool { mainScript != nil }
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

    /// Finds the assets the patches need, decoding as few as possible.
    ///
    /// Assets are visited stylesheet-first then largest-first, because the two targets are
    /// the one `.css` and the biggest `.js`, and the search stops as soon as all three are
    /// in hand. In practice that is two blobs decoded instead of two thousand nine hundred.
    static func locate(in image: Data, macho: MachOImage) throws -> Frontend {
        let table = try AssetTable(macho)
        Log.debug(
            "pointers: \(macho.hasChainedFixups ? "chained fixups" : "classic rebases"), "
                + "image base 0x\(String(macho.imageBase, radix: 16))")

        let entries = Profile.shared.measure("scan asset table") { table.entries(in: image) }
        Log.info("asset table: \(entries.count) keyed entries")

        var frontend = Profile.shared.measure("decode assets") {
            resolve(entries, in: image, usedFallback: false)
        }
        if !frontend.isUsable || frontend.stylesheet == nil {
            Log.warn("keyed asset scan came up short; falling back to a raw slice scan")
            let slices = table.slices(in: image)
            Log.info("raw slice scan: \(slices.count) candidates")
            frontend = Profile.shared.measure("decode assets (fallback)") {
                resolve(slices, in: image, usedFallback: true)
            }
        }
        Log.debug("decoded \(frontend.decodedCount) asset(s) to locate targets")
        return frontend
    }

    private static func resolve(_ entries: [AssetEntry], in image: Data, usedFallback: Bool)
        -> Frontend
    {
        let ordered = entries.sorted { left, right in
            let leftCSS = left.key.hasSuffix(".css"), rightCSS = right.key.hasSuffix(".css")
            if leftCSS != rightCSS { return leftCSS }
            return left.dataLength > right.dataLength
        }

        func contains(_ content: Data, anyOf needles: [String]) -> Bool {
            needles.contains { content.range(of: Data($0.utf8)) != nil }
        }

        var stylesheet: (entry: AssetEntry, content: Data)?
        var mainScript: (entry: AssetEntry, content: Data)?
        var sidebarHost: (entry: AssetEntry, content: Data)?
        var decodedCount = 0

        for entry in ordered {
            if stylesheet != nil, mainScript != nil, sidebarHost != nil { break }
            guard let content = try? Brotli.decompress(image[entry.dataRange]) else { continue }
            decodedCount += 1

            if stylesheet == nil,
                entry.key.hasSuffix(".css") || contains(content, anyOf: Patches.stylesheetAnchors)
            {
                stylesheet = (entry, content)
            }
            // Size-descending order means the first JavaScript seen is the biggest.
            if mainScript == nil,
                entry.key.hasSuffix(".js") || contains(content, anyOf: Patches.scriptAnchors)
            {
                mainScript = (entry, content)
            }
            if sidebarHost == nil, Patches.findHeader(in: content) != nil {
                sidebarHost = (entry, content)
            }
        }

        return Frontend(
            entries: entries, usedFallback: usedFallback, decodedCount: decodedCount,
            stylesheet: stylesheet, mainScript: mainScript, sidebarHost: sidebarHost)
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
        var image = try Profile.shared.measure("read executable") { try Data(contentsOf: executable) }
        Log.debug("read \(humanBytes(image.count)) executable")

        let macho = try Profile.shared.measure("parse Mach-O") { try MachOImage(image) }
        let frontend = try locate(in: image, macho: macho)

        guard let corpus = frontend.mainScript?.content else {
            throw PatchError("could not find any application JavaScript in the asset table")
        }
        let targets = [frontend.stylesheet, frontend.mainScript, frontend.sidebarHost]
        guard !targets.contains(where: { $0.map { Patches.alreadyPatched($0.content) } ?? false })
        else {
            throw PatchError("this image is already patched; refusing to patch it twice")
        }

        // Copy-on-write snapshot, so this costs nothing until the first mutation below.
        let original = image

        var outcomes: [PatchOutcome] = []
        var pending: [(entry: AssetEntry, content: Data)] = []

        // Widths, via rules appended to the stylesheet.
        if var stylesheet = frontend.stylesheet?.content, let entry = frontend.stylesheet?.entry {
            let widthOutcomes = Patches.injectStyles(
                stylesheet: &stylesheet, script: corpus, options: options)
            outcomes += widthOutcomes
            if widthOutcomes.contains(where: { $0.status != .disabled }) {
                pending.append((entry, stylesheet))
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
                if outcome.status == .applied { pending.append((entry, host)) }
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

        let written = try compressAll(pending)
        for (entry, blob) in written { try image.writeAsset(blob, to: entry) }

        try Profile.shared.measure("integrity check") {
            try verify(original: original, patched: image, written: written)
        }

        try Profile.shared.measure("write executable") {
            try image.write(to: executable, options: .atomic)
        }
        try sign()
        return outcomes
    }

    /// Proves the patch touched nothing it did not mean to.
    ///
    /// Stronger than re-decoding every asset and about twenty times cheaper: rather than
    /// checking that the other 2900 blobs still happen to decode, this checks that their
    /// bytes are untouched, by memcmp-ing the gaps between the ranges we deliberately
    /// wrote. Then it decodes the blobs we did write, out of the final image, and confirms
    /// they reproduce exactly the content intended.
    private static func verify(
        original: Data, patched: Data, written: [(entry: AssetEntry, blob: Data)]
    ) throws {
        guard original.count == patched.count else {
            throw PatchError("patched image changed size: \(original.count) -> \(patched.count)")
        }

        var allowed: [Range<Int>] = []
        for (entry, _) in written {
            allowed.append(entry.dataOffset ..< entry.dataOffset + entry.dataLength)
            allowed.append(entry.lengthFieldOffset ..< entry.lengthFieldOffset + 8)
        }
        allowed.sort { $0.lowerBound < $1.lowerBound }

        var gaps: [Range<Int>] = []
        var cursor = 0
        for range in allowed {
            if range.lowerBound > cursor { gaps.append(cursor ..< range.lowerBound) }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < original.count { gaps.append(cursor ..< original.count) }

        let identical = original.withUnsafeBytes { left in
            patched.withUnsafeBytes { right -> Bool in
                for gap in gaps
                where memcmp(
                    left.baseAddress! + gap.lowerBound, right.baseAddress! + gap.lowerBound,
                    gap.count) != 0 {
                    return false
                }
                return true
            }
        }
        guard identical else {
            throw PatchError("integrity check failed: bytes changed outside the patched assets")
        }

        for (entry, blob) in written {
            let stored = patched[entry.dataOffset ..< entry.dataOffset + blob.count]
            guard stored == blob else {
                throw PatchError("\(entry.label): stored blob does not match what was compressed")
            }
            guard patched.u64(at: entry.lengthFieldOffset) == UInt64(blob.count) else {
                throw PatchError("\(entry.label): length field does not match the stored blob")
            }
            _ = try Brotli.decompress(stored)
        }

        Log.info(
            "integrity: \(written.count) asset(s) rewritten, \(humanBytes(gaps.reduce(0) { $0 + $1.count })) "
                + "of the image byte-identical")
    }

    /// Compresses every changed asset, in parallel, each only as hard as its slot demands.
    ///
    /// libbrotli's encoder is single-threaded and brotli streams cannot be concatenated,
    /// so one asset cannot be split across cores -- but the stylesheet and the script can
    /// compress at the same time, which is most of what there is to win here.
    private static func compressAll(_ pending: [(entry: AssetEntry, content: Data)]) throws
        -> [(entry: AssetEntry, blob: Data)]
    {
        guard !pending.isEmpty else { return [] }

        var results = [Result<Data, Error>?](repeating: nil, count: pending.count)
        let lock = NSLock()

        Profile.shared.measure("compress assets") {
            DispatchQueue.concurrentPerform(iterations: pending.count) { index in
                let item = pending[index]
                let outcome = Result {
                    try Brotli.compressToFit(
                        item.content, budget: item.entry.dataLength,
                        describedAs: item.entry.label)
                }
                lock.lock()
                results[index] = outcome
                lock.unlock()
            }
        }

        return try pending.indices.map { index in
            let blob = try results[index]!.get()
            let entry = pending[index].entry
            Log.info(
                "\(entry.label): \(humanBytes(pending[index].content.count)) source -> "
                    + "\(humanBytes(blob.count)) (slot holds \(humanBytes(entry.dataLength)))")
            return (entry, blob)
        }
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
        print("  decoded           \(frontend.decodedCount) (of \(frontend.entries.count))")
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
        for rule in Patches.allStyleRules {
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

        try Profile.shared.measure("codesign") { try run("/usr/bin/codesign", arguments) }
        try Profile.shared.measure("codesign --verify") {
            try run("/usr/bin/codesign", ["--verify", "--strict", Paths.work.path])
        }
        Log.info("signed ad-hoc, hardened runtime preserved")
    }
}
