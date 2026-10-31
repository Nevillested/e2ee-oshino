import Foundation

/// Побочные эффекты входящих, зависящие от платформы.
public protocol RouterHost: AnyObject, Sendable {
    /// Логин чата, открытого прямо сейчас на экране (или nil).
    var openChatPeerLogin: String? { get }
    var isAppInForeground: Bool { get }
    func playMessageSound()
    /// Общее уведомление "новое сообщение" без содержимого — когда приложение свёрнуто.
    func showBackgroundMessageNotification()
}

public struct IncomingReaction: Sendable { public let peerLogin: String; public let messageId: String }
public struct IncomingDelete: Sendable { public let peerLogin: String; public let targetIds: [String] }

/// Владелец устройства-отправителя.
public struct DeviceOwnerRef: Sendable { public let accountId: String; public let login: String }

/// Стирает локальные файлы удалённых сообщений (вложения, превью).
public protocol MessageCleanup: Sendable {
    func purgeAll(_ messages: [StoredMessage])
}

/**
 * Единая точка входа всех входящих конвертов (как core/service/MessageRouter.kt):
 * расшифровка, самолечение сессии, разбор по типу, ack серверу.
 *
 * Правила ack:
 *  - успешно обработанное — ack;
 *  - дубль (alreadyProcessed) — ack, сессию не трогаем;
 *  - сбой на ТЕКУЩЕМ ключе — без ack (сервер передоставит), после 3 подряд —
 *    ack + session_reset (только если текущая сессия подтверждена собеседником);
 *  - нет сессии и нет X3DH-полей — 2 минуты ждём гонку доставки, потом ack.
 *
 * Сброс и новая X3DH не стирают прежнюю сессию, а отправляют её в архив
 * ([SessionStore.archived]): собеседник, ещё не узнавший о сбросе, шифрует
 * старой — это должно расшифровываться.
 */
public final class MessageRouter: @unchecked Sendable {
    private let transport: Transport
    private let api: ApiClient
    private let session: Session
    private let keys: KeyStore
    private let sessions: SessionStore
    private let peerAccounts: PeerAccountStore
    private let peerIdentities: PeerIdentityStore
    private let chats: ChatStore
    private let prefs: Prefs
    private let queue: SendQueueProcessor
    private let cleanup: MessageCleanup
    private let sendLock: KeyedMutex
    private weak var host: RouterHost?
    private let log: Logger
    private let now: () -> Int64

    static let sessionResetType = "session_reset"
    static let resetFailureThreshold: Int64 = 3
    static let resetCooldownMs: Int64 = 30_000
    static let noSessionGiveUpMs: Int64 = 2 * 60_000
    static let maxRememberedNonces = 500
    /// Служебные типы: без звука и уведомления.
    static let silentTypes: Set<String> = [MessageType.reaction, MessageType.pin, MessageType.edit, MessageType.delete,
                                           MessageType.clearChat, MessageType.deleteChat, MessageType.readReceipt]

    public let incomingReactions = Broadcast<IncomingReaction>()
    public let incomingDeletes = Broadcast<IncomingDelete>()

    private let lock = NSLock()
    private var ownerCache: [String: DeviceOwnerRef] = [:]
    private var started = false

    public init(transport: Transport, api: ApiClient, session: Session, keys: KeyStore, sessions: SessionStore, peerAccounts: PeerAccountStore,
                peerIdentities: PeerIdentityStore, chats: ChatStore, prefs: Prefs, queue: SendQueueProcessor, cleanup: MessageCleanup,
                sendLock: KeyedMutex, host: RouterHost, log: Logger = NoopLogger(), now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.transport = transport
        self.api = api
        self.session = session
        self.keys = keys
        self.sessions = sessions
        self.peerAccounts = peerAccounts
        self.peerIdentities = peerIdentities
        self.chats = chats
        self.prefs = prefs
        self.queue = queue
        self.cleanup = cleanup
        self.sendLock = sendLock
        self.host = host
        self.log = log
        self.now = now
    }

