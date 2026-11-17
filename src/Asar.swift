import CryptoKit
import Foundation

/// An Electron asar archive: Conductor's whole frontend and main process, in one file at
/// `Contents/Resources/app.asar`.
///
/// The layout is two Chromium pickles followed by the file data:
///
///     +0  u32 4                    size pickle: payload length
///     +4  u32 headerPickleLength   size pickle: payload
///     +8  u32 payloadLength        header pickle
///     +12 u32 jsonLength
///     +16 JSON, padded to 4 bytes
///     +8+headerPickleLength        file data; header offsets are relative to here
///
/// Two layers of integrity sit on top, and the shipped app enforces both
/// (`EnableEmbeddedAsarIntegrityValidation` is on):
///
/// - Info.plist's `ElectronAsarIntegrity` holds the SHA-256 of the header JSON, checked
///   when the archive is opened.
/// - Each file's header entry carries the SHA-256 of its contents and of every 4 MB block,
///   checked whenever the file is read.
///
/// Either mismatch is a fatal crash, not a warning, so both are recomputed for anything
/// rewritten and the result is re-read and checked before it is signed.
struct AsarArchive {
    struct File {
        /// Archive-relative, without a leading slash: `frontend/assets/index-D_kKVYi7.css`.
        let path: String
        let offset: Int
        let size: Int
    }

    /// The archive, memory-mapped.
    let bytes: Data
    /// The header JSON exactly as stored. Info.plist's hash covers these bytes.
    let headerJSON: Data
    /// Where file data begins.
    let dataStart: Int
    /// Every file stored in the archive (not unpacked, not a link), in no particular order.
    let files: [File]

    private let header: NSDictionary

    init(contentsOf url: URL) throws {
        let bytes = try Data(contentsOf: url, options: .alwaysMapped)
        let name = url.lastPathComponent
        guard bytes.count >= 16, bytes.u32(at: 0) == 4 else {
            throw PatchError("\(name): not an asar archive")
        }
        let headerPickleLength = Int(bytes.u32(at: 4))
        let payloadLength = Int(bytes.u32(at: 8))
        let jsonLength = Int(bytes.u32(at: 12))
        guard payloadLength + 4 == headerPickleLength, jsonLength + 4 <= payloadLength,
            8 + headerPickleLength <= bytes.count
        else {
            throw PatchError("\(name): malformed asar header")
        }

        let headerJSON = bytes.subdata(in: 16 ..< 16 + jsonLength)
        guard
            let header = try JSONSerialization.jsonObject(with: headerJSON) as? NSDictionary
        else {
            throw PatchError("\(name): asar header is not a JSON object")
        }

        self.bytes = bytes
        self.headerJSON = headerJSON
        self.header = header
        self.dataStart = 8 + headerPickleLength
        self.files = try Self.collectFiles(in: header, prefix: "", dataLength: bytes.count - dataStart)
    }

    private static func collectFiles(in directory: NSDictionary, prefix: String, dataLength: Int)
        throws -> [File]
    {
        guard let children = directory["files"] as? NSDictionary else { return [] }
        var found: [File] = []
        for case let (name as String, node as NSDictionary) in children {
            let path = prefix + name
            if node["files"] != nil {
                found += try collectFiles(in: node, prefix: path + "/", dataLength: dataLength)
                continue
            }
            if node["link"] != nil || (node["unpacked"] as? Bool) == true { continue }
            guard let offsetText = node["offset"] as? String, let offset = Int(offsetText),
                let size = (node["size"] as? NSNumber)?.intValue,
                offset >= 0, size >= 0, offset + size <= dataLength
            else {
                throw PatchError("asar entry \(path) has no usable offset/size")
            }
            found.append(File(path: path, offset: offset, size: size))
        }
        return found
    }

    func contents(of file: File) -> Data {
        bytes.subdata(in: dataStart + file.offset ..< dataStart + file.offset + file.size)
    }

    /// The value Info.plist's `ElectronAsarIntegrity` must hold for this archive.
    var headerHash: String { Self.sha256Hex(headerJSON) }

    /// A header entry's `integrity` dictionary, for comparing before and after.
    func integrity(of path: String) -> NSDictionary? {
        Self.entry(at: path, in: header)?["integrity"] as? NSDictionary
    }

    // MARK: - Rewriting

    /// Writes a copy of this archive to `url` with the files in `replacements` swapped for
    /// new contents. Returns the new header hash.
    ///
    /// The existing data region is copied through byte for byte and each replacement is
    /// appended after it, with its header entry repointed and its integrity recomputed.
    /// The old copy stays behind as unreferenced bytes. Nothing that is not being replaced
    /// moves, so every other entry's offset and integrity carry across untouched -- which
    /// is what lets `verify` check the result by comparing rather than re-hashing 3000
    /// files.
    func write(to url: URL, replacing replacements: [String: Data]) throws -> String {
        guard
            let header = try JSONSerialization.jsonObject(
                with: headerJSON, options: .mutableContainers) as? NSMutableDictionary
        else {
            throw PatchError("asar header is not a JSON object")
        }

        var appendOffset = bytes.count - dataStart
        var appended: [Data] = []
        for (path, content) in replacements.sorted(by: { $0.key < $1.key }) {
            guard let entry = Self.entry(at: path, in: header) as? NSMutableDictionary else {
                throw PatchError("asar has no entry for \(path)")
            }
            let blockSize = ((entry["integrity"] as? NSDictionary)?["blockSize"] as? NSNumber)?
                .intValue ?? Self.defaultBlockSize
            entry["offset"] = String(appendOffset)
            entry["size"] = content.count
            entry["integrity"] = Self.integrity(of: content, blockSize: blockSize)
            appended.append(content)
            appendOffset += content.count
        }

        let json = try JSONSerialization.data(withJSONObject: header, options: .withoutEscapingSlashes)
        let padding = (4 - json.count % 4) % 4
        var prefix = Data(capacity: 16 + json.count + padding)
        prefix.appendU32(4)
        prefix.appendU32(UInt32(8 + json.count + padding))  // header pickle length
        prefix.appendU32(UInt32(4 + json.count + padding))  // header pickle payload length
        prefix.appendU32(UInt32(json.count))
        prefix.append(json)
        prefix.append(Data(count: padding))

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: prefix)
        try handle.write(contentsOf: bytes[dataStart...])
        for content in appended { try handle.write(contentsOf: content) }

        return Self.sha256Hex(json)
    }

    // MARK: - Helpers

    static let defaultBlockSize = 4 << 20

    private static func entry(at path: String, in header: NSDictionary) -> NSDictionary? {
        var node: NSDictionary? = header
        for component in path.split(separator: "/") {
            node = (node?["files"] as? NSDictionary)?[String(component)] as? NSDictionary
        }
        return node
    }

    /// Integrity in the shape `@electron/asar` writes it, and Electron checks it.
    static func integrity(of content: Data, blockSize: Int) -> NSDictionary {
        var blocks: [String] = []
        var cursor = content.startIndex
        repeat {
            let end = min(cursor + blockSize, content.endIndex)
            blocks.append(sha256Hex(content[cursor ..< end]))
            cursor = end
        } while cursor < content.endIndex
        return [
            "algorithm": "SHA256",
            "hash": sha256Hex(content),
            "blockSize": blockSize,
            "blocks": blocks,
        ]
    }

    static func sha256Hex<D: DataProtocol>(_ data: D) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    fileprivate mutating func appendU32(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
