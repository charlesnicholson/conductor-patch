import Foundation

/// Thin wrappers over the statically linked libbrotli.
///
/// Window size is 24 bits, the largest the standard format allows without the large-window
/// extension, so any conforming decoder handles it. It is not a nicety: on Conductor's
/// 11 MB main chunk, quality 9 at lgwin 22 overshoots the slot by 1055 bytes while the same
/// quality at lgwin 24 comes in 20 KB under it -- the difference between a 0.7 s compress
/// and a 13 s one.
enum Brotli {
    static let windowBits: Int32 = 24

    /// Qualities to try, cheapest first. Compression is ~89% of a patch run's wall clock,
    /// and the only thing that matters about the output is that it fits the slot it came
    /// out of, so there is no reason to pay for quality 11 when 9 fits.
    static let qualityLadder: [Int32] = [9, 10, 11]

    static func decompress(_ input: Data) throws -> Data {
        guard let state = BrotliDecoderCreateInstance(nil, nil, nil) else {
            throw PatchError("brotli: could not create decoder")
        }
        defer { BrotliDecoderDestroyInstance(state) }

        var output = Data()
        // Large enough that an 11 MB asset takes a few hundred iterations, small enough
        // to stay off the stack pressure radar.
        var chunk = [UInt8](repeating: 0, count: 1 << 18)

        return try input.withUnsafeBytes { raw -> Data in
            var availableIn = raw.count
            var nextIn = raw.bindMemory(to: UInt8.self).baseAddress

            while true {
                var result = BROTLI_DECODER_RESULT_ERROR
                chunk.withUnsafeMutableBufferPointer { out in
                    var availableOut = out.count
                    var nextOut = out.baseAddress
                    result = BrotliDecoderDecompressStream(
                        state, &availableIn, &nextIn, &availableOut, &nextOut, nil)
                    output.append(contentsOf: out.prefix(out.count - availableOut))
                }

                switch result {
                case BROTLI_DECODER_RESULT_SUCCESS:
                    return output
                case BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT:
                    continue
                case BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT:
                    // The whole stream was handed over up front, so this means truncated.
                    throw PatchError("brotli: stream ended mid-decode")
                default:
                    let code = BrotliDecoderGetErrorCode(state)
                    let text = BrotliDecoderErrorString(code).map { String(cString: $0) } ?? "?"
                    throw PatchError("brotli: decode failed (\(text))")
                }
            }
        }
    }

    /// Compresses to fit `budget`, climbing the quality ladder only as far as needed.
    ///
    /// The result is decompressed and compared before being returned. That round trip
    /// costs about a tenth of a second and is the last line of defence between an encoder
    /// bug and a Conductor that launches to a blank window.
    static func compressToFit(_ input: Data, budget: Int, describedAs label: String) throws -> Data
    {
        var last: Data?
        for quality in qualityLadder {
            let blob = try compress(input, quality: quality)
            last = blob
            if blob.count <= budget {
                guard try decompress(blob) == input else {
                    throw PatchError("\(label): brotli round trip did not reproduce the input")
                }
                Log.debug(
                    "\(label): q\(quality) -> \(blob.count) bytes, \(budget - blob.count) spare")
                return blob
            }
            Log.debug(
                "\(label): q\(quality) -> \(blob.count) bytes, \(blob.count - budget) over budget")
        }
        throw PatchError(
            "\(label): even quality \(qualityLadder.last ?? 11) produces "
                + "\(last?.count ?? 0) bytes, over the \(budget)-byte slot")
    }

    static func compress(_ input: Data, quality: Int32 = 11) throws -> Data {
        var capacity = BrotliEncoderMaxCompressedSize(input.count)
        guard capacity > 0 else { throw PatchError("brotli: input too large to compress") }
        var output = [UInt8](repeating: 0, count: capacity)

        let ok = input.withUnsafeBytes { raw -> Int32 in
            output.withUnsafeMutableBufferPointer { out in
                BrotliEncoderCompress(
                    quality, windowBits, BROTLI_MODE_GENERIC,
                    raw.count, raw.bindMemory(to: UInt8.self).baseAddress,
                    &capacity, out.baseAddress)
            }
        }
        guard ok == 1 else { throw PatchError("brotli: encode failed") }
        return Data(output.prefix(capacity))
    }
}
