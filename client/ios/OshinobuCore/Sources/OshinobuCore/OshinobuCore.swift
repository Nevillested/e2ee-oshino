import Foundation
import Network

/// Журнал в файл documents/debug_log.txt (≤ 1 МБ, при переполнении остаётся вторая половина).
public final class FileLogger: Logger, @unchecked Sendable {
    public let file: URL
    private let queue = DispatchQueue(label: "oshinobu.logger")
    private let maxBytes: Int
    /// Ошибка — повод отправить журнал (как CrashReporter на Android).
    public var onError: (@Sendable () -> Void)?

    public init(dirs: AppDirs, maxBytes: Int = 1024 * 1024) {
        file = dirs.documents.appendingPathComponent("debug_log.txt")
        self.maxBytes = maxBytes
    }

    public func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async { [file, maxBytes] in
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: file)
            }
            if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > maxBytes,
               let data = try? Data(contentsOf: file) {
                try? data.suffix(maxBytes / 2).write(to: file)
            }
        }
    }

    public func error(_ message: String) {
        log(message)
        onError?()
    }

    /// Дождаться, пока всё записанное ляжет в файл.
    public func flush() { queue.sync {} }
}

/// Файлы вложений и их удаление вместе с сообщениями.
public final class MediaFiles: MessageCleanup, @unchecked Sendable {
    private let dirs: AppDirs

    public init(dirs: AppDirs) { self.dirs = dirs }

    /// Расшифрованная копия вложения (кэш — система может стереть, тогда скачаем снова).
    public func cacheURL(mediaId: String, fileName: String?) -> URL {
        let ext = fileName.map { ($0 as NSString).pathExtension }.flatMap { $0.isEmpty ? nil : $0 } ?? "bin"
        return dirs.temp.appendingPathComponent("media_cache_\(mediaId).\(ext)")
    }

    public func purgeAll(_ messages: [StoredMessage]) {
        let fm = FileManager.default
        for m in messages {
            if let id = m.mediaId { try? fm.removeItem(at: cacheURL(mediaId: id, fileName: m.fileName)) }
            for p in [m.localPreviewPath, m.localSourcePath].compactMap({ $0 }) { try? fm.removeItem(atPath: p) }
        }
    }
}

/**
 * Ядро iOS-клиента в сборе (как OshinobuCore.kt): хранилища, сеть, очереди,
 * роутер. Платформа даёт только [RouterHost] (звук, уведомления, что открыто).
 */
public final class OshinobuCore: @unchecked Sendable {
    public let dirs: AppDirs
    public let secure: SecureStore
    public let prefs: Prefs
    public let logger: FileLogger
    public let api: ApiClient
    public let session: Session
    public let keys: KeyStore
    public let sessions: SessionStore
    public let chats: ChatStore
    public let media: MediaFiles
    public let ws: WebSocketClient
    public let acks: AckRegistry
    public let sendQueue: SendQueueProcessor
    public let sendLock = KeyedMutex()
    public let messenger: PeerMessenger
    public let router: MessageRouter
    public let deviceSetup: DeviceSetup
    public let uploader: MediaUploader
    public let downloads: MediaDownloadManager
    public let calls: CallManager
    public let chatService: ChatService
    public let appLock: AppLockStore
    public let avatars: Avatars
    public let wallpapers: Wallpapers
    public let stickers: Stickers

    /// Сессия запущена и не завершена.
    public let sessionActive = StateValue(false)

