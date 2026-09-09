import Foundation

// MARK: - Errors

struct PatchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func fail(_ message: String) throws -> Never { throw PatchError(message) }

// MARK: - Logging
//
// Progress goes to stderr so `--no-launch`'s stdout path stays clean, to the status item
// when running as an agent, and always to a log file. `Log.observer` is how the AppKit
// side listens in.

enum Log {
    nonisolated(unsafe) static var verbose = false
    nonisolated(unsafe) static var observer: ((String) -> Void)?

    /// Everything, including debug lines, also lands in ~/Library/Logs/conductor-qol.log.
    ///
    /// In menu-bar mode stderr goes nowhere, and that is the mode the tool is normally run
    /// in -- so when a teardown step failed there was no trace of why. The file is where
    /// to look after the fact; it is capped by truncating when it grows past a few MB.
    static let logFile: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/conductor-qol.log")

    private static let file: FileHandle? = {
        let manager = FileManager.default
        if let size = (try? manager.attributesOfItem(atPath: logFile.path))?[.size] as? Int,
            size > 4 << 20
        {
            try? manager.removeItem(at: logFile)
        }
        if !manager.fileExists(atPath: logFile.path) {
            try? manager.createDirectory(
                at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            manager.createFile(atPath: logFile.path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: logFile.path) else { return nil }
        handle.seekToEndOfFile()
        let arguments = CommandLine.arguments.dropFirst().joined(separator: " ")
        handle.write(Data("\n--- conductor-qol pid \(getpid()) [\(arguments)]\n".utf8))
        return handle
    }()

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static let lock = NSLock()

    private static func emit(_ line: String, toStderr: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if toStderr { FileHandle.standardError.write(Data((line + "\n").utf8)) }
        file?.write(Data("\(clock.string(from: Date())) \(line)\n".utf8))
    }

    static func step(_ message: String) {
        emit("==> \(message)", toStderr: true)
        observer?(message)
    }

    static func info(_ message: String) {
        emit("    \(message)", toStderr: true)
    }

    static func debug(_ message: String) {
        emit("    [debug] \(message)", toStderr: verbose)
    }

    static func warn(_ message: String) {
        emit("warning: \(message)", toStderr: true)
    }
}

// MARK: - Profiling
//
// Wall-clock spans, printed as a table when --verbose is on. Deliberately crude: the
// interesting costs here are seconds apart, not microseconds.

final class Profile {
    nonisolated(unsafe) static let shared = Profile()

    private var spans: [(name: String, seconds: Double)] = []
    private let lock = NSLock()
    private let start = Date()

    @discardableResult
    func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let began = Date()
        defer {
            let elapsed = Date().timeIntervalSince(began)
            lock.lock()
            spans.append((name, elapsed))
            lock.unlock()
        }
        return try body()
    }

    func report() {
        guard Log.verbose else { return }
        lock.lock()
        let recorded = spans
        lock.unlock()
        guard !recorded.isEmpty else { return }

        let total = Date().timeIntervalSince(start)
        let accounted = recorded.reduce(0) { $0 + $1.seconds }
        var lines = ["", "  profile"]
        for span in recorded.sorted(by: { $0.seconds > $1.seconds }) {
            let share = total > 0 ? span.seconds / total * 100 : 0
            lines.append(
                String(
                    format: "    %-28@ %7.3fs  %5.1f%%", span.name as NSString, span.seconds, share)
            )
        }
        lines.append(String(format: "    %-28@ %7.3fs", "unaccounted" as NSString, total - accounted))
        lines.append(String(format: "    %-28@ %7.3fs", "TOTAL" as NSString, total))
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}

// MARK: - Little-endian scalar access
//
// The Mach-O structures and the asset table are all packed little-endian, and none of the
// fields are guaranteed aligned once you are indexing into a byte image, hence
// loadUnaligned throughout.

extension Data {
    func u32(at offset: Int) -> UInt32 {
        precondition(offset >= 0 && offset + 4 <= count, "u32 out of bounds")
        return withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    func u64(at offset: Int) -> UInt64 {
        precondition(offset >= 0 && offset + 8 <= count, "u64 out of bounds")
        return withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
    }

    mutating func setU64(_ value: UInt64, at offset: Int) {
        precondition(offset >= 0 && offset + 8 <= count, "setU64 out of bounds")
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { source in
            replaceSubrange(offset ..< offset + 8, with: source)
        }
    }

    /// A fixed-width C string field, as Mach-O uses for segment and section names.
    func cString(at offset: Int, maxLength: Int) -> String {
        let slice = self[offset ..< offset + maxLength]
        let bytes = Array(slice.prefix { $0 != 0 })
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Subprocess

@discardableResult
func run(_ executable: String, _ arguments: [String], quiet: Bool = true) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw PatchError(
            "\(executable) \(arguments.joined(separator: " ")) exited "
                + "\(process.terminationStatus)\n\(output)")
    }
    if !quiet, !output.isEmpty { Log.info(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return output
}

// MARK: - Byte-level search and replace
//
// Everything the patcher edits is minified JS or CSS, so the edits are literal byte
// substitutions on UTF-8. Working in Data rather than String avoids paying grapheme
// breaking on an 11 MB buffer for no benefit.

extension Data {
    func occurrences(of needle: Data, in searchRange: Range<Int>? = nil) -> [Int] {
        var found: [Int] = []
        var cursor = searchRange?.lowerBound ?? startIndex
        let end = searchRange?.upperBound ?? endIndex
        while cursor < end, let hit = range(of: needle, in: cursor ..< end) {
            found.append(hit.lowerBound)
            cursor = hit.lowerBound + 1
        }
        return found
    }

    /// Replaces every occurrence of `needle`, requiring exactly `expected` of them.
    /// A miscount means the bundle moved under us, which must abort rather than
    /// half-apply: `context` names the edit in the error.
    mutating func replaceAll(
        _ needle: String, with replacement: String, expected: Int, context: String
    ) throws {
        let needleData = Data(needle.utf8)
        let hits = occurrences(of: needleData)
        guard hits.count == expected else {
            throw PatchError(
                "\(context): expected \(expected) occurrence(s) of \(needle.debugDescription), "
                    + "found \(hits.count). Conductor's bundle has changed; the patch needs "
                    + "re-anchoring.")
        }
        let replacementData = Data(replacement.utf8)
        for start in hits.reversed() {
            replaceSubrange(start ..< start + needleData.count, with: replacementData)
        }
        Log.debug("\(context): replaced \(hits.count)x \(needle.debugDescription)")
    }
}

// MARK: - Byte counts

func humanBytes(_ count: Int) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var value = Double(count)
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    return unit == 0
        ? "\(count) B" : String(format: "%.1f %@", value, units[unit])
}
