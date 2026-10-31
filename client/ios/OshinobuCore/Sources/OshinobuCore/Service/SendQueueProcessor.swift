import Foundation

/**
 * Надёжная исходящая очередь (как core/service/SendQueueProcessor.kt): готовый
 * конверт сначала ложится на диск и уходит из очереди ТОЛЬКО по ack сервера.
 * Нет соединения — ждёт переподключения; ack не пришёл за 8 с — слушаем
 * опоздавший ack в фоне, при следующем переподключении конверт уходит снова
 * (дубли на приёме гасятся по message_id). Отказ сервера ("rejected") —
 * конверт убирается, сообщение «не отправлено».
 */
public final class SendQueueProcessor: @unchecked Sendable {
    private let store: SendQueueStore
    private let transport: Transport
    private let acks: AckRegistry
    private let chats: ChatStore
    private let log: Logger
    private let ackTimeout: Duration

    private let lock = NSLock()
    private var inFlight: Set<String> = []
    private var onAcked: [String: @Sendable () async -> Void] = [:]
    private var started = false

    public init(store: SendQueueStore, transport: Transport, acks: AckRegistry, chats: ChatStore, log: Logger = NoopLogger(), ackTimeout: Duration = .seconds(8)) {
        self.store = store
        self.transport = transport
        self.acks = acks
        self.chats = chats
        self.log = log
        self.ackTimeout = ackTimeout
    }

    public func start() {
        guard lock.sync({ () -> Bool in defer { started = true }; return !started }) else { return }
        Task { [weak self] in
            guard let self else { return }
            for await s in transport.status.stream() where s == .connected { sweep() }
        }
    }

    /// [messageId]+[peerLogin] — пометить сообщение 'sent' по ack.
    public func enqueue(toDeviceId: String, envelope: Envelope, deliveryId: String, silent: Bool = false,
                        messageId: String? = nil, peerLogin: String? = nil, onAcked: (@Sendable () async -> Void)? = nil) {
        store.add(id: deliveryId, toDeviceId: toDeviceId, envelope: envelope, silent: silent, messageId: messageId, peerLogin: peerLogin)
        if let onAcked { lock.sync { self.onAcked[deliveryId] = onAcked } }
        Task { await attempt(deliveryId, toDeviceId, envelope, silent, messageId, peerLogin) }
    }

    /// id конвертов, ждущих ack (переживают перезапуск).
    public func pendingIds() -> [String] { store.all().compactMap { $0["id"]?.string } }

    /// Снять с очереди конверты этих сообщений (отмена отправки из «Передач»).
    public func drop(messageIds: Set<String>) {
        for item in store.all() {
            guard let id = item["id"]?.string, let m = item["message_id"]?.string, messageIds.contains(m) else { continue }
            store.remove(id)
            lock.sync { _ = onAcked.removeValue(forKey: id) }
        }
    }

    /// Переотправить всё, что лежит в очереди (на каждое переподключение).
    public func sweep() {
        let items = store.all()
        if !items.isEmpty { log.log("SendQueueProcessor sweep: \(items.count) item(s) pending") }
        for item in items {
            guard let id = item["id"]?.string, let to = item["to_device_id"]?.string, let env = item["envelope"]?.object else { continue }
            Task { await attempt(id, to, env, item["silent"]?.bool ?? false, item["message_id"]?.string, item["peer_login"]?.string) }
        }
    }

    private func attempt(_ id: String, _ to: String, _ envelope: Envelope, _ silent: Bool, _ messageId: String?, _ peerLogin: String?) async {
        guard lock.sync({ inFlight.insert(id).inserted }) else { return } // уже в полёте
        var sentOffline = false
        defer {
            lock.sync { _ = inFlight.remove(id) }
            // связь появилась, пока эта попытка шла: обход очереди на переподключении её
            // пропустил («в полёте») — без повтора конверт ждал бы следующего переподключения
            if sentOffline && transport.isConnected {
                Task { await attempt(id, to, envelope, silent, messageId, peerLogin) }
            }
        }
        do {
            try transport.sendEnvelope(toDeviceId: to, envelope: envelope, deliveryId: id, silent: silent)
        } catch {
            log.log("SendQueueProcessor id=\(id) not sent (offline): \(error)")
            sentOffline = true
            return
        }
        let waiter = Task { try await acks.wait(id) }
        do {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask { try await waiter.value; return true }
                group.addTask { [ackTimeout] in try await Task.sleep(for: ackTimeout); return false }
                let acked = try await group.next() ?? false
                group.cancelAll()
                if !acked { throw AckTimeout() }
            }
            await finalizeAcked(id, messageId, peerLogin)
        } catch is AckTimeout {
            log.log("SendQueueProcessor id=\(id) no ack within timeout — still listening for a late ack")
            Task { [weak self] in
                do {
                    try await waiter.value
                    await self?.finalizeAcked(id, messageId, peerLogin)
                } catch let e as DeliveryRejectedError {
                    self?.finalizeRejected(id, messageId, peerLogin, e.reason)
                } catch {}
            }
        } catch let e as DeliveryRejectedError {
            finalizeRejected(id, messageId, peerLogin, e.reason)
        } catch {
            waiter.cancel() // ожидание отменено (сообщение удалено/отменено)
        }
    }

    private struct AckTimeout: Error {}

    private func finalizeRejected(_ id: String, _ messageId: String?, _ peerLogin: String?, _ reason: String) {
        log.log("SendQueueProcessor id=\(id) rejected by server (\(reason)) — dropped from queue")
        store.remove(id)
        if let messageId, let peerLogin { chats.updateMessageStatus(peerLogin, messageId, MessageStatus.failed) }
        lock.sync { _ = onAcked.removeValue(forKey: id) }
    }

    private func finalizeAcked(_ id: String, _ messageId: String?, _ peerLogin: String?) async {
        store.remove(id)
        if let messageId, let peerLogin { chats.updateMessageStatus(peerLogin, messageId, MessageStatus.sent) }
        let callback = lock.sync { onAcked.removeValue(forKey: id) }
        await callback?()
    }
}
