import Foundation

/// One row of Tauri's embedded-asset table.
///
/// The table is a `phf::Map<&str, &[u8]>` baked into `__DATA_CONST,__const` as 32-byte
/// records of four little-endian u64s:
///
///     +0  key pointer   +8  key length
///     +16 data pointer  +24 data length, in compressed bytes
///
/// `key` is empty for a row recovered by the keyless fallback, which finds blobs without
/// assuming anything about the record shape around them.
struct AssetEntry {
    let entryOffset: Int
    let key: String
    let dataOffset: Int
    let dataLength: Int
    let lengthFieldOffset: Int

    var dataRange: Range<Int> { dataOffset ..< dataOffset + dataLength }
    var label: String { key.isEmpty ? "blob@\(dataOffset)" : key }
}

struct AssetTable {
    let textConst: MachOImage.Section
    let dataConst: MachOImage.Section
    let imageBase: UInt64

    init(_ image: MachOImage) throws {
        textConst = try image.section("__TEXT", "__const")
        dataConst = try image.section("__DATA_CONST", "__const")
        imageBase = image.imageBase
    }

    // MARK: - Pointer decoding

    /// Resolves a stored pointer word to a file offset in `__TEXT,__const`, trying each
    /// encoding Apple's linkers produce and taking whichever lands in range.
    ///
    /// Conductor 0.84.2 links with classic `LC_DYLD_INFO_ONLY` rebases, so the word is a
    /// plain virtual address. Chained fixups pack the target into the low 36 bits --
    /// either as an address (`DYLD_CHAINED_PTR_64`) or as an offset from the image base
    /// (`..._64_OFFSET`). Rather than parse the fixups load command to find out which,
    /// try all three: a wrong reading simply fails to resolve, and every accepted record
    /// is validated further before anything is written.
    func resolve(pointerWord word: UInt64) -> Int? {
        let chainedTarget = word & 0x0000_000F_FFFF_FFFF  // 36-bit target field
        for candidate in [word, chainedTarget, imageBase &+ chainedTarget] {
            if let resolved = textConst.offset(forVA: candidate) { return resolved }
        }
        return nil
    }

    // MARK: - Enumeration

    /// Every 32-byte record that looks like a keyed asset row.
    ///
    /// Structural validation only. A couple of unrelated constants pass (2 of ~2900 in
    /// Conductor 0.84.2), which is why the integrity sweep compares the decodable set
    /// before and after rather than demanding every row decode.
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
        let keyLength = image.u64(at: offset + 8)
        let dataLength = image.u64(at: offset + 24)

        guard keyLength >= 1, keyLength <= 200,
            dataLength >= 1, dataLength <= 8 << 20,
            let keyOffset = resolve(pointerWord: image.u64(at: offset)),
            let dataOffset = resolve(pointerWord: image.u64(at: offset + 16)),
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
            dataLength: Int(dataLength),
            lengthFieldOffset: offset + 24)
    }

    /// Fallback that assumes nothing about the record layout: any adjacent
    /// `(pointer, length)` word pair whose target lies wholly inside `__TEXT,__const`.
    ///
    /// This is what keeps the tool alive if Tauri changes the map's value type -- adding
    /// CSP hashes back, say, which would widen rows from 32 bytes to 48 and desynchronise
    /// the keyed scan entirely. Much noisier than `entries`, so it is only consulted when
    /// the keyed scan cannot find what we are looking for.
    func slices(in image: Data) -> [AssetEntry] {
        var found: [AssetEntry] = []
        var seen = Set<Int>()
        var cursor = dataConst.fileStart
        let end = dataConst.fileEnd - 16

        while cursor <= end {
            defer { cursor += 8 }
            let length = image.u64(at: cursor + 8)
            guard length >= 64, length <= 8 << 20,
                let dataOffset = resolve(pointerWord: image.u64(at: cursor)),
                dataOffset + Int(length) <= textConst.fileEnd,
                !seen.contains(dataOffset)
            else { continue }
            seen.insert(dataOffset)
            found.append(
                AssetEntry(
                    entryOffset: cursor, key: "", dataOffset: dataOffset,
                    dataLength: Int(length), lengthFieldOffset: cursor + 8))
        }
        return found
    }

    // MARK: - Selection

    /// Finds the asset whose *decompressed* content contains `needle`.
    ///
    /// Content, not filename: Vite rehashes `renderApp-<hash>.js` on every build, splits
    /// and renames chunks, and the stylesheet could stop being a single file. What does
    /// not change is that the code carrying a given anchor is in there somewhere.
    /// `preferring` is a cheap ordering hint, not a requirement.
    static func find(
        _ needle: String,
        describedAs label: String,
        in entries: [AssetEntry],
        preferring keyHint: String?,
        image: Data
    ) -> (entry: AssetEntry, content: Data)? {
        let target = Data(needle.utf8)

        var ordered = entries
        if let keyHint {
            // Try the usual suspect first so the common case decompresses one blob, not
            // three thousand.
            ordered.sort { left, right in
                left.key.contains(keyHint) && !right.key.contains(keyHint)
            }
        }

        for entry in ordered {
            guard let content = try? Brotli.decompress(image[entry.dataRange]) else { continue }
            if content.range(of: target) != nil {
                Log.debug("\(label): found in \(entry.label) (\(humanBytes(content.count)))")
                return (entry, content)
            }
        }
        return nil
    }
}

extension Data {
    /// Overwrites an asset's blob in place and retunes its length field.
    ///
    /// No relocation and no padding games: the recompressed blob is always smaller than
    /// what shipped (Tauri compressed at a lower quality than 11, leaving ~260 KB of slack
    /// on the main chunk alone), so the bytes go back at the same offset and the table's
    /// length u64 is lowered to match. The tail is zeroed so no fragment of the old stream
    /// is left lying in the image.
    mutating func writeAsset(_ blob: Data, to entry: AssetEntry) throws {
        guard blob.count <= entry.dataLength else {
            throw PatchError(
                "\(entry.label): patched blob is \(blob.count) bytes but the slot holds only "
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
            "\(entry.label): \(entry.dataLength) -> \(blob.count) bytes "
                + "(\(humanBytes(slack)) reclaimed)")
    }
}