    public init(dirs: AppDirs = .standard(), secure: SecureStore = KeychainSecureStore(), prefs: Prefs = UserDefaultsPrefs(),
                config: ApiConfig = ApiConfig(), host: RouterHost, rtcEngine: RtcEngine) {
        self.dirs = dirs
        self.secure = secure
        self.prefs = prefs
        let logger = FileLogger(dirs: dirs)
        self.logger = logger
        api = ApiClient(config: config)
        session = Session(prefs: prefs)
        keys = KeyStore(secure: secure)
        sessions = SessionStore(secure: secure)
        chats = ChatStore(dirs: dirs)
        media = MediaFiles(dirs: dirs)
        ws = WebSocketClient(api: api, log: { logger.log($0) })
        acks = AckRegistry(transport: ws)
        sendQueue = SendQueueProcessor(store: SendQueueStore(secure: secure), transport: ws, acks: acks, chats: chats, log: logger)
        let peerAccounts = PeerAccountStore(secure: secure)
        let peerIdentities = PeerIdentityStore(secure: secure)
        messenger = PeerMessenger(api: api, session: session, keys: keys, sessions: sessions, peerAccounts: peerAccounts,
                                  peerIdentities: peerIdentities, chats: chats, queue: sendQueue, sendLock: sendLock, log: logger)
        router = MessageRouter(transport: ws, api: api, session: session, keys: keys, sessions: sessions, peerAccounts: peerAccounts,
                               peerIdentities: peerIdentities, chats: chats, prefs: prefs, queue: sendQueue, cleanup: media,
                               sendLock: sendLock, host: host, log: logger)
        deviceSetup = DeviceSetup(api: api, keys: keys, log: logger)
        uploader = MediaUploader(api: api, chats: chats, dirs: dirs, sessions: ChunkedUploadSessionStore(secure: secure), media: media, log: logger)
        downloads = MediaDownloadManager(api: api, session: session, media: media, dirs: dirs, log: logger)
        calls = CallManager(signaling: ws, messenger: messenger, router: router, api: api, session: session, chats: chats, engine: rtcEngine, log: logger)
        chatService = ChatService(chats: chats, messenger: messenger, router: router, cleanup: media)
        appLock = AppLockStore(secure: secure)
        avatars = Avatars(api: api, session: session, dirs: dirs)
        wallpapers = Wallpapers(api: api, session: session, dirs: dirs)
        stickers = Stickers(api: api, session: session, dirs: dirs)
        installCrashReporter()
        watchNetwork()
    }

    private let pathMonitor = NWPathMonitor()
    private var currentInterface: NWInterface.InterfaceType?

