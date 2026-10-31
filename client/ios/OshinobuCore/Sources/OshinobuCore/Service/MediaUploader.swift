import Foundation

/// Ключи локализации этапов загрузки под пузырём (те же, что у Android).
public enum UploadStep {
    public static let queued = "chat.queued"
    public static let encrypting = "chat.encrypting"
    public static let uploading = "chat.uploading"
}

/// Сохранённая сессия чанковой загрузки (докачка после перезапуска).
public final class ChunkedUploadSessionStore: @unchecked Sendable {
    public struct Entry: Codable, Sendable {
        public let mediaId: String
        public let uploadId: String
        public let partSize: Int
        public let keyBase64: String
    }

    private let secure: SecureStore

    public init(secure: SecureStore) { self.secure = secure }

    private func key(_ messageId: String) -> String { "chunked_upload:\(messageId)" }

    public func get(_ messageId: String) -> Entry? {
        secure.read(key(messageId)).flatMap { try? JSONDecoder().decode(Entry.self, from: Data($0.utf8)) }
    }

    public func save(_ messageId: String, _ e: Entry) {
        if let data = try? JSONEncoder().encode(e) { secure.write(key(messageId), String(decoding: data, as: UTF8.self)) }
    }

    public func clear(_ messageId: String) { secure.delete(key(messageId)) }
}

/**
 * Шифрует и грузит один файл (как core/service/MediaUploader.kt).
 * До 20 МБ — целиком: один AES-GCM, один multipart. Больше — потоковое шифрование
 * блоками в постоянный файл и загрузка частями ПОСЛЕДОВАТЕЛЬНО с докачкой: сессия
 * сохраняется, после перезапуска сервер говорит, какие части уже есть. Каждый
 * сетевой шаг — до 5 попыток с паузой 2 → 30 с. Исходник после загрузки — в кэш
 * расшифрованных: свой файл не придётся скачивать обратно.
 */
public final class MediaUploader: @unchecked Sendable {
    private let api: ApiClient
    private let chats: ChatStore
    private let dirs: AppDirs
    private let sessions: ChunkedUploadSessionStore
    private let media: MediaFiles
    private let log: Logger
    private let stepAttempts: Int
    private let firstRetryDelay: Duration

    public init(api: ApiClient, chats: ChatStore, dirs: AppDirs, sessions: ChunkedUploadSessionStore, media: MediaFiles,
                log: Logger = NoopLogger(), stepAttempts: Int = 5, firstRetryDelay: Duration = .seconds(2)) {
        self.api = api
        self.chats = chats
        self.dirs = dirs
        self.sessions = sessions
        self.media = media
        self.log = log
        self.stepAttempts = stepAttempts
        self.firstRetryDelay = firstRetryDelay
    }

