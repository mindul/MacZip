import Foundation
import zlib

private let bufferSize = 64 * 1024
private let streamSize = Int32(MemoryLayout<z_stream>.size)

/// zip용 raw deflate(windowBits = -15) 스트리밍 압축기.
public final class RawDeflater {
    private var stream = z_stream()
    private var buffer = [UInt8](repeating: 0, count: bufferSize)

    public init(level: Int32 = 6) {
        let rc = deflateInit2_(&stream, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, streamSize)
        precondition(rc == Z_OK, "deflateInit2 실패: \(rc)")
    }

    deinit { deflateEnd(&stream) }

    public func write(_ chunk: Data, sink: (Data) throws -> Void) throws {
        try run(chunk, flush: Z_NO_FLUSH, sink: sink)
    }

    public func finish(sink: (Data) throws -> Void) throws {
        try run(Data(), flush: Z_FINISH, sink: sink)
    }

    private func run(_ input: Data, flush: Int32, sink: (Data) throws -> Void) throws {
        var input = input
        try input.withUnsafeMutableBytes { (inRaw: UnsafeMutableRawBufferPointer) in
            stream.next_in = inRaw.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(inRaw.count)
            while true {
                let (rc, produced) = buffer.withUnsafeMutableBufferPointer { out -> (Int32, Int) in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    let rc = deflate(&stream, flush)
                    return (rc, out.count - Int(stream.avail_out))
                }
                if rc == Z_STREAM_ERROR { throw ZipError.corrupt("deflate") }
                if produced > 0 { try sink(Data(buffer[0..<produced])) }
                if flush == Z_FINISH {
                    if rc == Z_STREAM_END { break }
                } else if stream.avail_in == 0 && stream.avail_out != 0 {
                    break
                }
            }
            stream.next_in = nil
        }
    }
}

/// zip용 raw inflate 스트리밍 해제기.
public final class RawInflater {
    private var stream = z_stream()
    private var buffer = [UInt8](repeating: 0, count: bufferSize)
    public private(set) var isFinished = false

    public init() {
        let rc = inflateInit2_(&stream, -15, ZLIB_VERSION, streamSize)
        precondition(rc == Z_OK, "inflateInit2 실패: \(rc)")
    }

    deinit { inflateEnd(&stream) }

    public func write(_ chunk: Data, sink: (Data) throws -> Void) throws {
        if chunk.isEmpty { return }
        if isFinished { throw ZipError.corrupt("inflate") }
        var input = chunk
        try input.withUnsafeMutableBytes { (inRaw: UnsafeMutableRawBufferPointer) in
            stream.next_in = inRaw.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(inRaw.count)
            defer { stream.next_in = nil }
            while true {
                let (rc, produced) = buffer.withUnsafeMutableBufferPointer { out -> (Int32, Int) in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    let rc = inflate(&stream, Z_NO_FLUSH)
                    return (rc, out.count - Int(stream.avail_out))
                }
                if produced > 0 { try sink(Data(buffer[0..<produced])) }
                switch rc {
                case Z_STREAM_END:
                    isFinished = true
                    // 스트림 끝 뒤에 남은 데이터는 손상으로 본다.
                    if stream.avail_in > 0 { throw ZipError.corrupt("inflate") }
                    return
                case Z_OK:
                    if stream.avail_in == 0 && stream.avail_out != 0 { return }
                case Z_BUF_ERROR:
                    if stream.avail_in == 0 { return }
                    throw ZipError.corrupt("inflate")
                default:
                    throw ZipError.corrupt("inflate")
                }
            }
        }
    }
}
