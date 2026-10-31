import AVFoundation
import CallKit
import OshinobuCore

/**
 * Звонки через CallKit: системный экран входящего (в том числе на заблокированном
 * телефоне), кнопки гарнитуры и автомобиля, история «Недавние». Громкую связь и
 * датчик приближения у уха iOS ведёт сама — вручную их не трогаем.
 *
 * Входящий при закрытом приложении приходит VoIP-пушем (PushKit): iOS требует
 * показать его через CallKit сразу, ещё до связи с сервером, — экран звонка
 * появляется по пушу, а offer приложение забирает по WebSocket (сервер держит
 * его до подключения). Пока приложение на связи, звонок приходит по WebSocket.
 */
final class CallController: NSObject, CXProviderDelegate, @unchecked Sendable {
    private let core: OshinobuCore
    private let provider: CXProvider
    private let callKit = CXCallController()
    private var uuid: UUID?
    private var tasks: [Task<Void, Never>] = []
    /// Звонок, показанный по пушу (ещё не сопоставлен с offer ядра).
    private var pushedCallId: String?
    /// Его offer по WebSocket ещё не пришёл — ядро о звонке пока не знает.
    private var awaitingOffer = false
    private var pushedTimeout: Task<Void, Never>?
    /// Сколько ждать offer после пуша: связь поднимается не мгновенно, но звонящий
    /// дольше двух минут не ждёт.
    private static let pushedOfferWait: Duration = .seconds(30)

    init(core: OshinobuCore) {
        self.core = core
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = true
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
        follow()
    }

