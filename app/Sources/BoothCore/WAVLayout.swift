import Foundation

/// Where the samples are in a RIFF/WAVE file, so the preview player can read them straight out
/// of a memory-mapped file instead of decoding whole stems into memory.
public struct WAVLayout: Equatable, Sendable {
    public enum SampleFormat: Equatable, Sendable {
        case int16, int24, int32, float32, float64

        public var bytesPerSample: Int {
            switch self {
            case .int16: 2
            case .int24: 3
            case .int32, .float32: 4
            case .float64: 8
            }
        }
    }

    public enum ParseError: Error, Equatable {
        case notWAV
        case missingChunk(String)
        case unsupportedFormat(tag: UInt16, bitsPerSample: UInt16)
        case invalidSampleRate
    }

    public var format: SampleFormat
    public var channels: Int
    public var sampleRate: Double
    /// Byte offset of the first sample.
    public var dataOffset: Int
    /// Bytes of sample data, clamped to what the file really holds.
    public var dataLength: Int

    public init(format: SampleFormat, channels: Int, sampleRate: Double, dataOffset: Int, dataLength: Int) {
        self.format = format
        self.channels = channels
        self.sampleRate = sampleRate
        self.dataOffset = dataOffset
        self.dataLength = dataLength
    }

    public var bytesPerFrame: Int { format.bytesPerSample * channels }
    public var frameCount: Int { bytesPerFrame > 0 ? dataLength / bytesPerFrame : 0 }

    public static func parse(_ data: Data) throws -> WAVLayout {
        try data.withUnsafeBytes { try parse($0) }
    }

    /// Reads the `fmt ` and `data` chunks, skipping any others (`fact`, `PEAK`, `LIST`, …).
    public static func parse(_ bytes: UnsafeRawBufferPointer) throws -> WAVLayout {
        guard bytes.count >= 12, fourCC(bytes, at: 0) == "RIFF", fourCC(bytes, at: 8) == "WAVE" else {
            throw ParseError.notWAV
        }
        var format: (tag: UInt16, channels: UInt16, rate: UInt32, bits: UInt16)?
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = fourCC(bytes, at: offset)
            let size = Int(uint32(bytes, at: offset + 4))
            let body = offset + 8
            switch id {
            case "fmt ":
                guard size >= 16, body + 16 <= bytes.count else { throw ParseError.missingChunk("fmt ") }
                var tag = uint16(bytes, at: body)
                // WAVE_FORMAT_EXTENSIBLE: the real tag is the first two bytes of the sub-format GUID.
                if tag == 0xFFFE, size >= 40, body + 26 <= bytes.count { tag = uint16(bytes, at: body + 24) }
                format = (tag, uint16(bytes, at: body + 2), uint32(bytes, at: body + 4), uint16(bytes, at: body + 14))
            case "data":
                guard let format else { throw ParseError.missingChunk("fmt ") }
                guard format.rate > 0 else { throw ParseError.invalidSampleRate }
                let sampleFormat = try sampleFormat(tag: format.tag, bits: format.bits)
                // Streaming writers leave the size at 0 or 0xFFFFFFFF; trust the file length then.
                let available = bytes.count - body
                let length = (size == 0 || size > available) ? available : size
                return WAVLayout(
                    format: sampleFormat, channels: max(1, Int(format.channels)), sampleRate: Double(format.rate),
                    dataOffset: body, dataLength: length)
            default:
                break
            }
            offset = body + size + (size & 1) // chunks are padded to even sizes
        }
        throw ParseError.missingChunk(format == nil ? "fmt " : "data")
    }

    private static func sampleFormat(tag: UInt16, bits: UInt16) throws -> SampleFormat {
        switch (tag, bits) {
        case (1, 16): return .int16
        case (1, 24): return .int24
        case (1, 32): return .int32
        case (3, 32): return .float32
        case (3, 64): return .float64
        default: throw ParseError.unsupportedFormat(tag: tag, bitsPerSample: bits)
        }
    }

    /// One sample as a float in −1…1. `frame` and `channel` must be in range.
    @inline(__always)
    public func sample(in bytes: UnsafeRawBufferPointer, frame: Int, channel: Int = 0) -> Float {
        let offset = dataOffset + frame * bytesPerFrame + channel * format.bytesPerSample
        switch format {
        case .float32:
            return Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
        case .int16:
            return Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768
        case .int32:
            return Float(Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int32.self))) / 2_147_483_648
        case .int24:
            let value = Int32(bytes[offset]) | Int32(bytes[offset + 1]) << 8 | Int32(Int8(bitPattern: bytes[offset + 2])) << 16
            return Float(value) / 8_388_608
        case .float64:
            return Float(Double(bitPattern: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))))
        }
    }

    private static func fourCC(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> String {
        String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
    }

    private static func uint16(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt16 {
        UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    private static func uint32(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
}
