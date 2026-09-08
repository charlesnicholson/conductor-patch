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

    // MARK: - Patching

    /// Rewrites the cloned executable in place, then re-signs the bundle.
    static func patch(options: Patches.Options) throws {
        let executable = Paths.executable(in: Paths.work)
        var image = try Data(contentsOf: executable)
        Log.debug("read \(humanBytes(image.count)) executable")

        let macho = try MachOImage(image)
        let table = try AssetTable(macho)

        let entries = table.entries(in: image)
        guard entries.count > 500 else {
            throw PatchError(
                "found only \(entries.count) embedded assets; this does not look like the "
                    + "Tauri asset table")
        }
        Log.info("asset table: \(entries.count) entries")

        let before = decompressible(entries, in: image)
        Log.debug("\(before.count) of \(entries.count) entries decompress before patching")

        let script = try AssetTable.unique(
            entries,
            matching: #"^/assets/renderApp-[A-Za-z0-9_-]+\.js$"#,
            describedAs: "main script")

        var source = try Brotli.decompress(image[script.dataRange])
        Log.info(
            "\(script.key): \(humanBytes(script.dataLength)) compressed, "
                + "\(humanBytes(source.count)) source")

        try Patches.apply(to: &source, options: options)

        let recompressed = try Brotli.compress(source)
        Log.info(
            "recompressed to \(humanBytes(recompressed.count)) "
                + "(slot holds \(humanBytes(script.dataLength)))")
        try image.writeAsset(recompressed, to: script)

        // Verify against the freshly written image rather than the in-memory expectation:
        // this catches a bad length field or an off-by-one in the write, which is exactly
        // the class of bug that would otherwise surface as a blank window at runtime.
        let after = decompressible(table.entries(in: image), in: image)
        guard after == before else {
            let broken = before.subtracting(after).sorted()
            let appeared = after.subtracting(before).sorted()
            throw PatchError(
                "integrity check failed after patching. broken: \(broken.prefix(5)), "
                    + "new: \(appeared.prefix(5))")
        }
        Log.info("integrity: all \(after.count) decodable assets still decode")

        try image.write(to: executable, options: .atomic)
        try sign()
    }

    /// Keys of every entry whose blob decodes. A couple of unrelated constants pass the
    /// structural filter and never decode; comparing the set before and after keeps them
    /// from being mistaken for damage.
    private static func decompressible(_ entries: [AssetEntry], in image: Data) -> Set<String> {
        var good = Set<String>()
        for entry in entries where (try? Brotli.decompress(image[entry.dataRange])) != nil {
            good.insert(entry.key)
        }
        return good
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
