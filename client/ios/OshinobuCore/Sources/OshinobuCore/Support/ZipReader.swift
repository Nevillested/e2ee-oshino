import Compression
import Foundation

/// Минимальный читатель ZIP (паки стикеров): центральный каталог, записи без сжатия
/// (так пишет сервер) и deflate (через Compression). Без сторонних библиотек.
public enum ZipReader {
    public struct ZipError: Error { public let reason: String }

    /// Распаковать все файлы архива в [dir]; возвращает имена распакованных.
    @discardableResult
    public static func extract(_ archive: URL, to dir: URL) throws -> [String] {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var names: [String] = []
        for entry in try entries(data) {
            // только плоские имена — никаких путей из архива (zip slip)
            let name = (entry.name as NSString).lastPathComponent
            guard !name.isEmpty, !name.hasPrefix(".") else { continue }
            try entry.content(data).write(to: dir.appendingPathComponent(name), options: .atomic)
            names.append(name)
        }
        return names
    }

    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int

        func content(_ data: Data) throws -> Data {
            let lh = localHeaderOffset
            guard read32(data, lh) == 0x04034b50 else { throw ZipError(reason: "нет локального заголовка") }
            let start = lh + 30 + Int(read16(data, lh + 26)) + Int(read16(data, lh + 28))
            guard start + compressedSize <= data.count else { throw ZipError(reason: "запись обрезана") }
            let raw = data.subdata(in: start..<start + compressedSize)
            switch method {
            case 0: return raw
            case 8: return try inflate(raw, expected: uncompressedSize)
            default: throw ZipError(reason: "метод сжатия \(method) не поддерживается")
            }
        }
    }

    static func entries(_ data: Data) throws -> [Entry] {
        // конец центрального каталога — ищем с конца (комментарий архива до 64 КБ)
        var eocd = -1
        var i = data.count - 22
        while i >= max(0, data.count - 22 - 65_535) {
            if read32(data, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError(reason: "не ZIP") }
        let count = Int(read16(data, eocd + 10))
        var p = Int(read32(data, eocd + 16))
        var result: [Entry] = []
        for _ in 0..<count {
            guard read32(data, p) == 0x02014b50 else { throw ZipError(reason: "повреждён центральный каталог") }
            let method = read16(data, p + 10)
            let csize = Int(read32(data, p + 20))
            let usize = Int(read32(data, p + 24))
            let nameLen = Int(read16(data, p + 28))
            let extraLen = Int(read16(data, p + 30))
            let commentLen = Int(read16(data, p + 32))
            let offset = Int(read32(data, p + 42))
            let name = String(decoding: data.subdata(in: p + 46..<p + 46 + nameLen), as: UTF8.self)
            if !name.hasSuffix("/") {
                result.append(Entry(name: name, method: method, compressedSize: csize, uncompressedSize: usize, localHeaderOffset: offset))
            }
            p += 46 + nameLen + extraLen + commentLen
        }
        return result
    }

    private static func read16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8 }
    private static func read32(_ d: Data, _ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= d.count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(d[d.startIndex + o + $1]) << (8 * $1) }
    }

    /// Raw DEFLATE (COMPRESSION_ZLIB в Apple — это именно raw deflate без заголовка).
    private static func inflate(_ input: Data, expected: Int) throws -> Data {
        var out = Data(count: max(expected, 1))
        let written = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expected,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else { throw ZipError(reason: "deflate: \(written) из \(expected)") }
        return out.prefix(written)
    }
}