    /// Состояние контроллера — только на главном потоке (туда же CallKit шлёт делегату).
    private func follow() {
        let calls = core.calls
        tasks.append(Task { @MainActor [weak self] in
            for await incoming in calls.incomingCalls.stream() { self?.reportIncoming(incoming) }
        })
        tasks.append(Task { @MainActor [weak self] in
            for await state in calls.state.stream() {
                guard let self else { return }
                switch state {
                case .idle: self.endSystemCall()
                case .incomingRinging:
                    // offer звонка из пуша пришёл: ядро ведёт звонок, ждать больше нечего
                    if self.awaitingOffer {
                        self.awaitingOffer = false
                        self.pushedTimeout?.cancel()
                    }
                case .connected:
                    self.pushedCallId = nil
                    if let uuid = self.uuid { self.provider.reportOutgoingCall(with: uuid, connectedAt: Date()) }
                default: break
                }
            }
        })
        tasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            for await problem in calls.problems.stream() {
                // проблема звонка — отчёт в feedback с журналом и состоянием телефона (как на Android)
                let mic = AVAudioApplication.shared.recordPermission == .granted
                self.core.reportCallProblem("\(problem)\nmic=\(mic) ws=\(self.core.ws.status.value)")
            }
        })
    }

    /// Исходящий: CallKit знает о звонке (гарнитура, «Недавние»), сам звонок ведёт ядро.
    func startCall(_ peer: CallPeer) {
        let id = UUID()
        uuid = id
        let handle = CXHandle(type: .generic, value: peer.login ?? peer.deviceId)
        callKit.request(CXTransaction(action: CXStartCallAction(call: id, handle: handle))) { [weak self] error in
            if let error { self?.core.logger.log("CallKit start failed: \(error)") }
        }
    }

    /**
     * VoIP-пуш о звонке: показать CallKit немедленно (до [completion] — требование
     * iOS). Уже идёт другой звонок — показать и тут же завершить, звонящему «занято».
     */
    func reportPushedCall(callId: String, callerDeviceId: String, completion: @escaping () -> Void) {
        if pushedCallId == callId { return completion() } // повтор того же пуша
        let id = UUID()
        let busy = uuid != nil || core.calls.state.value != .idle
        let update = CXCallUpdate()
        let login = core.chats.knownPeers().first { $0.lastKnownDeviceId == callerDeviceId }?.peerLogin
        update.remoteHandle = CXHandle(type: .generic, value: login ?? callerDeviceId)
        update.localizedCallerName = login ?? "Oshinobu"
        update.hasVideo = false
        if !busy {
            // сразу, до ответа CallKit: offer по WebSocket может прийти раньше
            uuid = id
            pushedCallId = callId
            awaitingOffer = true
            pushedTimeout?.cancel()
            pushedTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.pushedOfferWait)
                guard !Task.isCancelled, let self, self.awaitingOffer, self.pushedCallId == callId else { return }
                self.core.logger.log("Pushed call \(callId): no offer over WebSocket — ended")
                self.endPushedCall(reason: .failed)
            }
        }
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
            completion()
            guard let self else { return }
            if let error {
                // например, «Не беспокоить» или номер в блокировке — звонка на экране нет
                self.core.logger.log("CallKit pushed call report failed: \(error)")
                if self.pushedCallId == callId { self.endPushedCallLocally() }
                return
            }
            if busy {
                self.provider.reportCall(with: id, endedAt: Date(), reason: .unanswered)
                Task { await self.core.declinePendingCall(callId: callId, busy: true) }
            }
        }
        // связь с сервером — offer ждёт там
        Task { @MainActor in await AppDelegate.shared?.model.launch() }
    }

    /// Звонящий отменил до того, как мы подключились (фоновый пуш call_cancel).
    func cancelPushedCall(callId: String) {
        guard awaitingOffer, pushedCallId == callId else { return }
        endPushedCall(reason: .remoteEnded)
    }

    private func endPushedCall(reason: CXCallEndedReason) {
        pushedTimeout?.cancel()
        pushedTimeout = nil
        pushedCallId = nil
        awaitingOffer = false
        Task { await core.calls.cancelAutoAccept() }
        guard let id = uuid else { return }
        uuid = nil
        provider.reportCall(with: id, endedAt: Date(), reason: reason)
    }

    private func reportIncoming(_ incoming: IncomingCall) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: incoming.peer.login ?? incoming.peer.deviceId)
        update.localizedCallerName = incoming.peer.login
        update.hasVideo = false
        // offer звонка, уже показанного по пушу, — тот же экран CallKit, только с именем
        if let pushed = pushedCallId, pushed == incoming.callId, let id = uuid {
            pushedTimeout?.cancel()
            pushedCallId = nil
            awaitingOffer = false
            provider.reportCall(with: id, updated: update)
            return
        }
        let id = UUID()
        uuid = id
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
            if let error { self?.core.logger.log("CallKit incoming report failed: \(error)") }
        }
    }

    /// Пользователь сам сбросил звонок из пуша — CallKit уже знает, reportCall не нужен.
    private func endPushedCallLocally() {
        pushedTimeout?.cancel()
        pushedTimeout = nil
        pushedCallId = nil
        awaitingOffer = false
        uuid = nil
        Task { await core.calls.cancelAutoAccept() }
    }

    private func endSystemCall() {
        // offer звонка из пуша ещё не пришёл — ядро и не начинало звонок
        guard !awaitingOffer else { return }
        pushedCallId = nil
        guard let id = uuid else { return }
        uuid = nil
        provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded)
    }

    // MARK: CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        Task { await core.calls.endCall() }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        configureAudioSession()
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        configureAudioSession()
        Task {
            // ответили по пушу, offer ещё в пути — ядро примет его сразу, как придёт
            if awaitingOffer { await core.calls.requestAutoAccept() } else { await core.calls.acceptCall() }
            action.fulfill()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if awaitingOffer, let callId = pushedCallId {
            // offer ещё не пришёл: отклоняем через сервер, без WebSocket
            endPushedCallLocally()
            Task {
                await core.declinePendingCall(callId: callId)
                action.fulfill()
            }
            return
        }
        uuid = nil
        Task {
            if core.calls.state.value == .incomingRinging { await core.calls.declineCall() } else { await core.calls.hangUp() }
            action.fulfill()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task {
            if core.calls.micEnabled.value == action.isMuted { await core.calls.toggleMic() }
            action.fulfill()
        }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) { WebRtcEngine.audioActivated(audioSession) }
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) { WebRtcEngine.audioDeactivated(audioSession) }

    /// Режим голосового чата: эхоподавление, у уха — разговорный динамик, датчик приближения — сам iOS.
    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
    }

    /// Громкая связь (кнопка на экране звонка).
    func setSpeaker(_ on: Bool) {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)
    }
}