    private static func failureCountKey(_ d: String) -> String { "session_reset_failcount:\(d)" }
    private static func lastResetKey(_ d: String) -> String { "session_reset_last_request:\(d)" }
    private static func noSessionFirstSeenKey(_ d: String) -> String { "no_session_first_seen:\(d)" }
    private static func decryptedNoncesKey(_ d: String) -> String { "decrypted_nonces:\(d)" }

    public func start() {
        guard lock.sync({ () -> Bool in defer { started = true }; return !started }) else { return }
        Task { [weak self] in
            guard let self else { return }
            for await incoming in transport.messages.stream() { await handleIncoming(incoming) }
        }
    }

    /// Обработка одного входящего (публично — для тестов и пуш-пробуждения).
    public func handleIncoming(_ incoming: IncomingEnvelope) async {
        guard let sender = incoming.envelope["sender_device_id"]?.string else { return }
        await sendLock.run(sender) {
            do { try await self.process(sender, incoming.envelope, incoming.deliveryId) }
            catch is CancellationError {}
            catch { self.log.error("Router FAILED from=\(sender) deliveryId=\(incoming.deliveryId ?? "-") error=\(error)") }
        }
    }

    private func ack(_ deliveryId: String?) { if let deliveryId { transport.ackDelivery(deliveryId) } }

    private func process(_ sender: String, _ envelope: Envelope, _ deliveryId: String?) async throws {
        if envelope["type"]?.string == Self.sessionResetType {
            // собеседник нашёл рассинхрон при чтении НАШИХ сообщений — текущую сессию в архив
            log.log("Router session_reset received from=\(sender) — retiring local session to archive")
            sessions.retire(sender)
            clearFailureCount(sender)
            ack(deliveryId)
            return
        }
        guard let inner = try decrypt(sender, envelope, deliveryId) else { return }
        guard let owner = await resolveOwner(sender) else {
            log.log("Router DROP from=\(sender) reason=resolve-owner-failed")
            return
        }
        let chatIsOpen = host?.openChatPeerLogin == owner.login
        await apply(inner, owner, chatIsOpen)
        ack(deliveryId)
        if !chatIsOpen, !Self.silentTypes.contains(inner.type), !chats.isChatMuted(owner.login) {
            host?.playMessageSound()
            if host?.isAppInForeground == false { host?.showBackgroundMessageNotification() }
        }
    }

    // MARK: - расшифровка и самолечение

    private enum Opened {
        case ok(String)
        case duplicate
        /// Не вскрылся: [current] — текущая после попытки (nil — её не было), [triedFresh] — были X3DH-поля.
        case failed(current: RatchetState?, triedFresh: Bool)
    }

    /// Текущая сессия → архивные (удачная снова текущая) → новая из X3DH-полей
    /// (прежняя текущая — в архив). Вызывать под [sendLock] отправителя.
    private func open(_ sender: String, _ envelope: Envelope) throws -> Opened {
        var current = sessions.get(sender)
        if var state = current {
            do {
                let raw = try decryptMessage(messageKey: try state.nextReceivingKey(envelope: envelope), envelope: envelope)
                sessions.save(sender, state)
                return opened(sender, raw)
            } catch RatchetError.alreadyProcessed(let n) {
                log.log("Router IGNORING duplicate from=\(sender) number=\(n)")
                return .duplicate
            } catch {
                log.log("Router current session failed from=\(sender): \(error)")
                current = state
            }
        }
        for (index, archived) in sessions.archived(sender).enumerated() {
            var state = archived
            do {
                let raw = try decryptMessage(messageKey: try state.nextReceivingKey(envelope: envelope), envelope: envelope)
                log.log("Router decrypted with archived session #\(index) from=\(sender) — it is current again")
                sessions.promote(sender, index: index, state: state)
                return opened(sender, raw)
            } catch RatchetError.alreadyProcessed {
                return .duplicate
            } catch {
                continue // не эта
            }
        }
        let fresh = try establishFreshIncoming(sender, envelope)
        if var state = fresh {
            do {
                let raw = try decryptMessage(messageKey: try state.nextReceivingKey(envelope: envelope), envelope: envelope)
                log.log("Router new X3DH session from=\(sender) (previous one archived)")
                sessions.replace(sender, state)
                return opened(sender, raw)
            } catch {
                log.log("Router new X3DH session from=\(sender) failed: \(error)")
            }
        }
        return .failed(current: current, triedFresh: fresh != nil)
    }