    public func encryptedTempFile(_ messageId: String) -> URL {
        let d = dirs.support.appendingPathComponent("chunked_uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("enc_\(messageId).bin")
    }

    public func upload(peerLogin: String, messageId: String, source: URL, size: Int64, fileName: String?, token: String,
                       recipientAccountId: String, onProgress: @escaping (Double) -> Void = { _ in }) async throws -> MediaRef {
        chats.updateProcessingStep(peerLogin, messageId, UploadStep.encrypting)
        let ref = size > StreamingFileCipher.streamingThresholdBytes
            ? try await uploadChunked(peerLogin, messageId, source, size, fileName, token, recipientAccountId, onProgress)
            : try await uploadWhole(peerLogin, messageId, source, size, fileName, token, recipientAccountId, onProgress)
        chats.updateMediaInfo(peerLogin, messageId, mediaId: ref.mediaId, key: ref.keyBase64, nonce: ref.nonceBase64, mac: ref.macBase64,
                              fileSize: ref.fileSize, chunked: ref.chunked)
        return ref
    }

    private func uploadWhole(_ peer: String, _ messageId: String, _ source: URL, _ size: Int64, _ fileName: String?, _ token: String,
                             _ recipient: String, _ onProgress: @escaping (Double) -> Void) async throws -> MediaRef {
        let plain = try Data(contentsOf: source, options: .mappedIfSafe)
        let encrypted = try MediaCipher.encrypt(plain)
        chats.updateProcessingStep(peer, messageId, UploadStep.uploading)
        let temp = dirs.temp.appendingPathComponent("enc_\(messageId).bin")
        try encrypted.ciphertext.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        // сбой сети (в т.ч. оборванный при смене сети запрос) — повтор с начала файла
        let mediaId = try await retryStep("whole") {
            try await self.api.uploadEncryptedMediaFile(token: token, file: temp, recipientAccountId: recipient, onProgress: onProgress)
        }
        try? plain.write(to: media.cacheURL(mediaId: mediaId, fileName: fileName))
        return MediaRef(mediaId: mediaId, keyBase64: b64(encrypted.key), nonceBase64: b64(encrypted.nonce), macBase64: b64(encrypted.mac),
                        fileSize: size, chunked: false)
    }

    private struct ChunkedSession { let mediaId: String; let uploadId: String; let partSize: Int; let key: Data; let confirmed: Set<Int> }

    private func uploadChunked(_ peer: String, _ messageId: String, _ source: URL, _ size: Int64, _ fileName: String?, _ token: String,
                               _ recipient: String, _ onProgress: @escaping (Double) -> Void) async throws -> MediaRef {
        let encFile = encryptedTempFile(messageId)
        let session: ChunkedSession
        if let resumed = await resume(messageId, encFile, token) { session = resumed } else { session = try await start(messageId, source, encFile, token) }
        chats.updateProcessingStep(peer, messageId, UploadStep.uploading)

        let total = (try FileManager.default.attributesOfItem(atPath: encFile.path)[.size] as? Int64) ?? 0
        let partSize = Int64(session.partSize)
        let partCount = Int((total + partSize - 1) / partSize)
        func partLen(_ pn: Int) -> Int { Int(min(partSize, total - Int64(pn - 1) * partSize)) }

        var confirmedBytes = session.confirmed.filter { (1...partCount).contains($0) }.reduce(Int64(0)) { $0 + Int64(partLen($1)) }
        onProgress(Double(confirmedBytes) * 100 / Double(total))
        let handle = try FileHandle(forReadingFrom: encFile)
        defer { try? handle.close() }
        for pn in 1...max(partCount, 1) where !session.confirmed.contains(pn) {
            try handle.seek(toOffset: UInt64(Int64(pn - 1) * partSize))
            let chunk = try handle.read(upToCount: partLen(pn)) ?? Data()
            let before = confirmedBytes
            try await retryStep("part \(pn)") {
                try await self.api.uploadChunkedPart(token: token, mediaId: session.mediaId, uploadId: session.uploadId, partNumber: pn, data: chunk) { pct in
                    onProgress((Double(before) + pct / 100 * Double(chunk.count)) * 100 / Double(total))
                }
            }
            confirmedBytes += Int64(chunk.count)
            onProgress(Double(confirmedBytes) * 100 / Double(total))
        }
        try await retryStep("complete") {
            try await self.api.completeChunkedUpload(token: token, mediaId: session.mediaId, uploadId: session.uploadId, recipientAccountId: recipient)
        }
        sessions.clear(messageId)
        try? FileManager.default.removeItem(at: encFile)
        let cache = media.cacheURL(mediaId: session.mediaId, fileName: fileName)
        try? FileManager.default.removeItem(at: cache)
        try? FileManager.default.copyItem(at: source, to: cache)
        return MediaRef(mediaId: session.mediaId, keyBase64: b64(session.key), nonceBase64: nil, macBase64: nil, fileSize: size, chunked: true)
    }

    /// Продолжить прерванную загрузку: сессия сохранена и зашифрованный файл на месте.
    private func resume(_ messageId: String, _ encFile: URL, _ token: String) async -> ChunkedSession? {
        guard let saved = sessions.get(messageId) else { return nil }
        guard FileManager.default.fileExists(atPath: encFile.path), let key = try? unb64(saved.keyBase64) else {
            sessions.clear(messageId)
            return nil
        }
        do {
            let confirmed = try await retryStep("list-parts") { try await self.api.listChunkedParts(token: token, mediaId: saved.mediaId, uploadId: saved.uploadId) }
            return ChunkedSession(mediaId: saved.mediaId, uploadId: saved.uploadId, partSize: saved.partSize, key: key, confirmed: confirmed)
        } catch {
            // сессия на сервере протухла — начинаем с нуля
            log.log("MediaUploader: resume of \(messageId) failed (\(error)) — starting over")
            sessions.clear(messageId)
            return nil
        }
    }

    private func start(_ messageId: String, _ source: URL, _ encFile: URL, _ token: String) async throws -> ChunkedSession {
        let key = try StreamingFileCipher.encryptFile(input: source, output: encFile)
        let size = (try FileManager.default.attributesOfItem(atPath: encFile.path)[.size] as? Int64) ?? 0
        let initResult = try await retryStep("init") { try await self.api.initChunkedUpload(token: token, sizeBytes: size) }
        sessions.save(messageId, .init(mediaId: initResult.mediaId, uploadId: initResult.uploadId, partSize: initResult.partSize, keyBase64: b64(key)))
        return ChunkedSession(mediaId: initResult.mediaId, uploadId: initResult.uploadId, partSize: initResult.partSize, key: key, confirmed: [])
    }

    /// Один сетевой шаг: до [stepAttempts] попыток с нарастающей паузой.
    @discardableResult
    private func retryStep<T>(_ label: String, _ step: () async throws -> T) async throws -> T {
        var delay = firstRetryDelay
        var attempt = 1
        while true {
            do { return try await step() }
            catch is CancellationError { throw CancellationError() }
            catch {
                if attempt >= stepAttempts {
                    log.error("MediaUploader[\(label)] failed after \(attempt) attempts: \(error)")
                    throw error
                }
                log.log("MediaUploader[\(label)] attempt \(attempt)/\(stepAttempts) failed: \(error) — retry")
                try await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(30))
                attempt += 1
            }
        }
    }
}
