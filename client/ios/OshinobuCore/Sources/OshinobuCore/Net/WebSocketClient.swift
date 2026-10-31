import Foundation

// WebSocket к серверу (как core/net/WebSocketClient.kt).
//
// Внешние кадры сервера: {"Type", "DeliveryId", "Ciphertext", ...}.
//  - "ack"                   — сервер принял наш конверт (DeliveryId);
//  - "rejected"              — и не примет никогда (DeliveryId, Reason);
//  - "presence"/"typing"     — присутствие собеседника;
//  - "block_status_changed"  — кто-то (раз)блокировал;
//  - "profile_updated"       — {AccountId, Field};
//  - "wallpaper_changed"     — {AccountId};
//  - "call_*"                — сигнал звонка; ack шлём СРАЗУ, сам сигнал — в callSignals;
//  - остальное с Ciphertext  — конверт сообщения; DeliveryId подтверждаем ПОСЛЕ обработки.

public enum ConnectionStatus: Sendable, Equatable { case waitingForNetwork, connecting, connected, reconnecting }

public struct IncomingEnvelope: Sendable {
    public let envelope: Envelope
    public let deliveryId: String?
}

public struct DeliveryRejection: Sendable { public let deliveryId: String; public let reason: String }
public struct ProfileChange: Sendable { public let accountId: String; public let field: String }

/// То, что сервисам нужно от соединения с сервером (в тестах — фейковый сервер).
public protocol Transport: AnyObject, Sendable {
    var status: StateValue<ConnectionStatus> { get }
    var messages: Broadcast<IncomingEnvelope> { get }
    var acks: Broadcast<String> { get }
    var rejections: Broadcast<DeliveryRejection> { get }
    var isConnected: Bool { get }
    func sendEnvelope(toDeviceId: String, envelope: Envelope, deliveryId: String, silent: Bool) throws
    func ackDelivery(_ deliveryId: String)
}

/// Канал сигналов звонка: входящие уже разобраны в JSON с полем "type".
public protocol CallSignaling: AnyObject, Sendable {
    var callSignals: Broadcast<[String: JSONValue]> { get }
    func sendCallSignal(toDeviceId: String, type: String, payload: [String: JSONValue]) async -> Bool
}

public struct NotConnectedError: Error {}

