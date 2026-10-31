import Foundation

/// Что скачать и как расшифровать.
public struct DownloadSpec: Codable, Sendable, Equatable {
    public let mediaId: String
    public let keyBase64: String
    public let chunked: Bool
    public let nonceBase64: String?
    public let macBase64: String?
    /// Размер ОТКРЫТОГО файла — по нему решается, годится ли файл в авто-очередь.
    public let plaintextSize: Int64
    public let peerLogin: String
    public let fileName: String?

    /// Спецификация для медиа-сообщения истории (у которого уже есть media_id и ключ).
    public static func of(_ m: StoredMessage, peerLogin: String) -> DownloadSpec? {
        guard let id = m.mediaId, let key = m.mediaKeyBase64 else { return nil }
        return DownloadSpec(mediaId: id, keyBase64: key, chunked: m.chunked, nonceBase64: m.mediaNonceBase64, macBase64: m.mediaMacBase64,
                            plaintextSize: m.fileSize, peerLogin: peerLogin, fileName: m.fileName)
    }
}

public struct DownloadFailedError: Error { public let reason: String }

/// Очереди скачивания — для панели «Передачи».
public struct DownloadQueues: Sendable, Equatable {
    public var manual: [DownloadSpec] = []
    public var auto: [DownloadSpec] = []
    /// Качаются прямо сейчас (по одному в каждой очереди).
    public var active: Set<String> = []
}

/**
 * Скачивание и расшифровка вложений (как core/service/MediaDownloadManager.kt).
 * Две очереди по одному файлу: ручная (тап пользователя и ожидание файла экраном)
 * и авто (мелкие < 3 МБ, фоном). Недокачанный хвост лежит на диске и докачивается
 * по Range; после сбоя — 20 с без авто-повторов. Расшифрованный файл — в кэше;
 * серверу сообщаем, что получатель файл забрал.
 */
