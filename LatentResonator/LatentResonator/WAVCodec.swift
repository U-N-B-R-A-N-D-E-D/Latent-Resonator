import Foundation

// MARK: - WAV Codec (Whitepaper §6.1 -- Bridge Transport Layer)
//
// Lightweight WAV encoder/decoder for audio-to-HTTP transport.
// Used by ACEStepBridge to serialize audio samples as base64-encoded
// WAV for JSON payloads to/from the Python bridge server.
//
// Supports:
//   - Encoding: Float32 mono -> WAV (IEEE float 32-bit)
//   - Decoding: WAV (16-bit PCM or 32-bit float) -> [Float]

enum WAVCodec {

    // MARK: - Encode

    /// Encode float32 samples into a WAV file (IEEE Float 32-bit, mono).
    ///
    /// - Parameters:
    ///   - samples: Mono float32 audio samples
    ///   - sampleRate: Audio sample rate (default: 48000)
    /// - Returns: WAV file data
    static func encode(
        samples: [Float],
        sampleRate: Int = Int(LRConstants.sampleRate)
    ) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 32
        let audioFormat: UInt16 = 3    // IEEE float
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * MemoryLayout<Float>.size)
        let fileSize = 36 + dataSize   // RIFF header(8) + fmt(24) + data header(8) = 36 + data

        var data = Data()
        data.reserveCapacity(Int(44 + dataSize))

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        appendUInt32(&data, fileSize)
        data.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk
        data.append(contentsOf: "fmt ".utf8)
        appendUInt32(&data, 16)                     // sub-chunk size
        appendUInt16(&data, audioFormat)             // IEEE float
        appendUInt16(&data, numChannels)
        appendUInt32(&data, UInt32(sampleRate))
        appendUInt32(&data, byteRate)
        appendUInt16(&data, blockAlign)
        appendUInt16(&data, bitsPerSample)

        // data sub-chunk
        data.append(contentsOf: "data".utf8)
        appendUInt32(&data, dataSize)

        // Sample data -- write float32 directly
        samples.withUnsafeBufferPointer { buffer in
            let raw = UnsafeRawBufferPointer(buffer)
            data.append(contentsOf: raw)
        }

        return data
    }

    // MARK: - Decode

    /// Decode a WAV file to mono float32 samples.
    /// Supports 16-bit PCM and 32-bit IEEE float formats.
    ///
    /// - Parameter wavData: WAV file data
    /// - Returns: Mono float32 audio samples (empty array on failure)
    static func decode(wavData: Data) -> [Float] {
        guard wavData.count >= 44 else {
            print("[WAVCodec] Data too short: \(wavData.count) bytes")
            return []
        }

        // Verify RIFF/WAVE header
        let riff = String(data: wavData[0..<4], encoding: .ascii) ?? ""
        let wave = String(data: wavData[8..<12], encoding: .ascii) ?? ""

        guard riff == "RIFF", wave == "WAVE" else {
            print("[WAVCodec] Not a valid WAV file (RIFF=\(riff), WAVE=\(wave))")
            return []
        }

        // Parse chunks
        var pos = 12
        var audioFormat: UInt16 = 0
        var numChannels: UInt16 = 1
        var bitsPerSample: UInt16 = 16
        var fmtFound = false
        var dataBytes = Data()

        while pos < wavData.count - 8 {
            let chunkID = String(data: wavData[pos..<pos+4], encoding: .ascii) ?? ""
            let chunkSize = readUInt32(wavData, at: pos + 4)
            pos += 8

            if chunkID == "fmt " {
                guard pos + 16 <= wavData.count else { break }
                audioFormat = readUInt16(wavData, at: pos)
                numChannels = readUInt16(wavData, at: pos + 2)
                // sampleRate at pos+4 (not needed -- we trust the caller)
                bitsPerSample = readUInt16(wavData, at: pos + 14)
                fmtFound = true
            } else if chunkID == "data" {
                let endPos = min(pos + Int(chunkSize), wavData.count)
                dataBytes = wavData[pos..<endPos]
                break
            }

            pos += Int(chunkSize)
        }

        guard fmtFound, !dataBytes.isEmpty else {
            print("[WAVCodec] Missing fmt or data chunk")
            return []
        }

        // Decode samples
        var samples: [Float]

        if audioFormat == 3 && bitsPerSample == 32 {
            // IEEE Float 32-bit (alignment-safe copy)
            let count = dataBytes.count / MemoryLayout<Float>.size
            samples = [Float](repeating: 0, count: count)
            dataBytes.withUnsafeBytes { raw in
                samples.withUnsafeMutableBufferPointer { dst in
                    guard let dstBase = dst.baseAddress,
                          let srcBase = raw.baseAddress else { return }
                    memcpy(dstBase, srcBase, count * MemoryLayout<Float>.size)
                }
            }
        } else if audioFormat == 1 && bitsPerSample == 16 {
            // PCM 16-bit (alignment-safe)
            let count = dataBytes.count / MemoryLayout<Int16>.size
            samples = [Float](repeating: 0, count: count)
            var int16Buf = [Int16](repeating: 0, count: count)
            dataBytes.withUnsafeBytes { raw in
                int16Buf.withUnsafeMutableBufferPointer { dst in
                    guard let dstBase = dst.baseAddress,
                          let srcBase = raw.baseAddress else { return }
                    memcpy(dstBase, srcBase, count * MemoryLayout<Int16>.size)
                }
            }
            for i in 0..<count {
                samples[i] = Float(int16Buf[i]) / 32768.0
            }
        } else if audioFormat == 1 && bitsPerSample == 24 {
            // PCM 24-bit
            let count = dataBytes.count / 3
            samples = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let offset = dataBytes.startIndex + i * 3
                let b0 = Int32(dataBytes[offset])
                let b1 = Int32(dataBytes[offset + 1])
                let b2 = Int32(dataBytes[offset + 2])
                // Sign-extend from 24-bit
                var val = b0 | (b1 << 8) | (b2 << 16)
                if val & 0x800000 != 0 {
                    val |= Int32(bitPattern: 0xFF000000)   // sign-extend
                }
                samples[i] = Float(val) / 8388608.0
            }
        } else {
            print("[WAVCodec] Unsupported format: audioFormat=\(audioFormat), bits=\(bitsPerSample)")
            return []
        }

        // Mix to mono if multichannel
        if numChannels > 1 {
            let monoCount = samples.count / Int(numChannels)
            var mono = [Float](repeating: 0, count: monoCount)
            let ch = Int(numChannels)
            for i in 0..<monoCount {
                var sum: Float = 0
                for c in 0..<ch {
                    sum += samples[i * ch + c]
                }
                mono[i] = sum / Float(ch)
            }
            return mono
        }

        return samples
    }

    // MARK: - Binary Helpers

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        // Use manual byte assembly to avoid alignment requirements.
        // WAV chunk boundaries are not guaranteed to be 2-byte aligned.
        guard offset + 1 < data.count else { return 0 }
        let b0 = UInt16(data[data.startIndex + offset])
        let b1 = UInt16(data[data.startIndex + offset + 1])
        return b0 | (b1 << 8)  // little-endian
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        // Use manual byte assembly to avoid alignment requirements.
        guard offset + 3 < data.count else { return 0 }
        let si = data.startIndex
        let b0 = UInt32(data[si + offset])
        let b1 = UInt32(data[si + offset + 1])
        let b2 = UInt32(data[si + offset + 2])
        let b3 = UInt32(data[si + offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)  // little-endian
    }
}
