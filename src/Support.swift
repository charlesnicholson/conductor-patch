import Foundation

// MARK: - Errors

struct PatchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func fail(_ message: String) throws -> Never { throw PatchError(message) }

// MARK: - Logging
//
// Progress goes to stderr so `--print-path`-style stdout stays clean, and to the status
// item when running as an agent. `Log.observer` is how the AppKit side listens in.

enum Log {
    nonisolated(unsafe) static var verbose = false
    nonisolated(unsafe) static var observer: ((String) -> Void)?

    static func step(_ message: String) {
        FileHandle.standardError.write(Data("==> \(message)\n".utf8))
        observer?(message)
    }

    static func info(_ message: String) {
        FileHandle.standardError.write(Data("    \(message)\n".utf8))
    }

    static func debug(_ message: String) {
        guard verbose else { return }
        FileHandle.standardError.write(Data("    [debug] \(message)\n".utf8))
    }

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
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
