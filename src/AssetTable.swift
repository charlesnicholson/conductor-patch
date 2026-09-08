import Foundation

/// One row of Tauri's embedded-asset table.
///
/// The table is a `phf::Map<&str, &[u8]>` baked into `__DATA_CONST,__const` as 32-byte
/// records of four little-endian u64s:
///
///     +0  key pointer (virtual address)   +8  key length
///     +16 data pointer (virtual address)  +24 data length, in compressed bytes
///
/// Conductor links with the classic `LC_DYLD_INFO_ONLY` rebase opcodes rather than chained
/// fixups, so those pointers are plain virtual addresses sitting in the file -- readable,
/// and in principle writable, without decoding a fixup chain.
struct AssetEntry {
    let entryOffset: Int
    let key: String
    let dataOffset: Int
    let dataLength: Int

    /// File offset of the u64 holding the blob length.
    var lengthFieldOffset: Int { entryOffset + 24 }
    var dataRange: Range<Int> { dataOffset ..< dataOffset + dataLength }
}

struct AssetTable {
    let textConst: MachOImage.Section
    let dataConst: MachOImage.Section

    init(_ image: MachOImage) throws {
        textConst = try image.section("__TEXT", "__const")
        dataConst = try image.section("__DATA_CONST", "__const")
    }

    /// Every record that looks like an asset row.
    ///
    /// Structural validation only -- pointers land in `__TEXT,__const`, lengths are sane,
    /// the key is printable and absolute. A couple of unrelated constants happen to pass
    /// (2 of ~2900 in Conductor 0.84.2), which is why the integrity sweep compares the
    /// before and after sets rather than demanding every row decompress.
    func entries(in image: Data) -> [AssetEntry] {
        var found: [AssetEntry] = []
        var cursor = dataConst.fileStart
        let end = dataConst.fileEnd - 32

        while cursor <= end {
            guard let entry = record(at: cursor, in: image) else {
                cursor += 8
                continue
            }
            found.append(entry)
            cursor += 32
        }
        return found
    }

    private func record(at offset: Int, in image: Data) -> AssetEntry? {
        let keyPointer = image.u64(at: offset)
        let keyLength = image.u64(at: offset + 8)
        let dataPointer = image.u64(at: offset + 16)
        let dataLength = image.u64(at: offset + 24)

        guard keyLength >= 1, keyLength <= 200,
            dataLength >= 1, dataLength <= 8 << 20,
            let keyOffset = textConst.offset(forVA: keyPointer),
            let dataOffset = textConst.offset(forVA: dataPointer),
            keyOffset + Int(keyLength) <= textConst.fileEnd,
            dataOffset + Int(dataLength) <= textConst.fileEnd
        else { return nil }

        let keyBytes = image[keyOffset ..< keyOffset + Int(keyLength)]
        guard keyBytes.first == UInt8(ascii: "/"),
            keyBytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f })
        else { return nil }

        return AssetEntry(
            entryOffset: offset,
            key: String(decoding: keyBytes, as: UTF8.self),
            dataOffset: dataOffset,
            dataLength: Int(dataLength))
    }

    /// The one entry whose key matches `pattern`, which must match exactly once.
    ///
    /// Matching by pattern rather than literal name is what lets the patch survive a
    /// Conductor release: Vite rehashes `renderApp-<hash>.js` on every build.
    static func unique(_ entries: [AssetEntry], matching pattern: String, describedAs label: String)
        throws -> AssetEntry
    {
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = entries.filter { entry in
            let range = NSRange(entry.key.startIndex ..< entry.key.endIndex, in: entry.key)
            return regex.firstMatch(in: entry.key, range: range) != nil
        }
        guard matches.count == 1 else {
            let names = matches.map(\.key).sorted().joined(separator: ", ")
            throw PatchError(
                "expected exactly one \(label) asset matching /\(pattern)/, found "
                    + "\(matches.count)\(names.isEmpty ? "" : ": \(names)")")
        }
        return matches[0]
    }
}

extension Data {
    /// Overwrites an asset's blob in place and retunes its length field.
    ///
    /// No relocation and no padding games: the recompressed blob is always smaller than
    /// what shipped (Tauri compressed at a lower quality than 11, leaving ~300 KB of slack
    /// on the main chunk alone), so the bytes go back at the same offset and the table's
    /// length u64 is lowered to match. The tail is zeroed so no fragment of the old stream
    /// is left lying in the image.
    mutating func writeAsset(_ blob: Data, to entry: AssetEntry) throws {
        guard blob.count <= entry.dataLength else {
            throw PatchError(
                "\(entry.key): patched blob is \(blob.count) bytes but the slot holds only "
                    + "\(entry.dataLength). Relocating assets is not implemented.")
        }

        replaceSubrange(entry.dataOffset ..< entry.dataOffset + blob.count, with: blob)

        let slack = entry.dataLength - blob.count
        if slack > 0 {
            let tail = entry.dataOffset + blob.count
            replaceSubrange(tail ..< tail + slack, with: Data(repeating: 0, count: slack))
        }
        setU64(UInt64(blob.count), at: entry.lengthFieldOffset)

        Log.debug(
            "\(entry.key): \(entry.dataLength) -> \(blob.count) bytes "
                + "(\(humanBytes(slack)) reclaimed)")
    }
}
