import Foundation

public enum CallState: Sendable, Equatable { case idle, outgoingRinging, incomingRinging, connected }

public struct IceServer: Sendable { public let urls: [String]; public let username: String?; public let credential: String? }

public enum SignalingState: Sendable { case stable, haveLocalOffer, other }

/// WebRTC-соединение одного звонка (реализация — в приложении, поверх WebRTC.framework).
public protocol RtcSession: AnyObject, Sendable {
    var signalingState: SignalingState { get }
    /// Создать offer и поставить локальным описанием; вернуть SDP.
    func createOffer() async throws -> String
    func createAnswer() async throws -> String
    /// [type] — "offer" или "answer".
    func setRemoteDescription(type: String, sdp: String) async throws
    /// Откат своего offer при встречном (perfect negotiation, вежливая сторона).
    func rollback() async throws
    func addIceCandidate(_ candidate: String, sdpMid: String?, sdpMLineIndex: Int32) async throws
    func startAudio(micEnabled: Bool) async throws
    func setMicEnabled(_ enabled: Bool)
    /// Камера вкл/выкл; в первый раз добавляет видеодорожку (→ renegotiation).
    func setVideoEnabled(_ enabled: Bool) async throws
    /// Сменить камеру; true — теперь фронтальная.
    func switchCamera() async throws -> Bool
    func close()
}

/// События соединения — из потоков WebRTC; менеджер сам переносит их к себе.
public protocol RtcEvents: AnyObject, Sendable {
    func onIceCandidate(_ candidate: String, sdpMid: String?, sdpMLineIndex: Int32)
    func onConnected()
    func onFailed()
    func onRenegotiationNeeded()
}

public protocol RtcEngine: Sendable {
    func createSession(iceServers: [IceServer], events: RtcEvents) -> RtcSession
}

/// С кем звонок; login/accountId выясняются по device_id, если звонок входящий.
public struct CallPeer: Sendable, Equatable {
    public let deviceId: String
    public var login: String?
    public var accountId: String?
    public init(deviceId: String, login: String? = nil, accountId: String? = nil) {
        self.deviceId = deviceId
        self.login = login
        self.accountId = accountId
    }
}

public struct IncomingCall: Sendable { public let callId: String; public let peer: CallPeer }

/**
 * Звонки (как core/service/CallManager.kt): сигнальный протокол поверх
 * зашифрованного канала (сигналы шифруются той же сессией ratchet, что и
 * сообщения), медиа — WebRTC за [RtcEngine]. Вся работа — на одном actor:
 * без гонок между сигналами и действиями пользователя, и действие доводится до
 * конца, даже если экран, который его вызвал, ушёл.
 *
 *  - исходящий: offer → (answer) → connected; отмена — call_cancel;
 *  - входящий: offer → incomingRinging → accept (answer) / decline (call_reject);
 *    второй звонок поверх идущего — call_busy;
 *  - смена дорожек — renegotiation по perfect negotiation (вежливая — принимающая);
 *  - дозвон не вечный (2 минуты); по окончании — запись в чат, недоступному — «пропущенный».
 */
