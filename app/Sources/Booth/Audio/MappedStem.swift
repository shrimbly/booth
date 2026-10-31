import BoothCore
import Darwin
import Foundation

/// A WAV file mapped into memory. Stems of long recordings run to hundreds of megabytes, so the
/// preview reads samples straight from the mapping instead of decoding whole files.
final class MappedStem: @unchecked Sendable {
    enum LoadError: Error, CustomStringConvertible {
        case open(String, Int32)
        case map(String, Int32)
        case empty(String)

        var description: String {
            switch self {
            case .open(let path, let code): "can't open \(path): \(String(cString: strerror(code)))"
            case .map(let path, let code): "can't map \(path): \(String(cString: strerror(code)))"
            case .empty(let path): "\(path) is empty"
            }
        }
    }

    let url: URL
    let layout: WAVLayout
    private let base: UnsafeMutableRawPointer
    private let length: Int
    private let bytes: UnsafeRawBufferPointer

    init(url: URL) throws {
        let path = url.path
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw LoadError.open(path, errno) }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw LoadError.open(path, errno) }
        let length = Int(info.st_size)
        guard length > 0 else { throw LoadError.empty(path) }
        let mapping: UnsafeMutableRawPointer? = mmap(nil, length, PROT_READ, MAP_PRIVATE, descriptor, 0)
        guard let mapped = mapping, mapped != UnsafeMutableRawPointer(bitPattern: -1) else { // MAP_FAILED
            throw LoadError.map(path, errno)
        }
        let bytes = UnsafeRawBufferPointer(start: mapped, count: length)
        do {
            layout = try WAVLayout.parse(bytes)
        } catch {
            munmap(mapped, length)
            throw error
        }
        // Pull the samples into the page cache now rather than on the render thread.
        madvise(mapped, length, MADV_WILLNEED)
        self.url = url
        self.base = mapped
        self.length = length
        self.bytes = bytes
    }

    deinit {
        munmap(base, length)
    }

    var frameCount: Int { layout.frameCount }
    var sampleRate: Double { layout.sampleRate }

    /// The sample at `frame`, mixed down to mono. `frame` must be below `frameCount`.
    @inline(__always)
    func sample(_ frame: Int) -> Float {
        let channels = layout.channels
        if channels == 1 { return layout.sample(in: bytes, frame: frame) }
        var sum: Float = 0
        for channel in 0..<channels { sum += layout.sample(in: bytes, frame: frame, channel: channel) }
        return sum / Float(channels)
    }
}