    /// Вскрылся: собеседник шифрует текущей сессией — X3DH-поля больше не нужны, сбоев нет.
    private func opened(_ sender: String, _ raw: String) -> Opened {
        sessions.clearPendingInit(sender)
        clearFailureCount(sender)
        prefs.remove(Self.noSessionFirstSeenKey(sender))
        return .ok(raw)
    }

    /// nil — расшифровать не удалось; ack/заглушка/сброс уже сделаны здесь.
    private func decrypt(_ sender: String, _ envelope: Envelope, _ deliveryId: String?) throws -> InnerMessage? {
        switch try open(sender, envelope) {
        case .ok(let raw):
            rememberDecrypted(sender, envelope)
            return try InnerMessage.decode(raw)
        case .duplicate:
            ack(deliveryId)
            return nil
        case .failed(let current, let triedFresh):
            if current == nil && !triedFresh {
                // нет сессии и нет X3DH: возможно, сообщение с инициализацией ещё в пути
                let gaveUp = giveUpIfNoSessionTooLong(sender)
                log.log("Router DROP from=\(sender) reason=no-session-and-no-handshake\(gaveUp ? " (gave up)" : "")")
                if gaveUp {
                    ack(deliveryId)
                    Task { await recordUndecryptable(sender, envelope) }
                }
                return nil
            }
            log.error("Router decrypt-FAILED from=\(sender) hadSession=\(current != nil) triedFresh=\(triedFresh)")
            if let current, !triedFresh {
                handleUnrecoverable(sender, envelope, deliveryId, current)
            } else if onDecryptFailure(sender, deliveryId) {
                Task { await recordUndecryptable(sender, envelope) }
            }
            return nil
        }
    }

    private func handleUnrecoverable(_ sender: String, _ envelope: Envelope, _ deliveryId: String?, _ state: RatchetState) {
        let incomingKey = envelope["ratchet_pubkey"]?.string
        let currentKey = state.receivingRatchetPublicKey.map(b64)
        if let incomingKey, let currentKey, incomingKey != currentKey {
            // ключ прошлой эпохи: необратимо — сессию не трогаем, сбоем не считаем
            log.log("Router giving up on stale-ratchet-key delivery from=\(sender) (session left untouched)")
            ack(deliveryId)
            Task { await recordUndecryptable(sender, envelope, requireKnownHistory: true) }
            return
        }
        if onDecryptFailure(sender, deliveryId) { Task { await recordUndecryptable(sender, envelope) } }
    }

    private func establishFreshIncoming(_ sender: String, _ envelope: Envelope) throws -> RatchetState? {
        guard let me = keys.loadIdentity(), case let (state, x3dh)? = try PeerCipher.startIncomingSession(envelope: envelope, me: me) else { return nil }
        if let consumed = x3dh.consumedOneTimePrekey { keys.deleteOneTimePrekey(consumed) }
        if x3dh.missingOneTimePrekey { log.log("X3DH: sender claims a one-time prekey we no longer have — 3-DH only") }
        if let newDh = envelope["sender_identity_dh_pubkey"]?.string {
            if let previous = peerIdentities.get(sender), previous != newDh {
                // переустановка или подмена ключа — сами не отличим, но фиксируем громко
                log.error("Router SECURITY-WARNING identity_dh_pubkey CHANGED for from=\(sender)")
            }
            peerIdentities.save(sender, newDh)
        }
        return state
    }

