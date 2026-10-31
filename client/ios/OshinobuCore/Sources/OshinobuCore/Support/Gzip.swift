import Compression
import Foundation

/// Распаковка gzip (RFC 1952) — для TGS-стикеров (Lottie JSON в gzip). Заголовок
/// разбирается вручную, тело — raw deflate потоком через Compression.
public enum Gzip {
    public static func decompress(_ data: Data) -> Data? {
        guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b, data[data.startIndex + 2] == 8 else { return nil }
        let flags = data[data.startIndex + 3]
        var p = data.startIndex + 10
        if flags & 0x04 != 0 { // FEXTRA
            guard p + 2 <= data.endIndex else { return nil }
            p += 2 + (Int(data[p]) | (Int(data[p + 1]) << 8))
        }
        if flags & 0x08 != 0 { while p < data.endIndex, data[p] != 0 { p += 1 }; p += 1 } // FNAME
        if flags & 0x10 != 0 { while p < data.endIndex, data[p] != 0 { p += 1 }; p += 1 } // FCOMMENT
        if flags & 0x02 != 0 { p += 2 } // FHCRC
        guard p < data.endIndex - 8 else { return nil }
        return inflate(data[p..<(data.endIndex - 8)])
    }

    /// Raw deflate потоком (размер результата заранее неизвестен).
    private static func inflate(_ input: Data) -> Data? {
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(streamPtr) }
        let chunk = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var out = Data()
        return input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return nil }
            streamPtr.pointee.src_ptr = base
            streamPtr.pointee.src_size = input.count
            while true {
                streamPtr.pointee.dst_ptr = dst
                streamPtr.pointee.dst_size = chunk
                let status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(dst, count: chunk - streamPtr.pointee.dst_size)
                switch status {
                case COMPRESSION_STATUS_OK: continue
                case COMPRESSION_STATUS_END: return out
                default: return nil
                }
            }
        }
    }
}