    /**
     * Сеть пропала/появилась/сменилась (Wi-Fi ↔ сотовая) — WebSocket переподключается
     * сразу, а не по таймеру; при смене интерфейса старые соединения мертвы — обрываем
     * их (как watchNetwork на Android).
     */
    private func watchNetwork() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            guard path.status == .satisfied else {
                self.currentInterface = nil
                self.ws.onNetworkLost()
                return
            }
            let iface = [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet].first { path.usesInterfaceType($0) } ?? .other
            let previous = self.currentInterface
            self.currentInterface = iface
            if let previous, previous != iface {
                self.logger.log("Network switched \(previous) -> \(iface) — dropping connections, reconnecting")
                self.api.dropConnections()
                self.ws.onNetworkSwitched()
            } else {
                self.ws.onNetworkAvailable()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "oshinobu.network"))
    }

    /**
     * Ошибка в работе — журнал в feedback (kind=auto_crash), не чаще раза в
     * 30 минут (отметка в prefs переживает перезапуск); после отправки журнал
     * очищается. Как CrashReporter на Android.
     */
    private func installCrashReporter() {
        logger.onError = { [weak self] in
            guard let self else { return }
            Task { await self.sendErrorReport() }
        }
    }

    private func sendErrorReport() async {
        let key = "crash_reporter_last_sent_at_ms"
        let at = Int64(Date().timeIntervalSince1970 * 1000)
        if let last = prefs.long(key), at - last < 30 * 60_000 { return }
        guard let token = session.token else { return }
        logger.flush()
        guard let text = try? String(contentsOf: logger.file, encoding: .utf8), !text.isEmpty else { return }
        do {
            try await api.reportCrashLog(token: token, logText: String(text.suffix(500_000)))
            prefs.set(key, at)
            try? FileManager.default.removeItem(at: logger.file)
        } catch {
            // нет сети — журнал остаётся до следующей ошибки
        }
    }

    /// Запуск после входа или при старте с сохранённой сессией. Повторный вызов безопасен.
    public func startSession() async throws {
        guard let token = session.token else { return }
        try await deviceSetup.ensureDeviceRegistered(token: token)
        guard let deviceId = keys.deviceId() else { return }
        failOrphanedSending()
        router.start()
        await calls.start()
        sendQueue.start()
        ws.connect(token: token, deviceId: deviceId)
        sessionActive.value = true
        followProfileChanges()
        await deviceSetup.ensurePrekeysTopped(token: token, deviceId: deviceId)
        await syncFromServer(token: token)
        await registerPushTokens()
    }

    /// Токены APNs приходят от системы когда угодно (и до входа) — храним и отправляем,
    /// как только есть сессия. Сервер нового токена не знает, пока не отправили.
    public func setPushToken(_ hex: String, voip: Bool) {
        let key = voip ? "apns_voip_token" : "apns_alert_token"
        guard prefs.string(key) != hex else { return }
        prefs.set(key, hex)
        prefs.remove("apns_sent")
        Task { await registerPushTokens() }
    }

    private func registerPushTokens() async {
        guard prefs.bool("apns_sent") != true, let token = session.token, let deviceId = keys.deviceId() else { return }
        let alert = prefs.string("apns_alert_token"), voip = prefs.string("apns_voip_token")
        guard alert != nil || voip != nil else { return }
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        if await api.registerApnsTokens(token: token, deviceId: deviceId, alert: alert, voip: voip, sandbox: sandbox) {
            prefs.set("apns_sent", true)
            logger.log("Push: APNs tokens registered (alert=\(alert != nil) voip=\(voip != nil))")
        }
    }

    /// Отклонить звонок из пуша, когда связи с сервером ещё нет (как кнопка уведомления на Android).
    public func declinePendingCall(callId: String, busy: Bool = false) async {
        guard let token = session.token, let deviceId = keys.deviceId() else { return }
        _ = await api.declineCall(token: token, deviceId: deviceId, callId: callId, busy: busy)
    }

    /// Поднять сохранённую сессию; false — входа нет или сервер его больше не признаёт.
    public func resumeSession() async -> Bool {
        guard let token = session.token, keys.deviceId() != nil else { return false }
        if await api.checkSession(token: token) == false {
            signOutLocally()
            return false
        }
        do { try await startSession() } catch { logger.error("startSession failed: \(error)") }
        return true
    }

    private var profileTask: Task<Void, Never>?

    /// profile_updated — фото собеседника перезапрашивается.
    private func followProfileChanges() {
        guard profileTask == nil else { return }
        profileTask = Task { [weak self] in
            guard let self else { return }
            for await change in ws.profileChanges.stream() where change.field == "avatar" { await avatars.invalidate(change.accountId) }
        }
        Task { [weak self] in
            guard let self else { return }
            await wallpapers.sync()
            for await accountId in ws.wallpaperChanges.stream() { await wallpapers.refresh(accountId) }
        }
    }

    /// Мьюты и блокировки с сервера.
    private func syncFromServer(token: String) async {
        chats.syncMutedFromServer(Set(await api.getMutedChats(token: token)))
        if let b = await api.getBlockedContacts(token: token) {
            chats.syncBlockedFromServer(blockedByMe: Set(b.blockedByMe), blockingMe: Set(b.blockingMe))
        }
    }

    public func login(login: String, password: String, totpCode: String) async throws {
        let result = try await api.login(login: login, password: password, totpCode: totpCode)
        session.token = result.token
        session.login = login
        if let me = await api.getMyAccountInfo(token: result.token) { session.accountId = me.accountId }
        try await startSession()
    }

    /// Выход: ключи, сессии и переписка стираются (как на Android).
    public func signOutLocally() {
        ws.disconnect()
        sessionActive.value = false
        keys.wipeAll()
        chats.wipeAll()
        session.token = nil
        session.login = nil
        session.accountId = nil
        prefs.remove("apns_sent") // следующий вход — новое устройство, токены отправить заново
    }

    public func logout() async {
        if let token = session.token, let deviceId = keys.deviceId() { _ = await api.unregisterPushToken(token: token, deviceId: deviceId) }
        signOutLocally()
    }

    /// Отправить текст так же, как экран чата Android (ChatService.sendText).
    public func sendText(_ text: String, to peer: ChatSummary, replyTo: StoredMessage? = nil) async {
        let inner = InnerMessage.text(text, replyTo: replyTo?.messageId, replyPreview: replyTo.map { String($0.text.prefix(120)) })
        var m = StoredMessage(messageId: inner.messageId, text: text, isMine: true, timestamp: inner.sentAt)
        m.status = MessageStatus.sending
        m.replyToMessageId = inner.replyToMessageId
        m.replyToPreview = inner.replyToPreview
        chats.addMessage(peer.peerLogin, m, accountId: peer.lastKnownAccountId)
        guard let deviceId = peer.lastKnownDeviceId else {
            chats.updateMessageStatus(peer.peerLogin, m.messageId, MessageStatus.failed)
            return
        }
        do { try await messenger.send(to: deviceId, inner, peerLogin: peer.peerLogin) }
        catch {
            logger.log("sendText FAILED to=\(deviceId): \(error)")
            chats.updateMessageStatus(peer.peerLogin, m.messageId, MessageStatus.failed)
        }
    }

    /// Файл к отправке: путь (копия в каталоге отправок), имя и вид.
    public struct OutgoingFile: Sendable {
        public let url: URL
        public let name: String
        public let isVideo: Bool
        public let isFile: Bool
        public init(url: URL, name: String, isVideo: Bool, isFile: Bool) {
            self.url = url
            self.name = name
            self.isVideo = isVideo
            self.isFile = isFile
        }
    }

    /// Предел вложения — как на Android.
    public static let maxAttachmentBytes: Int64 = 500 * 1024 * 1024

    /**
     * Отправка файлов, как ChatService.sendMedia на Android: один файл без подписи —
     * 'media'; с подписью или несколько — альбом 'media_group' (подпись — отдельное
     * текстовое сообщение той же группы, собеседнику всё — одним конвертом). Пузыри
     * появляются сразу; файлы грузятся по очереди. Возвращает отклонённые по размеру.
     */
    @discardableResult
    public func sendMedia(_ files: [OutgoingFile], to peer: ChatSummary, caption: String = "") async -> [OutgoingFile] {
        func size(_ f: OutgoingFile) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: f.url.path)[.size] as? Int64) ?? 0 }
        let accepted = files.filter { size($0) <= Self.maxAttachmentBytes }
        let rejected = files.filter { size($0) > Self.maxAttachmentBytes }
        guard !accepted.isEmpty else { return rejected }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let hasCaption = !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let groupId = (accepted.count + (hasCaption ? 1 : 0)) > 1 ? "grp_\(UUID().uuidString.lowercased())" : nil
        var textMessageId: String?
        if hasCaption {
            let t = InnerMessage.text(caption)
            textMessageId = t.messageId
            var tm = StoredMessage(messageId: t.messageId, text: caption, isMine: true, timestamp: nowMs)
            tm.status = MessageStatus.sending
            tm.groupId = groupId
            chats.addMessage(peer.peerLogin, tm, accountId: peer.lastKnownAccountId)
        }
        var items: [(OutgoingFile, String, Int64)] = []
        for f in accepted {
            let id = UUID().uuidString.lowercased()
            let sz = size(f)
            var m = StoredMessage(messageId: id, text: "", isMine: true, timestamp: nowMs)
            m.isMedia = true
            m.isVideo = f.isVideo
            m.isFile = f.isFile
            m.fileName = f.name
            m.fileSize = sz
            m.chunked = sz > StreamingFileCipher.streamingThresholdBytes
            m.status = MessageStatus.sending
            m.processingStep = UploadStep.queued
            m.localPreviewPath = (f.isFile || f.isVideo) ? nil : f.url.path
            m.localSourcePath = f.url.path
            m.groupId = groupId
            items.append((f, id, sz))
            chats.addMessage(peer.peerLogin, m, accountId: peer.lastKnownAccountId)
        }

        let ids = [textMessageId].compactMap { $0 } + items.map(\.1)
        func fail() { for id in ids { chats.updateMessageStatus(peer.peerLogin, id, MessageStatus.failed) } }
        guard let token = session.token, let deviceId = peer.lastKnownDeviceId, let account = peer.lastKnownAccountId else {
            fail()
            return rejected
        }
        await trackedSend(ids) { [self] in
            do {
                var refs: [(OutgoingFile, String, MediaRef)] = []
                for (f, id, sz) in items {
                    let ref = try await uploader.upload(peerLogin: peer.peerLogin, messageId: id, source: f.url, size: sz, fileName: f.name,
                                                        token: token, recipientAccountId: account) { [weak self] pct in self?.setUploadProgress(id, pct) }
                    refs.append((f, id, ref))
                }
                if let groupId {
                    let files: [[String: JSONValue]] = refs.map { f, id, ref in
                        var body = InnerMessage.media(ref, fileName: f.name, isFile: f.isFile, isVideo: f.isVideo, messageId: id).bodyJSON()
                        body["message_id"] = .string(id)
                        return body
                    }
                    let group = InnerMessage.mediaGroup(groupId: groupId, files: files, caption: hasCaption ? caption : nil, textMessageId: textMessageId)
                    try await messenger.send(to: deviceId, group, peerLogin: peer.peerLogin, trackStatus: false) { [chats] in
                        for id in ids { chats.updateMessageStatus(peer.peerLogin, id, MessageStatus.sent) }
                    }
                } else if case let (f, id, ref)? = refs.first {
                    try await messenger.send(to: deviceId, .media(ref, fileName: f.name, isFile: f.isFile, isVideo: f.isVideo, messageId: id), peerLogin: peer.peerLogin)
                }
            } catch {
                logger.log("sendMedia FAILED to=\(deviceId): \(error)")
                fail()
            }
        }
        return rejected
    }

    /// Недавно отправленные стикеры (новые первыми, до 15) — первая вкладка панели.
    public var recentStickers: [String] { prefs.stringList("recent_stickers") ?? [] }

    /// Стикер — только его id; получатель берёт файл из пака на сервере.
    public func sendSticker(_ stickerId: String, to peer: ChatSummary) async {
        prefs.set("recent_stickers", Array(([stickerId] + recentStickers.filter { $0 != stickerId }).prefix(15)))
        let inner = InnerMessage.sticker(stickerId)
        var m = StoredMessage(messageId: inner.messageId, text: "", isMine: true, timestamp: inner.sentAt)
        m.stickerId = stickerId
        m.status = MessageStatus.sending
        chats.addMessage(peer.peerLogin, m, accountId: peer.lastKnownAccountId)
        guard let deviceId = peer.lastKnownDeviceId else { return chats.updateMessageStatus(peer.peerLogin, m.messageId, MessageStatus.failed) }
        do { try await messenger.send(to: deviceId, inner, peerLogin: peer.peerLogin) }
        catch { chats.updateMessageStatus(peer.peerLogin, m.messageId, MessageStatus.failed) }
    }

    /// Очистить кэш: расшифрованные вложения и паки стикеров (скачаются заново). Возвращает освобождённые байты.
    @discardableResult
    public func clearCache() async -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0
        for f in (try? fm.contentsOfDirectory(at: dirs.temp, includingPropertiesForKeys: [.fileSizeKey])) ?? [] where f.lastPathComponent.hasPrefix("media_cache_") {
            freed += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? fm.removeItem(at: f)
        }
        await stickers.clearCache()
        logger.log("Settings media cache cleared freedBytes=\(freed)")
        return freed
    }

    /// Удалить аккаунт на сервере и всё локально; false — не вышло (нет связи).
    public func deleteAccount() async -> Bool {
        guard let token = session.token, (try? await api.deleteAccount(token: token)) == true else { return false }
        signOutLocally()
        return true
    }

    /**
     * Свои сообщения, застрявшие в «отправляется» без конверта в очереди (процесс
     * выгрузили посреди шифрования/загрузки), — «не отправлено»: их можно повторить.
     * Те, чей конверт уже в очереди, уйдут сами при подключении.
     */
    private func failOrphanedSending() {
        let queued = Set(sendQueue.pendingIds())
        for chat in chats.knownPeers() {
            for m in chats.messages(chat.peerLogin) where m.isMine && (m.status == MessageStatus.sending || m.status == MessageStatus.queued)
                && !queued.contains(m.messageId) {
                logger.log("Orphaned sending message \(m.messageId) — marked failed")
                chats.updateMessageStatus(chat.peerLogin, m.messageId, MessageStatus.failed)
            }
        }
    }

    /// «Повторить отправку» упавшего вложения — из сохранённого исходника, с тем же message_id.
    public func retryMedia(_ m: StoredMessage, to peer: ChatSummary) async {
        guard m.isMine, m.isMedia, let path = m.localSourcePath, FileManager.default.fileExists(atPath: path),
              let token = session.token, let deviceId = peer.lastKnownDeviceId, let account = peer.lastKnownAccountId else { return }
        chats.updateMessageStatus(peer.peerLogin, m.messageId, MessageStatus.sending)
        await trackedSend([m.messageId]) { [self] in
            do {
                let fileName = m.fileName ?? (m.isVoice ? "voice.m4a" : m.isVideoNote ? "video.mp4" : "file")
                let ref = try await uploader.upload(peerLogin: peer.peerLogin, messageId: m.messageId, source: URL(fileURLWithPath: path),
                                                    size: m.fileSize, fileName: fileName, token: token, recipientAccountId: account) { [weak self] pct in
                    self?.setUploadProgress(m.messageId, pct)
                }
                let inner: InnerMessage
                if m.isVoice { inner = .voice(ref, durationMs: m.durationMs ?? 0, messageId: m.messageId) }
                else if m.isVideoNote { inner = .videoNote(ref, durationMs: m.durationMs ?? 0, messageId: m.messageId) }
                else { inner = .media(ref, fileName: fileName, isFile: m.isFile, isVideo: m.isVideo, messageId: m.messageId) }
                try await messenger.send(to: deviceId, inner, peerLogin: peer.peerLogin)
            } catch {
                logger.log("retryMedia FAILED \(m.messageId): \(error)")
                chats.updateMessageStatus(peer.peerLogin, m.messageId, MessageStatus.failed)
            }
        }
    }

    /// «Повторить отправку» упавшего текста — тот же message_id (получатель погасит дубль).
    public func retryText(_ m: StoredMessage, to peer: ChatSummary) async {
        guard m.isMine, !m.isMedia, !m.isSticker, let deviceId = peer.lastKnownDeviceId else { return }
        chats.updateMessageStatus(peer.peerLogin, m.messageId, MessageStatus.sending)
        let inner = InnerMessage(messageId: m.messageId, type: MessageType.text, sentAt: m.timestamp, body: m.text,
                                 replyToMessageId: m.replyToMessageId, replyToPreview: m.replyToPreview)
        do { try await messenger.send(to: deviceId, inner, peerLogin: peer.peerLogin) }
        catch { chats.updateMessageStatus(peer.peerLogin, m.messageId, MessageStatus.failed) }
    }

    /// Голосовое (или видеосообщение): файл записи, длительность — в конверте.
    public func sendRecorded(_ source: URL, durationMs: Int64, videoNote: Bool, to peer: ChatSummary) async {
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
        let messageId = UUID().uuidString.lowercased()
        var m = StoredMessage(messageId: messageId, text: "", isMine: true, timestamp: Int64(Date().timeIntervalSince1970 * 1000))
        m.isMedia = true
        m.isVoice = !videoNote
        m.isVideoNote = videoNote
        m.durationMs = durationMs
        m.fileSize = size
        m.status = MessageStatus.sending
        m.processingStep = UploadStep.queued
        m.localSourcePath = source.path
        chats.addMessage(peer.peerLogin, m, accountId: peer.lastKnownAccountId)
        guard let token = session.token, let deviceId = peer.lastKnownDeviceId, let account = peer.lastKnownAccountId else {
            return chats.updateMessageStatus(peer.peerLogin, messageId, MessageStatus.failed)
        }
        await trackedSend([messageId]) { [self] in
            do {
                let ref = try await uploader.upload(peerLogin: peer.peerLogin, messageId: messageId, source: source, size: size,
                                                    fileName: videoNote ? "video.mp4" : "voice.m4a", token: token, recipientAccountId: account) { [weak self] pct in
                    self?.setUploadProgress(messageId, pct)
                }
                let inner = videoNote ? InnerMessage.videoNote(ref, durationMs: durationMs, messageId: messageId)
                    : InnerMessage.voice(ref, durationMs: durationMs, messageId: messageId)
                try await messenger.send(to: deviceId, inner, peerLogin: peer.peerLogin)
            } catch {
                logger.log("sendRecorded FAILED to=\(deviceId): \(error)")
                chats.updateMessageStatus(peer.peerLogin, messageId, MessageStatus.failed)
            }
        }
    }

    /// message_id → процент выгрузки вложения (пузырь и «Передачи»).
    public let uploadProgress = StateValue<[String: Double]>([:])
    private let uploadProgressLock = NSLock()

    /// Целые проценты: на каждый отправленный пакет экран не перерисовываем.
    private func setUploadProgress(_ id: String, _ percent: Double?) {
        uploadProgressLock.sync {
            var p = uploadProgress.value
            p[id] = percent.map { min(100, $0.rounded(.down)) }
            uploadProgress.value = p
        }
    }

    /// Идущие отправки вложений: message_id → задача (отмена из «Передач»).
    private var sendJobs: [String: Task<Void, Never>] = [:]
    private let sendJobsLock = NSLock()

    private func trackedSend(_ ids: [String], _ body: @escaping () async -> Void) async {
        let job = Task { await body() }
        sendJobsLock.sync { for id in ids { sendJobs[id] = job } }
        await job.value
        sendJobsLock.sync { for id in ids where sendJobs[id] == job { sendJobs[id] = nil } }
        for id in ids { setUploadProgress(id, nil) }
    }

    /// Свои сообщения в пути: вложения, которые грузятся сейчас (message_id) — для «Передач».
    public func activeSendIds() -> Set<String> { sendJobsLock.sync { Set(sendJobs.keys) } }

    /**
     * Отменить исходящее (панель «Передачи», как cancelOutgoing на Android): загрузка
     * остановлена, конверт снят с очереди, сообщение удалено у себя.
     */
    public func cancelOutgoing(_ peerLogin: String, _ messageIds: [String]) {
        let jobs = sendJobsLock.sync { messageIds.compactMap { sendJobs.removeValue(forKey: $0) } }
        jobs.forEach { $0.cancel() }
        sendQueue.drop(messageIds: Set(messageIds))
        chats.deleteMessages(peerLogin, messageIds)
    }

    /// Открыть чат по логину (поиск): устройство собеседника и запись в списке.
    public func openChat(login: String) async throws -> ChatSummary {
        guard let token = session.token else { throw ApiError("error.notSignedIn") }
        let devices = try await api.getDevicesByLogin(token: token, login: login)
        guard let deviceId = devices.devices.first?["device_id"]?.string else { throw ApiError("error.userHasNoDevices") }
        chats.ensurePeer(login, accountId: devices.accountId, deviceId: deviceId)
        chats.setLastKnownDeviceId(login, deviceId: deviceId)
        return chats.peer(login) ?? ChatSummary(peerLogin: login, lastKnownAccountId: devices.accountId, lastKnownDeviceId: deviceId)
    }

    private var lastCallReportAt: Int64?
    private let reportLock = NSLock()

    /**
     * Звонок сработал плохо: отчёт с последней частью журнала — в feedback
     * (kind=call_problem), не чаще раза в минуту (сбои одного звонка идут пачкой).
     */
    public func reportCallProblem(_ summary: String) {
        let at = Int64(Date().timeIntervalSince1970 * 1000)
        let joined: Bool = reportLock.sync {
            if let last = lastCallReportAt, at - last < 60_000 { return true }
            lastCallReportAt = at
            return false
        }
        if joined {
            logger.log("Call problem (joined to the previous report): \(summary)")
            return
        }
        logger.log("Call problem reported: \(summary)")
        logger.flush()
        let journal = (try? String(contentsOf: logger.file, encoding: .utf8)).map { String($0.suffix(150_000)) } ?? ""
        guard let token = session.token else { return }
        Task {
            do { try await api.reportCrashLog(token: token, logText: "=== CALL PROBLEM ===\n\(summary)\n=== журнал ===\n\(journal)", kind: "call_problem") }
            catch { logger.log("Call problem report not delivered: \(error)") }
        }
    }

    /// Мьют чата — у себя и на сервере (пуши о нём не приходят).
    public func setMuted(_ peer: ChatSummary, _ muted: Bool) async throws {
        guard let token = session.token, let account = peer.lastKnownAccountId else { return }
        if muted { try await api.muteChat(token: token, peerAccountId: account) } else { try await api.unmuteChat(token: token, peerAccountId: account) }
        chats.setChatMuted(peer.peerLogin, muted: muted)
    }

    /// Блокировка собеседника — на сервере (он перестаёт видеть профиль и не может писать).
    public func setBlocked(_ peer: ChatSummary, _ blocked: Bool) async throws {
        guard let token = session.token, let account = peer.lastKnownAccountId else { return }
        if blocked { try await api.blockContact(token: token, peerAccountId: account) } else { try await api.unblockContact(token: token, peerAccountId: account) }
        chats.setChatBlockedByMe(peer.peerLogin, blocked: blocked)
        if let b = await api.getBlockedContacts(token: token) { chats.syncBlockedFromServer(blockedByMe: Set(b.blockedByMe), blockingMe: Set(b.blockingMe)) }
    }

    /// Чат открыт и виден — квитанции о прочтении за чужие сообщения, счётчик — в ноль.
    public func markChatRead(_ peer: ChatSummary) async {
        chats.clearUnread(peer.peerLogin)
        let unreadIds = chats.messages(peer.peerLogin).filter { !$0.isMine && !$0.readReceiptSent && !$0.isCallLog }.map(\.messageId)
        guard !unreadIds.isEmpty, let deviceId = peer.lastKnownDeviceId else { return }
        await messenger.sendControl(to: deviceId, .readReceipt(targets: unreadIds))
        chats.markReadReceiptsSent(peer.peerLogin, unreadIds)
    }
}