    /// Подряд идущие сбои (счётчик на диске). На пороге: ack и session_reset (не чаще раза в 30 с).
    /// true — доставка признана окончательно потерянной.
    private func onDecryptFailure(_ sender: String, _ deliveryId: String?) -> Bool {
        let count = (prefs.long(Self.failureCountKey(sender)) ?? 0) + 1
        prefs.set(Self.failureCountKey(sender), count)
        log.log("Router decrypt-failure-count from=\(sender) count=\(count)")
        guard count >= Self.resetFailureThreshold else { return false }
        ack(deliveryId)
        // сброс лечит только подтверждённую собеседником сессию: нет текущей — следующая
        // отправка и так поднимет новую; текущая — наша свежая X3DH без ответа — собеседник
        // поднимет её по X3DH-полям любого нашего сообщения
        if sessions.get(sender) == nil || sessions.pendingInit(sender) != nil {
            log.log("Router no auto session-reset for=\(sender): our session is not confirmed by the peer yet")
            return true
        }
        let last = prefs.long(Self.lastResetKey(sender))
        if last == nil || now() - last! >= Self.resetCooldownMs {
            prefs.set(Self.lastResetKey(sender), now())
            log.log("Router auto session-reset for=\(sender) after \(count) consecutive decrypt failures")
            resetLocked(sender, reason: "auto (\(count) decrypt failures)")
        }
        return true
    }

    /// Расшифровать сигнал звонка (внутри — JSON {type, ...}); тот же путь, что у сообщений.
    public func openCallSignal(_ sender: String, _ envelope: Envelope) async -> [String: JSONValue]? {
        await sendLock.run(sender) {
            do {
                switch try self.open(sender, envelope) {
                case .ok(let raw): return try JSONValue.parse(raw).object
                case .duplicate: return nil
                case .failed(let current, let triedFresh):
                    if current == nil && !triedFresh {
                        self.log.log("Router call signal from=\(sender): no session and no handshake")
                    } else {
                        self.log.error("Router call signal decrypt-FAILED from=\(sender) hadSession=\(current != nil) triedFresh=\(triedFresh)")
                        _ = self.onDecryptFailure(sender, nil)
                    }
                    return nil
                }
            } catch {
                self.log.error("Router call signal FAILED from=\(sender) error=\(error)")
                return nil
            }
        }
    }

    /// Сессию у себя — в архив и попросить собеседника сделать то же. Также кнопка
    /// "Сбросить шифрование" и очистка чата у обоих.
    public func resetSessionWith(_ deviceId: String, reason: String) async {
        await sendLock.run(deviceId) { self.resetLocked(deviceId, reason: reason) }
    }

    private func resetLocked(_ deviceId: String, reason: String) {
        log.log("Router resetSessionWith device=\(deviceId) reason=\(reason)")
        sessions.retire(deviceId)
        guard let myDeviceId = keys.deviceId() else { return }
        queue.enqueue(toDeviceId: deviceId, envelope: ["type": .string(Self.sessionResetType), "sender_device_id": .string(myDeviceId)],
                      deliveryId: UUID().uuidString.lowercased(), silent: true)
    }

    private func clearFailureCount(_ d: String) { prefs.remove(Self.failureCountKey(d)) }

    private func giveUpIfNoSessionTooLong(_ d: String) -> Bool {
        guard let first = prefs.long(Self.noSessionFirstSeenKey(d)) else {
            prefs.set(Self.noSessionFirstSeenKey(d), now())
            return false
        }
        return now() - first > Self.noSessionGiveUpMs
    }

    // MARK: - заглушка "не удалось дешифровать"

    /// Журнал nonce расшифрованных конвертов: отличает повтор прочитанного от настоящей потери.
    private func rememberDecrypted(_ d: String, _ envelope: Envelope) {
        guard let nonce = envelope["nonce"]?.string else { return }
        var list = prefs.stringList(Self.decryptedNoncesKey(d)) ?? []
        guard !list.contains(nonce) else { return }
        list.append(nonce)
        prefs.set(Self.decryptedNoncesKey(d), Array(list.suffix(Self.maxRememberedNonces)))
    }