public final class WebSocketClient: NSObject, Transport, CallSignaling, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let api: ApiClient
    private let log: (String) -> Void
    private let readyTimeout: Duration
    private let reconnectDelay: Duration
    private let callSignalWait: Duration

    public let status = StateValue<ConnectionStatus>(.connecting)
    public let messages = Broadcast<IncomingEnvelope>()
    public let callSignals = Broadcast<[String: JSONValue]>()
    public let presenceEvents = Broadcast<[String: JSONValue]>()
    public let blockStatusEvents = Broadcast<Void>()
    public let profileChanges = Broadcast<ProfileChange>()
    /// account_id собеседника, который поменял обои нашего с ним чата.
    public let wallpaperChanges = Broadcast<String>()
    public let acks = Broadcast<String>()
    public let rejections = Broadcast<DeliveryRejection>()
    public let sessionInvalidated = Broadcast<Void>()

    private let lock = NSLock()
    private var session: URLSession!
    private var socket: URLSessionWebSocketTask?
    /// Растёт на каждое новое соединение — колбэки старых сокетов игнорируются.
    private var generation = 0
    private var token: String?
    private var deviceId: String?
    private var manuallyDisconnected = false
    private var hadNetwork = true
    private var reconnectTask: Task<Void, Never>?
    private var readyTimeoutTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    /// Видит ли человек приложение; пока не сообщили — нет (процесс мог поднять пуш).
    private var lastKnownForeground = false

    public init(api: ApiClient, readyTimeout: Duration = .seconds(8), reconnectDelay: Duration = .seconds(3),
                callSignalWait: Duration = .seconds(5), log: @escaping (String) -> Void = { _ in }) {
        self.api = api
        self.readyTimeout = readyTimeout
        self.reconnectDelay = reconnectDelay
        self.callSignalWait = callSignalWait
        self.log = log
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    /// Реально готов к отправке (сокет есть И рукопожатие завершено).
    public var isConnected: Bool { lock.sync { socket != nil } && status.value == .connected }

    private func setStatus(_ s: ConnectionStatus) {
        if status.value != s {
            status.value = s
            log("WS status -> \(s)")
        }
    }

    public func connect(token: String, deviceId: String) {
        lock.sync {
            self.token = token
            self.deviceId = deviceId
            manuallyDisconnected = false
            closeCurrentLocked()
        }
        openConnection()
    }

    public func disconnect() {
        lock.sync {
            manuallyDisconnected = true
            reconnectTask?.cancel()
            closeCurrentLocked()
        }
    }

    /// Сеть появилась — переподключаемся сразу, а не по таймеру.
    public func onNetworkAvailable() {
        let wasOffline = lock.sync { () -> Bool in
            defer { hadNetwork = true }
            return !hadNetwork
        }
        if wasOffline { forceReconnect() }
    }

    /// Разбудил пуш (приложение было приостановлено): не связаны — подключиться сразу,
    /// не дожидаясь таймера переподключения.
    public func wake() {
        if status.value != .connected { forceReconnect() }
    }

    /// Основная сеть сменилась (Wi-Fi ↔ сотовая) — старый сокет мёртв.
    public func onNetworkSwitched() {
        lock.sync { hadNetwork = true }
        forceReconnect()
    }

    public func onNetworkLost() {
        lock.sync { hadNetwork = false }
        setStatus(.waitingForNetwork)
    }

    private func forceReconnect() {
        let proceed = lock.sync { () -> Bool in
            if manuallyDisconnected { return false }
            reconnectTask?.cancel()
            closeCurrentLocked()
            return true
        }
        if proceed { openConnection() }
    }

    private func closeCurrentLocked() {
        generation += 1
        readyTimeoutTask?.cancel()
        pingTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func openConnection() {
        let setup: (Int, URLRequest)? = lock.sync {
            guard let token, let deviceId else { return nil }
            generation += 1
            var c = URLComponents(url: api.config.webSocketURL.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "device_id", value: deviceId)]
            var r = URLRequest(url: c.url!)
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return (generation, r)
        }
        guard case let (gen, request)? = setup else { return }
        setStatus(.connecting)
        let task = session.webSocketTask(with: request)
        task.taskDescription = String(gen)
        lock.sync {
            guard gen == generation else { task.cancel(); return }
            socket = task
            readyTimeoutTask = Task { [weak self, readyTimeout] in
                try? await Task.sleep(for: readyTimeout)
                guard let self, !Task.isCancelled, self.isCurrent(gen), self.status.value != .connected else { return }
                self.log("WS connect timeout — will retry")
                self.scheduleReconnect(gen)
            }
        }
        task.resume()
        receive(task, gen: gen)
    }

    private func isCurrent(_ gen: Int) -> Bool { lock.sync { gen == generation } }

    private func scheduleReconnect(_ gen: Int) {
        lock.sync {
            guard gen == generation else { return }
            generation += 1
            readyTimeoutTask?.cancel()
            pingTask?.cancel()
            socket?.cancel()
            socket = nil
            if manuallyDisconnected { return }
            status.value = hadNetwork ? .reconnecting : .waitingForNetwork
            reconnectTask?.cancel()
            reconnectTask = Task { [weak self, reconnectDelay] in
                try? await Task.sleep(for: reconnectDelay)
                guard let self, !Task.isCancelled else { return }
                if let t = self.lock.sync({ self.token }), await self.api.checkSession(token: t) == false {
                    // вошли с другого устройства — переподключаться бессмысленно
                    self.log("WS session invalid — stopping reconnect")
                    self.lock.sync { self.manuallyDisconnected = true }
                    self.sessionInvalidated.emit(())
                    return
                }
                if self.lock.sync({ self.socket != nil || self.manuallyDisconnected }) { return }
                self.openConnection()
            }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, gen: Int) {
        task.receive { [weak self] result in
            guard let self, self.isCurrent(gen) else { return }
            switch result {
            case .success(let message):
                let text: String? = {
                    switch message {
                    case .string(let s): return s
                    case .data(let d): return String(data: d, encoding: .utf8)
                    @unknown default: return nil
                    }
                }()
                if let text {
                    do { try self.handleFrame(JSONValue.parse(text).object ?? [:]) }
                    catch { self.log("WS recv: failed to parse frame: \(error)") }
                }
                self.receive(task, gen: gen)
            case .failure(let error):
                self.log("WS failure: \(error) — reconnecting")
                self.scheduleReconnect(gen)
            }
        }
    }

    // MARK: URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard let gen = Int(webSocketTask.taskDescription ?? ""), isCurrent(gen) else { return }
        lock.sync { readyTimeoutTask?.cancel() }
        setStatus(.connected)
        sendForegroundState(lock.sync { lastKnownForeground })
        startPing(webSocketTask, gen: gen)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard let gen = Int(webSocketTask.taskDescription ?? ""), isCurrent(gen) else { return }
        log("WS closed code=\(closeCode.rawValue) — reconnecting")
        scheduleReconnect(gen)
    }

    /// Ping раз в 45 с (как pingInterval у OkHttp): без ответа соединение мёртвое.
    private func startPing(_ task: URLSessionWebSocketTask, gen: Int) {
        lock.sync {
            pingTask?.cancel()
            pingTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(45))
                    guard let self, !Task.isCancelled, self.isCurrent(gen) else { return }
                    task.sendPing { error in
                        if let error {
                            self.log("WS ping failed: \(error) — reconnecting")
                            self.scheduleReconnect(gen)
                        }
                    }
                }
            }
        }
    }

    // MARK: кадры

    private func handleFrame(_ outer: [String: JSONValue]) {
        let type = outer["Type"]?.string
        let deliveryId = outer["DeliveryId"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        switch type {
        case "ack":
            if let deliveryId { acks.emit(deliveryId) }
        case "rejected":
            if let deliveryId {
                let reason = outer["Reason"]?.string ?? ""
                log("WS recv rejected deliveryId=\(deliveryId) reason=\(reason)")
                rejections.emit(DeliveryRejection(deliveryId: deliveryId, reason: reason))
            }
        case "presence", "typing":
            presenceEvents.emit(outer)
        case "block_status_changed":
            log("WS recv block_status_changed")
            blockStatusEvents.emit(())
        case "profile_updated":
            if let a = outer["AccountId"]?.string, let f = outer["Field"]?.string { profileChanges.emit(ProfileChange(accountId: a, field: f)) }
        case "wallpaper_changed":
            if let a = outer["AccountId"]?.string { wallpaperChanges.emit(a) }
        case let t? where t.hasPrefix("call_"):
            // сигналы звонка подтверждаем сразу — их обработка не идемпотентна
            if let deliveryId { send(ackFrame(deliveryId)) }
            log("WS recv \(t)")
            var payload = (outer["Ciphertext"]?.string).flatMap { try? JSONValue.parse($0).object } ?? [:]
            payload["type"] = .string(t)
            callSignals.emit(payload)
        default:
            if let c = outer["Ciphertext"]?.string, let env = try? JSONValue.parse(c).object {
                messages.emit(IncomingEnvelope(envelope: env, deliveryId: deliveryId))
            }
        }
    }

    private func ackFrame(_ deliveryId: String) -> [String: JSONValue] { ["Type": "ack", "DeliveryId": .string(deliveryId)] }

    @discardableResult
    private func send(_ frame: [String: JSONValue]) -> Bool {
        guard let socket = lock.sync({ self.socket }) else { return false }
        socket.send(.string(JSONValue.object(frame).encoded())) { [weak self] error in
            if let error { self?.log("WS send failed: \(error)") }
        }
        return true
    }

    /// Подтвердить серверу, что входящий конверт обработан (иначе он придёт снова).
    public func ackDelivery(_ deliveryId: String) {
        if isConnected { send(ackFrame(deliveryId)) }
    }

    /// Бросает [NotConnectedError], если соединения нет: вызывающий кладёт конверт в очередь.
    public func sendEnvelope(toDeviceId: String, envelope: Envelope, deliveryId: String, silent: Bool) throws {
        guard isConnected else { throw NotConnectedError() }
        send([
            "ToDeviceId": .string(toDeviceId), "Ciphertext": .string(JSONValue.object(envelope).encoded()),
            "Type": "message", "DeliveryId": .string(deliveryId), "Silent": .bool(silent),
        ])
    }

    /// Сигналы звонка не идут через очередь — если соединение переоткрывается, ждём его до [callSignalWait].
    public func sendCallSignal(toDeviceId: String, type: String, payload: [String: JSONValue]) async -> Bool {
        let frame: [String: JSONValue] = ["ToDeviceId": .string(toDeviceId), "Ciphertext": .string(JSONValue.object(payload).encoded()), "Type": .string(type)]
        if isConnected { return send(frame) }
        log("WS send \(type): not connected, waiting")
        let ready = await status.first(where: { $0 == .connected }, timeout: callSignalWait) != nil
        if ready, isConnected { return send(frame) }
        log("WS sendCallSignal type=\(type) DROPPED — no connection")
        return false
    }

    public func subscribePresence(_ peerDeviceId: String) { send(["Type": "presence_subscribe", "ToDeviceId": .string(peerDeviceId)]) }
    public func unsubscribePresence(_ peerDeviceId: String) { send(["Type": "presence_unsubscribe", "ToDeviceId": .string(peerDeviceId)]) }

    public func sendForegroundState(_ foreground: Bool) {
        lock.sync { lastKnownForeground = foreground }
        send(["Type": "presence_foreground", "Foreground": .bool(foreground)])
    }

    public func sendTyping(_ peerDeviceId: String) { send(["Type": "typing", "ToDeviceId": .string(peerDeviceId)]) }
}
