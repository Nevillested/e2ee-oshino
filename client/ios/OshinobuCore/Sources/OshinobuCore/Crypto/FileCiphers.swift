import CryptoKit
import Foundation

// Шифрование вложений (как core/crypto/FileCiphers.kt).
//
// Мелкие файлы (≤ 20 МБ) — целиком одним AES-256-GCM: ключ/nonce/mac едут в конверте.
// Большие — потоково блоками по 4 МБ (формат зафиксирован):
//   блок:  [4 байта BE = len(ciphertext+tag)] [ciphertext] [tag(16)]
//   nonce  = 0x00000000 || uint64_be(index)
//   AAD    = UTF-8("<index>:<0|1>"), 1 = последний блок; файл, кратный 4 МБ,
//            завершается ПУСТЫМ последним блоком.

public struct EncryptedFile {
    public let key: Data
    public let nonce: Data
    public let mac: Data
    public let ciphertext: Data
}

public enum MediaCipher {
    public static func encrypt(_ plain: Data) throws -> EncryptedFile {
        let key = randomBytes(32)
        let box = try AesGcm.encrypt(key: key, plaintext: plain)
        return EncryptedFile(key: key, nonce: box.nonce, mac: box.mac, ciphertext: box.ciphertext)
    }

    public static func decrypt(key: Data, nonce: Data, mac: Data, ciphertext: Data) throws -> Data {
        try AesGcm.decrypt(key: key, box: SealedBox(nonce: nonce, ciphertext: ciphertext, mac: mac))
    }
}

public enum FileCipherError: Error {
    case corrupted(String)
}

public enum StreamingFileCipher {
    public static let chunkSize = 4 * 1024 * 1024
    /// Порог, с которого файл шифруется потоково и грузится частями.
    public static let streamingThresholdBytes: Int64 = 20 * 1024 * 1024
    private static let tagBytes = 16
    private static let maxBlock = 64 * 1024 * 1024 + 1024

    /// Шифрует [input] в [output], возвращает случайный 32-байтный ключ файла.
    public static func encryptFile(input: URL, output: URL, onProgress: ((Double) -> Void)? = nil) throws -> Data {
        let key = randomBytes(32)
        let symmetric = SymmetricKey(data: key)
        let total = (try? FileManager.default.attributesOfItem(atPath: input.path)[.size] as? Int64) ?? 0
        FileManager.default.createFile(atPath: output.path, contents: nil)
        do {
            let ins = try FileHandle(forReadingFrom: input)
            defer { try? ins.close() }
            let out = try FileHandle(forWritingTo: output)
            defer { try? out.close() }
            var index: UInt64 = 0
            var processed: Int64 = 0
            while true {
                let chunk = try readFully(ins, count: chunkSize)
                let isLast = chunk.count < chunkSize
                let sealed = try AES.GCM.seal(chunk, using: symmetric, nonce: try nonce(for: index), authenticating: aad(index, isLast))
                var block = Data()
                block.append(bigEndian32(UInt32(sealed.ciphertext.count + tagBytes)))
                block.append(sealed.ciphertext)
                block.append(sealed.tag)
                try out.write(contentsOf: block)
                index += 1
                processed += Int64(chunk.count)
                onProgress?(total == 0 ? 100 : Double(processed) * 100 / Double(total))
                if isLast { break }
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return key
    }

    /// Бросает [FileCipherError.corrupted] на обрыв, подмену или неверный ключ.
    public static func decryptFile(input: URL, output: URL, key: Data, onProgress: ((Double) -> Void)? = nil) throws {
        let symmetric = SymmetricKey(data: key)
        let total = (try? FileManager.default.attributesOfItem(atPath: input.path)[.size] as? Int64) ?? 0
        FileManager.default.createFile(atPath: output.path, contents: nil)
        do {
            let ins = try FileHandle(forReadingFrom: input)
            defer { try? ins.close() }
            let out = try FileHandle(forWritingTo: output)
            defer { try? out.close() }
            var offset: Int64 = 0
            var index: UInt64 = 0
            var sawLast = false
            while offset < total {
                let header = try readFully(ins, count: 4)
                guard header.count == 4 else { throw FileCipherError.corrupted("неполный заголовок блока") }
                let len = Int(header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                offset += 4
                guard len >= tagBytes, len <= maxBlock else { throw FileCipherError.corrupted("недопустимая длина блока \(len)") }
                let payload = try readFully(ins, count: len)
                guard payload.count == len else { throw FileCipherError.corrupted("блок обрезан") }
                offset += Int64(len)
                let (plain, isLast) = try openBlock(symmetric, index: index, payload: payload)
                try out.write(contentsOf: plain)
                sawLast = isLast
                index += 1
                onProgress?(total == 0 ? 100 : Double(offset) * 100 / Double(total))
            }
            guard sawLast else { throw FileCipherError.corrupted("нет завершающего блока") }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func openBlock(_ key: SymmetricKey, index: UInt64, payload: Data) throws -> (Data, Bool) {
        let ciphertext = payload.prefix(payload.count - tagBytes)
        let tag = payload.suffix(tagBytes)
        for isLast in [false, true] {
            if let box = try? AES.GCM.SealedBox(nonce: nonce(for: index), ciphertext: ciphertext, tag: tag),
               let plain = try? AES.GCM.open(box, using: key, authenticating: aad(index, isLast)) {
                return (plain, isLast)
            }
        }
        throw FileCipherError.corrupted("блок \(index) не расшифровывается (обрыв, подмена или неверный ключ)")
    }

    private static func nonce(for index: UInt64) throws -> AES.GCM.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: index.bigEndian) { bytes.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: bytes)
    }

    private static func aad(_ index: UInt64, _ isLast: Bool) -> Data { Data("\(index):\(isLast ? 1 : 0)".utf8) }

    private static func bigEndian32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

    private static func readFully(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let part = try handle.read(upToCount: count - data.count), !part.isEmpty else { break }
            data.append(part)
        }
        return data
    }
}