    private func recordUndecryptable(_ d: String, _ envelope: Envelope, requireKnownHistory: Bool = false) async {
        guard let nonce = envelope["nonce"]?.string else { return }
        let decrypted = prefs.stringList(Self.decryptedNoncesKey(d))
        if let decrypted, decrypted.contains(nonce) { return }
        if requireKnownHistory && decrypted == nil { return }
        guard let owner = await resolveOwner(d) else { return }
        chats.addUndecryptableNotice(owner.login, id: "undecryptable_\(nonce)", timestamp: now(), accountId: owner.accountId,
                                     incrementUnread: host?.openChatPeerLogin != owner.login)
    }

    // MARK: - владелец устройства

    /// device_id → (account_id, login) без сети: память → диск.
    public func knownOwner(_ deviceId: String) -> DeviceOwnerRef? {
        if let cached = lock.sync({ ownerCache[deviceId] }) { return cached }
        guard let accountId = peerAccounts.get(deviceId),
              let chat = chats.knownPeers().first(where: { $0.lastKnownAccountId == accountId }) else { return nil }
        let ref = DeviceOwnerRef(accountId: accountId, login: chat.peerLogin)
        lock.sync { ownerCache[deviceId] = ref }
        return ref
    }

    /// device_id → (account_id, login): без сети, потом сеть.
    public func resolveOwner(_ deviceId: String) async -> DeviceOwnerRef? {
        if let known = knownOwner(deviceId) { return known }
        guard let token = session.token, let info = await api.getDeviceOwnerInfo(token: token, deviceId: deviceId) else { return nil }
        peerAccounts.save(deviceId, info.accountId)
        let ref = DeviceOwnerRef(accountId: info.accountId, login: info.login)
        lock.sync { ownerCache[deviceId] = ref }
        return ref
    }

    // MARK: - применение расшифрованного

