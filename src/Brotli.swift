import Foundation

/// Thin wrappers over the statically linked libbrotli.
///
/// Quality 11 with a 22-bit window matches what Tauri's embedded assets decode as and
/// costs about 13 s on Conductor's 11 MB main chunk -- fine, since this runs once per
/// launch and the launch is the slow part anyway. A smaller window would also fit the
/// budget; 22 is the conservative choice the Rust decoder in Tauri is certain to handle.
enum Brotli {
    static let quality: Int32 = 11
    static let windowBits: Int32 = 22

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

    static func compress(_ input: Data) throws -> Data {
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
