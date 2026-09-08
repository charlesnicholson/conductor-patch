import Foundation

/// Just enough Mach-O to find two sections by name in a thin arm64 image.
///
/// Conductor is a Tauri app: its entire React frontend is embedded in the executable as
/// brotli blobs living in `__TEXT,__const`, indexed by a compile-time perfect-hash table
/// in `__DATA_CONST,__const`. Those two sections are all this needs to locate, plus the
/// virtual-address-to-file-offset mapping to follow the table's pointers.
struct MachOImage {
    struct Section {
        let segment: String
        let name: String
        let vmAddr: UInt64
        let size: UInt64
        let fileOffset: UInt64

        var fileStart: Int { Int(fileOffset) }
        var fileEnd: Int { Int(fileOffset + size) }
        var fileRange: Range<Int> { fileStart ..< fileEnd }

        func contains(va: UInt64) -> Bool { va >= vmAddr && va < vmAddr &+ size }

        /// File offset for a virtual address, or nil if the address is not in this section.
        func offset(forVA va: UInt64) -> Int? {
            contains(va: va) ? Int(fileOffset &+ (va &- vmAddr)) : nil
        }
    }

    let sections: [Section]

    /// Preferred load address, i.e. the `__TEXT` segment's vmaddr. Needed to interpret
    /// chained-fixup pointers, which store an offset from here rather than an address.
    let imageBase: UInt64

    /// Whether the image carries `LC_DYLD_CHAINED_FIXUPS`. Conductor 0.84.2 does not --
    /// it still uses classic `LC_DYLD_INFO_ONLY` rebases, so its pointers are plain
    /// virtual addresses -- but a deployment-target or Xcode bump would flip this, and it
    /// is the one change that would otherwise silently make every pointer unreadable.
    let hasChainedFixups: Bool

    private static let MH_MAGIC_64: UInt32 = 0xfeed_facf
    private static let LC_SEGMENT_64: UInt32 = 0x19
    private static let LC_DYLD_CHAINED_FIXUPS: UInt32 = 0x8000_0034

    init(_ image: Data) throws {
        guard image.count > 32 else { throw PatchError("not a Mach-O: file is too small") }

        let magic = image.u32(at: 0)
        guard magic == Self.MH_MAGIC_64 else {
            // A universal binary would need a slice picked first. Conductor ships thin
            // arm64, so rather than guess, say what was found.
            throw PatchError(
                String(
                    format:
                        "unsupported Mach-O magic 0x%08x; expected a thin arm64 image (0xfeedfacf)",
                    magic))
        }

        let commandCount = Int(image.u32(at: 16))
        var found: [Section] = []
        var base: UInt64?
        var chained = false
        var cursor = 32  // sizeof(mach_header_64)

        for _ in 0 ..< commandCount {
            guard cursor + 8 <= image.count else {
                throw PatchError("truncated load commands at offset \(cursor)")
            }
            let command = image.u32(at: cursor)
            let commandSize = Int(image.u32(at: cursor + 4))
            guard commandSize >= 8, cursor + commandSize <= image.count else {
                throw PatchError("bad load command size \(commandSize) at offset \(cursor)")
            }

            if command == Self.LC_DYLD_CHAINED_FIXUPS { chained = true }

            if command == Self.LC_SEGMENT_64 {
                // struct segment_command_64: cmd, cmdsize, segname[16], vmaddr, vmsize,
                // fileoff, filesize, maxprot, initprot, nsects, flags
                let segmentName = image.cString(at: cursor + 8, maxLength: 16)
                if segmentName == "__TEXT" { base = image.u64(at: cursor + 24) }
                let sectionCount = Int(image.u32(at: cursor + 64))
                var sectionCursor = cursor + 72  // sizeof(segment_command_64)

                for _ in 0 ..< sectionCount {
                    guard sectionCursor + 80 <= cursor + commandSize else {
                        throw PatchError("section table overruns segment \(segmentName)")
                    }
                    // struct section_64: sectname[16], segname[16], addr, size, offset, ...
                    found.append(
                        Section(
                            segment: segmentName,
                            name: image.cString(at: sectionCursor, maxLength: 16),
                            vmAddr: image.u64(at: sectionCursor + 32),
                            size: image.u64(at: sectionCursor + 40),
                            fileOffset: UInt64(image.u32(at: sectionCursor + 48))))
                    sectionCursor += 80
                }
            }

            cursor += commandSize
        }

        sections = found
        hasChainedFixups = chained
        guard let base else { throw PatchError("Mach-O has no __TEXT segment") }
        imageBase = base
    }

    func section(_ segment: String, _ name: String) throws -> Section {
        guard let match = sections.first(where: { $0.segment == segment && $0.name == name })
        else {
            throw PatchError("Mach-O has no \(segment),\(name) section")
        }
        return match
    }
}