    private func apply(_ inner: InnerMessage, _ owner: DeviceOwnerRef, _ chatIsOpen: Bool) async {
        let login = owner.login
        let unread = !chatIsOpen
        func base(_ id: String, _ text: String) -> StoredMessage {
            var m = StoredMessage(messageId: id, text: text, isMine: false, timestamp: inner.sentAt)
            m.groupId = inner.groupId
            m.replyToMessageId = inner.replyToMessageId
            m.replyToPreview = inner.replyToPreview
            return m
        }
        switch inner.type {
        case MessageType.text:
            chats.addMessage(login, base(inner.messageId, inner.body), accountId: owner.accountId, incrementUnread: unread)
        case MessageType.sticker:
            guard let stickerId = inner.bodyJSON()["sticker_id"]?.string else { return }
            var m = base(inner.messageId, "")
            m.stickerId = stickerId
            chats.addMessage(login, m, accountId: owner.accountId, incrementUnread: unread)
        case MessageType.media:
            var m = Self.mediaMessage(inner.messageId, inner.bodyJSON(), inner.sentAt, inner.groupId)
            m.replyToMessageId = inner.replyToMessageId
            m.replyToPreview = inner.replyToPreview
            chats.addMessage(login, m, accountId: owner.accountId, incrementUnread: unread)
        case MessageType.voice, MessageType.videoNote:
            let b = inner.bodyJSON()
            let videoNote = inner.type == MessageType.videoNote
            var m = base(inner.messageId, "")
            m.isMedia = true
            m.isVoice = !videoNote
            m.isVideoNote = videoNote
            m.fileSize = b["file_size"]?.int ?? 0
            m.chunked = b["chunked"]?.bool ?? false
            m.durationMs = b["duration_ms"]?.int
            m.mediaId = b["media_id"]?.string
            m.mediaKeyBase64 = b["key"]?.string
            m.mediaNonceBase64 = b["nonce"]?.string
            m.mediaMacBase64 = b["mac"]?.string
            chats.addMessage(login, m, accountId: owner.accountId, incrementUnread: unread)
        case MessageType.mediaGroup:
            let b = inner.bodyJSON()
            var list: [StoredMessage] = []
            if let caption = b["caption"]?.string, !caption.isEmpty, let textId = b["text_message_id"]?.string {
                var t = StoredMessage(messageId: textId, text: caption, isMine: false, timestamp: inner.sentAt)
                t.groupId = inner.groupId
                list.append(t)
            }
            for f in b["files"]?.array ?? [] {
                if let o = f.object, let id = o["message_id"]?.string { list.append(Self.mediaMessage(id, o, inner.sentAt, inner.groupId)) }
            }
            chats.addMessages(login, list, accountId: owner.accountId, incrementUnread: unread)
        case MessageType.callMissed:
            // звонок не дошёл живьём (мы были офлайн) — подстраховка через офлайн-очередь
            let b = inner.bodyJSON()
            chats.addCallLog(login, direction: "incoming", outcome: "missed", timestamp: b["called_at"]?.int ?? inner.sentAt,
                             accountId: owner.accountId, incrementUnread: unread, callId: b["call_id"]?.string)
        case MessageType.reaction:
            let b = inner.bodyJSON()
            guard let target = b["target_id"]?.string else { return }
            let emoji = b["emoji"]?.string
            chats.setReaction(login, target, isMine: false, emoji: emoji)
            if emoji != nil { incomingReactions.emit(IncomingReaction(peerLogin: login, messageId: target)) }
        case MessageType.pin:
            let b = inner.bodyJSON()
            chats.setPinned(login, messageId: b["pinned"]?.bool == true ? b["target_id"]?.string : nil)
        case MessageType.edit:
            let b = inner.bodyJSON()
            if let target = b["target_id"]?.string, let text = b["text"]?.string { chats.editMessageText(login, target, text) }
        case MessageType.delete:
            let targets = (inner.bodyJSON()["target_ids"]?.array ?? []).compactMap(\.string)
            if !targets.isEmpty { incomingDeletes.emit(IncomingDelete(peerLogin: login, targetIds: targets)) }
            let set = Set(targets)
            let toPurge = chats.messages(login).filter { set.contains($0.messageId) }
            chats.deleteMessages(login, targets)
            cleanup.purgeAll(toPurge)
        case MessageType.clearChat:
            let all = chats.messages(login)
            chats.clearHistory(login)
            cleanup.purgeAll(all)
        case MessageType.deleteChat:
            let all = chats.messages(login)
            chats.removeChat(login)
            cleanup.purgeAll(all)
        case MessageType.readReceipt:
            chats.markMessagesRead(login, (inner.bodyJSON()["target_ids"]?.array ?? []).compactMap(\.string))
        default:
            log.log("Router: unknown inner type=\(inner.type) — ignored")
        }
    }

    /// Входящее фото/видео/файл (body 'media' или элемент 'media_group').
    static func mediaMessage(_ id: String, _ b: [String: JSONValue], _ sentAt: Int64, _ groupId: String?) -> StoredMessage {
        var m = StoredMessage(messageId: id, text: "", isMine: false, timestamp: sentAt)
        m.isMedia = true
        m.isFile = b["is_file"]?.bool ?? false
        m.isVideo = b["is_video"]?.bool ?? false
        m.fileSize = b["file_size"]?.int ?? 0
        m.chunked = b["chunked"]?.bool ?? false
        m.isSpoiler = b["spoiler"]?.bool ?? false
        m.mediaId = b["media_id"]?.string
        m.mediaKeyBase64 = b["key"]?.string
        m.mediaNonceBase64 = b["nonce"]?.string
        m.mediaMacBase64 = b["mac"]?.string
        m.fileName = b["file_name"]?.string
        m.groupId = groupId
        return m
    }
}