public actor CallManager {
    private static let requiresActivePeer: Set<String> = ["call_answer", "call_ice", "call_video_state", "call_reject", "call_busy", "call_cancel", "call_end"]
    private static let stun = "stun:stun.l.google.com:19302"

    private let signaling: CallSignaling
    private let messenger: PeerMessenger
    private let router: MessageRouter
    private let api: ApiClient
    private let session: Session
    private let chats: ChatStore
    private let engine: RtcEngine
    private let log: Logger
    private let now: @Sendable () -> Int64
    private let endReasonDelay: Duration
    private let ringTimeout: Duration
    private let stepTimeout: Duration

    public nonisolated let state = StateValue<CallState>(.idle)
    /// Этап установки или причина завершения — ключ локализации ("call.ringing"…).
    public nonisolated let status = StateValue<String?>(nil)
    public nonisolated let peer = StateValue<CallPeer?>(nil)
    public nonisolated let connectedAt = StateValue<Int64?>(nil)
    public nonisolated let micEnabled = StateValue(true)
    public nonisolated let videoEnabled = StateValue(false)
    public nonisolated let remoteVideoEnabled = StateValue(false)
    public nonisolated let usingFrontCamera = StateValue(true)
    public nonisolated let incomingCalls = Broadcast<IncomingCall>()
    /// Звонок принят без экрана входящего (из CallKit) — открыть экран звонка.
    public nonisolated let openCallScreen = Broadcast<Void>()
    /// Звонок сработал плохо — описание для отчёта call_problem.
    public nonisolated let problems = Broadcast<String>()

    private var rtc: RtcSession?
    private var currentCallId: String?
    private var pendingOfferSdp: String?
    private var remoteDescriptionSet = false
    private var pendingCandidates: [(String, String?, Int32)] = []
    private var startedAt: Int64?
    private var isOutgoing = false
    private var makingOffer = false
    private var accepting = false
    private var autoAcceptPending = false
    private var started = false
    private var ringTimer: Task<Void, Never>?

    /// Вежливая сторона уступает при встречных offer — принимающая звонок.
    private var polite: Bool { !isOutgoing }

    public var callId: String? { currentCallId }

    /// Соединение текущего звонка — экрану звонка для видео (реализация платформы).
    public var session: RtcSession? { rtc }

    public init(signaling: CallSignaling, messenger: PeerMessenger, router: MessageRouter, api: ApiClient, session: Session, chats: ChatStore,
                engine: RtcEngine, log: Logger = NoopLogger(), now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                endReasonDelay: Duration = .milliseconds(1800), ringTimeout: Duration = .seconds(120), stepTimeout: Duration = .seconds(20)) {
        self.signaling = signaling
        self.messenger = messenger
        self.router = router
        self.api = api
        self.session = session
        self.chats = chats
        self.engine = engine
        self.log = log
        self.now = now
        self.endReasonDelay = endReasonDelay
        self.ringTimeout = ringTimeout
        self.stepTimeout = stepTimeout
    }

    public func start() {
        guard !started else { return }
        started = true
        let stream = signaling.callSignals.stream()
        Task { [weak self] in
            for await signal in stream {
                guard let self else { return }
                await self.handleSignal(signal)
            }
        }
    }

    private func setState(_ s: CallState) {
        log.log("CallManager state \(state.value) -> \(s)")
        state.value = s
    }

    private func problem(_ what: String) {
        let text = "\(what) (callId=\(currentCallId ?? "-") outgoing=\(isOutgoing) state=\(state.value) status=\(status.value ?? "-") peer=\(peer.value?.deviceId ?? "-"))"
        log.log("CallManager PROBLEM \(text)")
        problems.emit(text)
    }

    // MARK: - действия пользователя

    public func startCall(_ callee: CallPeer) async {
        guard state.value == .idle else { return }
        log.log("CallManager startCall to=\(callee.deviceId)")
        currentCallId = UUID().uuidString.lowercased()
        peer.value = callee
        resetMediaFlags()
        remoteDescriptionSet = false
        pendingCandidates = []
        startedAt = now()
        connectedAt.value = nil
        isOutgoing = true
        setState(.outgoingRinging)
        do {
            status.value = "call.securingConnection"
            // собеседник мог переустановить приложение: звоним на его нынешнее устройство
            if let login = callee.login {
                let current = await messenger.resolvePeerDeviceId(login: login, fallback: callee.deviceId)
                if current != callee.deviceId {
                    log.log("CallManager startCall: peer device changed \(callee.deviceId) -> \(current)")
                    peer.value = CallPeer(deviceId: current, login: callee.login, accountId: callee.accountId)
                }
            }
            let rtc = await createSession()
            try await step("call.enablingMic") { try await rtc.startAudio(micEnabled: self.micEnabled.value) }
            let offer = try await step("call.buildingOffer") { try await rtc.createOffer() }
            if !(await send("call_offer", ["sdp": .string(offer)])) {
                // сервер offer не получил — гудеть незачем; в историю не пишем: звонок никуда не ушёл
                log.log("CallManager startCall: offer not sent — no connection")
                problem("outgoing call: offer not sent, no connection to server")
                startedAt = nil
                await endWithReason("call.noConnection")
                return
            }
            status.value = "call.ringing"
            armRingTimeout()
        } catch {
            log.error("CallManager startCall FAILED: \(error)")
            problem("outgoing call setup failed: \(error)")
            await resetLocal()
        }
    }

    public func acceptCall() async {
        guard let offer = pendingOfferSdp, !accepting, state.value != .connected else {
            log.log("CallManager accept SKIP pendingOffer=\(pendingOfferSdp != nil) accepting=\(accepting) state=\(state.value)")
            return
        }
        accepting = true
        defer { accepting = false }
        do {
            resetMediaFlags()
            status.value = "call.securingConnection"
            let rtc = await createSession()
            try await step("call.securingConnection") { try await rtc.setRemoteDescription(type: "offer", sdp: offer) }
            remoteDescriptionSet = true
            try await flushPendingCandidates(rtc)
            try await step("call.enablingMic") { try await rtc.startAudio(micEnabled: self.micEnabled.value) }
            let answer = try await step("call.buildingAnswer") { try await rtc.createAnswer() }
            _ = await send("call_answer", ["sdp": .string(answer)])
            status.value = "call.connecting"
            setState(.connected)
        } catch {
            log.error("CallManager accept FAILED: \(error)")
            problem("accept failed: \(error)")
            _ = await send("call_end", [:])
            await resetLocal()
        }
    }

    public func declineCall() async {
        guard state.value != .idle else { return }
        _ = await send("call_reject", [:])
        await resetLocal()
    }

    public func cancelCall() async {
        guard state.value != .idle else { return }
        _ = await send("call_cancel", [:])
        await resetLocal()
    }

    public func endCall(notifyRemote: Bool = true) async {
        guard state.value != .idle else { return }
        if notifyRemote { _ = await send("call_end", [:]) }
        await resetLocal()
    }

    /// Красная кнопка: пока исходящий не ответили — отмена, иначе — завершение.
    public func hangUp() async {
        if state.value == .outgoingRinging { await cancelCall() } else { await endCall() }
    }

    /// "Ответить" нажали в CallKit, когда offer ещё не пришёл — принять, как только придёт.
    public func requestAutoAccept() async {
        if state.value == .incomingRinging && pendingOfferSdp != nil { await autoAcceptAndOpen() } else { autoAcceptPending = true }
    }

    /// Звонок из пуша так и не пришёл (отменён, истёк) — «ответить сразу» к следующему не относится.
    public func cancelAutoAccept() {
        autoAcceptPending = false
    }

    private func autoAcceptAndOpen() async {
        await resolvePeer()
        await acceptCall()
        openCallScreen.emit(())
    }

    public func toggleMic() {
        micEnabled.value.toggle()
        rtc?.setMicEnabled(micEnabled.value)
    }

    public func toggleVideo() async {
        guard let rtc else { return }
        let enabled = !videoEnabled.value
        do { try await rtc.setVideoEnabled(enabled) } catch {
            log.error("CallManager toggleVideo FAILED: \(error)")
            return
        }
        videoEnabled.value = enabled
        _ = await send("call_video_state", ["enabled": .bool(enabled)])
    }

    public func switchCamera() async {
        guard let rtc, videoEnabled.value else { return }
        do { usingFrontCamera.value = try await rtc.switchCamera() } catch { log.error("CallManager switchCamera FAILED: \(error)") }
    }

    // MARK: - соединение

    private func iceServers() async -> [IceServer] {
        let stun = IceServer(urls: [Self.stun], username: nil, credential: nil)
        guard let token = session.token, let creds = await api.getTurnCredentials(token: token) else { return [stun] }
        let urls: [String] = creds["urls"]?.array?.compactMap(\.string) ?? creds["urls"]?.string.map { [$0] } ?? []
        guard !urls.isEmpty else { return [stun] }
        return [stun, IceServer(urls: urls, username: creds["username"]?.string, credential: creds["password"]?.string)]
    }

    /// Шаг установки: этап — на экран и в журнал. WebRTC не ответил за [stepTimeout] — ошибка, а не вечное ожидание.
    private func step<T: Sendable>(_ key: String, _ block: @escaping @Sendable () async throws -> T) async throws -> T {
        status.value = key
        log.log("CallManager step \(key)")
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await block() }
            group.addTask { [stepTimeout] in try await Task.sleep(for: stepTimeout); return nil }
            guard let first = try await group.next(), let value = first else {
                group.cancelAll()
                throw StepTimeout(step: key)
            }
            group.cancelAll()
            return value
        }
    }

    private struct StepTimeout: Error, CustomStringConvertible {
        let step: String
        var description: String { "WebRTC step \(step) timed out" }
    }

    private func createSession() async -> RtcSession {
        let servers = await iceServers()
        log.log("CallManager createSession ice=\(servers.count)")
        let session = engine.createSession(iceServers: servers, events: EventsBridge(manager: self))
        rtc = session
        return session
    }

    /// События WebRTC приходят с его потоков — переносим на actor.
    private final class EventsBridge: RtcEvents, @unchecked Sendable {
        weak var manager: CallManager?
        init(manager: CallManager) { self.manager = manager }
        func onIceCandidate(_ candidate: String, sdpMid: String?, sdpMLineIndex: Int32) {
            Task { await manager?.sendIce(candidate, sdpMid, sdpMLineIndex) }
        }
        func onConnected() { Task { await manager?.markConnected() } }
        func onFailed() { Task { await manager?.connectionFailed() } }
        func onRenegotiationNeeded() { Task { await manager?.renegotiateIfConnected() } }
    }

    private func sendIce(_ candidate: String, _ mid: String?, _ index: Int32) async {
        _ = await send("call_ice", ["candidate": .string(candidate), "sdpMid": .optional(mid), "sdpMLineIndex": .int(Int64(index))])
    }

    private func markConnected() {
        if connectedAt.value == nil { connectedAt.value = now() }
        if state.value != .connected && state.value != .idle { setState(.connected) }
    }

    private func connectionFailed() async {
        log.log("CallManager connection FAILED — ending call")
        guard state.value != .idle else { return }
        problem("WebRTC connection failed, media \(connectedAt.value != nil ? "was connected" : "never connected")")
        _ = await send("call_end", [:])
        await resetLocal()
    }

    private func renegotiateIfConnected() async {
        guard state.value == .connected, let rtc else { return }
        makingOffer = true
        defer { makingOffer = false }
        do {
            let offer = try await rtc.createOffer()
            _ = await send("call_offer", ["sdp": .string(offer), "renegotiation": .bool(true)])
        } catch {
            log.error("CallManager renegotiate FAILED: \(error)")
        }
    }

    private func flushPendingCandidates(_ rtc: RtcSession) async throws {
        for (c, mid, index) in pendingCandidates { try await rtc.addIceCandidate(c, sdpMid: mid, sdpMLineIndex: index) }
        pendingCandidates = []
    }

    private func resetMediaFlags() {
        micEnabled.value = true
        videoEnabled.value = false
        remoteVideoEnabled.value = false
        usingFrontCamera.value = true
    }

    // MARK: - сигналы

    /// false — сигнал не ушёл на сервер (нет соединения или не зашифровался).
    private func send(_ type: String, _ payload: [String: JSONValue]) async -> Bool {
        guard let to = peer.value?.deviceId else { return false }
        return await sendTo(to, type, payload, currentCallId)
    }

    private func sendTo(_ to: String, _ type: String, _ payload: [String: JSONValue], _ callId: String?) async -> Bool {
        var body = payload
        body["type"] = .string(type)
        let envelope: Envelope
        do { envelope = try await messenger.sealCallSignal(to, payload: body) } catch {
            log.error("CallManager encrypt-FAILED type=\(type) to=\(to): \(error) — dropped")
            return false
        }
        var withId = envelope
        withId["call_id"] = .optional(callId)
        return await signaling.sendCallSignal(toDeviceId: to, type: type, payload: withId)
    }

    private func handleSignal(_ envelope: [String: JSONValue]) async {
        guard let type = envelope["type"]?.string else { return }
        if type == "call_unavailable" {
            if state.value != .idle { await resetLocal(peerWasUnavailable: true) }
            return
        }
        guard let sender = envelope["sender_device_id"]?.string else {
            // сервер отклонил звонок за собеседника (его приложение было не на связи) — без отправителя
            if state.value == .outgoingRinging && (type == "call_reject" || type == "call_busy") {
                await endWithReason(type == "call_busy" ? "call.busy" : "call.declined")
            }
            return
        }
        let activePeer = peer.value?.deviceId
        if Self.requiresActivePeer.contains(type) && sender != activePeer {
            log.log("CallManager IGNORING \(type) from=\(sender) — active peer=\(activePeer ?? "nil")")
            return
        }
        guard let payload = await router.openCallSignal(sender, envelope) else {
            log.log("CallManager \(type) from=\(sender): decrypt failed, dropped")
            problem("call signal \(type) from=\(sender) could not be decrypted")
            return
        }
        let callId = envelope["call_id"]?.string
        log.log("CallManager signal \(type) from=\(sender) state=\(state.value)")
        switch type {
        case "call_offer": await onOffer(sender, callId, payload)
        case "call_answer":
            guard let sdp = payload["sdp"]?.string, let rtc else { return }
            guard rtc.signalingState == .haveLocalOffer else {
                log.log("CallManager call_answer while not have-local-offer — duplicate/stale, ignored")
                return
            }
            do {
                try await rtc.setRemoteDescription(type: "answer", sdp: sdp)
                remoteDescriptionSet = true
                try await flushPendingCandidates(rtc)
            } catch {
                log.error("CallManager call_answer FAILED: \(error)")
            }
        case "call_ice":
            guard let candidate = payload["candidate"]?.string else { return }
            let mid = payload["sdpMid"]?.string
            let index = Int32(payload["sdpMLineIndex"]?.int ?? 0)
            if remoteDescriptionSet, let rtc { try? await rtc.addIceCandidate(candidate, sdpMid: mid, sdpMLineIndex: index) }
            else { pendingCandidates.append((candidate, mid, index)) }
        case "call_video_state": remoteVideoEnabled.value = payload["enabled"]?.bool ?? false
        case "call_reject": await endWithReason("call.declined")
        case "call_busy": await endWithReason("call.busy")
        case "call_cancel", "call_end": await resetLocal()
        default: break
        }
    }

    private func onOffer(_ sender: String, _ callId: String?, _ payload: [String: JSONValue]) async {
        guard let sdp = payload["sdp"]?.string else { return }
        if payload["renegotiation"]?.bool == true {
            guard sender == peer.value?.deviceId, let rtc else { return }
            let collision = makingOffer || rtc.signalingState != .stable
            if collision && !polite {
                log.log("CallManager renegotiation offer collision — impolite side, ignoring theirs")
                return
            }
            do {
                if collision { try await rtc.rollback() }
                try await rtc.setRemoteDescription(type: "offer", sdp: sdp)
                let answer = try await rtc.createAnswer()
                _ = await send("call_answer", ["sdp": .string(answer)])
            } catch {
                log.error("CallManager renegotiation FAILED: \(error)")
            }
            return
        }
        guard state.value == .idle else {
            _ = await sendTo(sender, "call_busy", [:], callId)
            return
        }
        currentCallId = callId
        // кто звонит — из своих чатов, сразу: экран входящего не должен мигать "Unknown"
        let caller = knownPeer(sender)
        peer.value = caller
        pendingOfferSdp = sdp
        startedAt = now()
        connectedAt.value = nil
        isOutgoing = false
        remoteDescriptionSet = false
        pendingCandidates = []
        setState(.incomingRinging)
        armRingTimeout()
        if autoAcceptPending {
            autoAcceptPending = false
            await autoAcceptAndOpen()
        } else {
            incomingCalls.emit(IncomingCall(callId: callId ?? "", peer: caller))
            await resolvePeer()
        }
    }

    /// Дозвон не вечный: исходящий — отмена у собеседника, «не отвечает» и пропущенный ему;
    /// входящий — ждём чуть дольше звонящего.
    private func armRingTimeout() {
        ringTimer?.cancel()
        let callId = currentCallId
        let ringing = state.value
        let timeout = ringing == .outgoingRinging ? ringTimeout : ringTimeout + .seconds(5)
        ringTimer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.ringTimedOut(ringing, callId)
        }
    }

    private func ringTimedOut(_ ringing: CallState, _ callId: String?) async {
        guard state.value == ringing, currentCallId == callId else { return }
        log.log("CallManager ring timeout state=\(ringing)")
        ringTimer = nil
        if ringing == .outgoingRinging {
            _ = await send("call_cancel", [:])
            status.value = "call.noAnswer"
            try? await Task.sleep(for: endReasonDelay)
            await resetLocal(peerWasUnavailable: true)
        } else {
            await resetLocal()
        }
    }

    private func knownPeer(_ deviceId: String) -> CallPeer {
        if let owner = router.knownOwner(deviceId) { return CallPeer(deviceId: deviceId, login: owner.login, accountId: owner.accountId) }
        if let chat = chats.knownPeers().first(where: { $0.lastKnownDeviceId == deviceId }) {
            return CallPeer(deviceId: deviceId, login: chat.peerLogin, accountId: chat.lastKnownAccountId)
        }
        return CallPeer(deviceId: deviceId)
    }

    private func resolvePeer() async {
        guard let p = peer.value, p.login == nil, let token = session.token,
              let owner = await api.getDeviceOwnerInfo(token: token, deviceId: p.deviceId), peer.value?.deviceId == p.deviceId else { return }
        peer.value = CallPeer(deviceId: p.deviceId, login: owner.login, accountId: owner.accountId)
    }

    private func endWithReason(_ key: String) async {
        status.value = key
        try? await Task.sleep(for: endReasonDelay)
        await resetLocal()
    }

    private func resetLocal(peerWasUnavailable: Bool = false) async {
        guard state.value != .idle || rtc != nil else { return }
        // ответили, а звук так и не соединился — собеседники друг друга не услышали
        if state.value == .connected && connectedAt.value == nil { problem("call ended before media connected") }
        ringTimer?.cancel()
        ringTimer = nil
        await logCall(peerWasUnavailable: peerWasUnavailable)
        rtc?.close()
        rtc = nil
        pendingOfferSdp = nil
        remoteDescriptionSet = false
        pendingCandidates = []
        currentCallId = nil
        resetMediaFlags()
        peer.value = nil
        status.value = nil
        connectedAt.value = nil
        setState(.idle)
    }

    /// Запись о звонке в чат; недоступному собеседнику — "пропущенный звонок".
    private func logCall(peerWasUnavailable: Bool) async {
        guard let p = peer.value, let started = startedAt else { return }
        startedAt = nil
        let connected = connectedAt.value
        let outcome = connected != nil ? "answered" : (isOutgoing ? "no_answer" : "missed")
        guard let token = session.token, let owner = await api.getDeviceOwnerInfo(token: token, deviceId: p.deviceId) else { return }
        chats.addCallLog(owner.login, direction: isOutgoing ? "outgoing" : "incoming", outcome: outcome, timestamp: started,
                         durationSeconds: connected.map { (now() - $0) / 1000 }, accountId: owner.accountId, callId: currentCallId)
        if peerWasUnavailable && isOutgoing {
            // обычное (не тихое) сообщение — с пушем, чтобы собеседник узнал о звонке
            try? await messenger.send(to: p.deviceId, .missedCall(calledAt: started, callId: currentCallId), trackStatus: false)
        }
    }
}