public actor MediaDownloadManager {
    public static let autoDownloadLimitBytes: Int64 = 3 * 1024 * 1024
    private static let failCooldownMs: Int64 = 20_000

    private let api: ApiClient
    private let session: Session
    private let media: MediaFiles
    private let dirs: AppDirs
    private let log: Logger
    private let now: @Sendable () -> Int64

    private struct Lane {
        var queue: [String] = []
        var active: String?
        var task: Task<Void, Never>?
    }

    private var manual = Lane() { didSet { publishQueues() } }
    private var auto = Lane() { didSet { publishQueues() } }
    private var specs: [String: DownloadSpec] = [:]
    private var failedAt: [String: Int64] = [:]
    private var waiters: [String: [CheckedContinuation<URL, Error>]] = [:]

    /// mediaId → процент скачивания (для колец на пузырях).
    public nonisolated let progress = StateValue<[String: Double]>([:])
    /// Снимок очередей (меняется при каждой постановке, старте, завершении, отмене).
    public nonisolated let queues = StateValue(DownloadQueues())
    /// Файл скачан и расшифрован.
    public nonisolated let done = Broadcast<String>()
    public nonisolated let failed = Broadcast<String>()

    public init(api: ApiClient, session: Session, media: MediaFiles, dirs: AppDirs, log: Logger = NoopLogger(),
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.api = api
        self.session = session
        self.media = media
        self.dirs = dirs
        self.log = log
        self.now = now
    }

    private func cacheURL(_ spec: DownloadSpec) -> URL { media.cacheURL(mediaId: spec.mediaId, fileName: spec.fileName) }
    private func partURL(_ id: String) -> URL { dirs.temp.appendingPathComponent("dl_\(id).part") }

    public func isQueuedOrActive(_ id: String) -> Bool { manual.queue.contains(id) || auto.queue.contains(id) }

    /// Пользователь нажал "скачать".
    public func requestUserDownload(_ spec: DownloadSpec) {
        specs[spec.mediaId] = spec
        failedAt[spec.mediaId] = nil
        auto.queue.removeAll { $0 == spec.mediaId }
        if !manual.queue.contains(spec.mediaId) { manual.queue.append(spec.mediaId) }
        kick(manual: true)
    }

    /// Мелкий файл попал в видимую часть чата.
    public func requestAutoDownload(_ spec: DownloadSpec) {
        guard spec.plaintextSize < Self.autoDownloadLimitBytes,
              !FileManager.default.fileExists(atPath: cacheURL(spec).path),
              !isQueuedOrActive(spec.mediaId) else { return }
        if let t = failedAt[spec.mediaId], now() - t < Self.failCooldownMs { return }
        specs[spec.mediaId] = spec
        auto.queue.append(spec.mediaId)
        kick(manual: false)
    }

    /// Отменить скачивание (недокачанный хвост остаётся для докачки).
    public func cancel(_ id: String) {
        for isManual in [true, false] {
            var lane = isManual ? manual : auto
            lane.queue.removeAll { $0 == id }
            if lane.active == id { lane.task?.cancel() }
            if isManual { manual = lane } else { auto = lane }
        }
        resumeWaiters(id, .failure(CancellationError()))
    }

    /// Файл нужен экрану (просмотр): есть в кэше — сразу, иначе — в ручную очередь и ждём.
    public func ensureDownloaded(_ spec: DownloadSpec) async throws -> URL {
        let cached = cacheURL(spec)
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        return try await withCheckedThrowingContinuation { c in
            waiters[spec.mediaId, default: []].append(c)
            requestUserDownload(spec)
        }
    }

    private func publishQueues() {
        queues.value = DownloadQueues(manual: manual.queue.compactMap { specs[$0] }, auto: auto.queue.compactMap { specs[$0] },
                                      active: Set([manual.active, auto.active].compactMap { $0 }))
    }

    private func resumeWaiters(_ id: String, _ result: Result<URL, Error>) {
        for w in waiters.removeValue(forKey: id) ?? [] { w.resume(with: result) }
    }

    private func kick(manual isManual: Bool) {
        var lane = isManual ? manual : auto
        guard lane.active == nil, let next = lane.queue.first, let spec = specs[next] else { return }
        lane.active = next
        lane.task = Task { [weak self] in await self?.run(spec, manual: isManual) }
        if isManual { manual = lane } else { auto = lane }
    }

    private func finish(_ id: String, manual isManual: Bool) {
        var lane = isManual ? manual : auto
        lane.queue.removeAll { $0 == id }
        lane.active = nil
        lane.task = nil
        if isManual { manual = lane } else { auto = lane }
        var p = progress.value
        p[id] = nil
        progress.value = p
        kick(manual: isManual)
    }

    private func setProgress(_ id: String, _ percent: Double) {
        var p = progress.value
        p[id] = percent
        progress.value = p
    }

    private func run(_ spec: DownloadSpec, manual isManual: Bool) async {
        let id = spec.mediaId
        do {
            let file = try await downloadAndDecrypt(spec)
            done.emit(id)
            resumeWaiters(id, .success(file))
        } catch is CancellationError {
            log.log("Download \(id) cancelled")
        } catch {
            log.error("Download \(id) failed: \(error)")
            failedAt[id] = now()
            failed.emit(id)
            resumeWaiters(id, .failure(error))
        }
        finish(id, manual: isManual)
    }

    private func downloadAndDecrypt(_ spec: DownloadSpec) async throws -> URL {
        guard let token = session.token else { throw ApiError("error.notSignedIn") }
        let part = partURL(spec.mediaId)
        let id = spec.mediaId
        _ = try await retryWithBackoff(maxAttempts: 3) {
            try await self.api.downloadEncryptedMediaResumable(token: token, mediaId: id, dest: part) { pct in
                Task { await self.setProgress(id, pct * 0.95) }
            }
        }
        try Task.checkCancellation()
        let out = cacheURL(spec)
        let key = try unb64(spec.keyBase64)
        do {
            if spec.chunked {
                try StreamingFileCipher.decryptFile(input: part, output: out, key: key)
            } else {
                guard let n = spec.nonceBase64, let m = spec.macBase64 else { throw DownloadFailedError(reason: "нет nonce/mac у нечанкового файла") }
                let plain = try MediaCipher.decrypt(key: key, nonce: try unb64(n), mac: try unb64(m), ciphertext: try Data(contentsOf: part))
                try plain.write(to: out, options: .atomic)
            }
        } catch {
            // испорченный хвост не докачивать снова — в следующий раз с нуля
            try? FileManager.default.removeItem(at: part)
            throw error
        }
        try? FileManager.default.removeItem(at: part)
        setProgress(id, 100)
        await api.confirmMediaReceived(token: token, mediaId: id)
        return out
    }
}
