import Foundation

/**
 * Зашифровать сообщение собеседнику и поставить в надёжную очередь — один путь
 * для всех видов отправки (как core/service/PeerMessenger.kt). Нет сессии с
 * устройством — prekey-бандл и X3DH; X3DH-поля прикладываются к каждому
 * сообщению, пока собеседник не ответил.
 */
public final class PeerMessenger: @unchecked Sendable {
    private let api: ApiClient
    private let session: Session
    private let keys: KeyStore
    private let sessions: SessionStore
    private let peerAccounts: PeerAccountStore
    private let peerIdentities: PeerIdentityStore
    private let chats: ChatStore
    private let queue: SendQueueProcessor
    private let sendLock: KeyedMutex
    private let log: Logger

    public init(api: ApiClient, session: Session, keys: KeyStore, sessions: SessionStore, peerAccounts: PeerAccountStore,
                peerIdentities: PeerIdentityStore, chats: ChatStore, queue: SendQueueProcessor, sendLock: KeyedMutex, log: Logger = NoopLogger()) {
        self.api = api
        self.session = session
        self.keys = keys
        self.sessions = sessions
        self.peerAccounts = peerAccounts
        self.peerIdentities = peerIdentities
        self.chats = chats
        self.queue = queue
        self.sendLock = sendLock
        self.log = log
    }

    public func send(to peerDeviceId: String, _ inner: InnerMessage, peerLogin: String? = nil, silent: Bool = false,
                     trackStatus: Bool? = nil, onAcked: (@Sendable () async -> Void)? = nil) async throws {
        precondition(!peerDeviceId.isEmpty, "нет device_id собеседника")
        let track = trackStatus ?? !silent
        try await sendLock.run(peerDeviceId) {
            let envelope = try await self.sealLocked(peerDeviceId, inner.encode())
            self.queue.enqueue(toDeviceId: peerDeviceId, envelope: envelope, deliveryId: inner.messageId, silent: silent,
                               messageId: track ? inner.messageId : nil, peerLogin: track ? peerLogin : nil, onAcked: onAcked)
        }
    }

    /// Сигнал звонка: тот же ratchet, но конверт уходит сразу по WebSocket, не через очередь.
    public func sealCallSignal(_ peerDeviceId: String, payload: [String: JSONValue]) async throws -> Envelope {
        try await sendLock.run(peerDeviceId) { try await self.sealLocked(peerDeviceId, JSONValue.object(payload).encoded()) }
    }

    /// Шифрует следующим ключом сессии (нет сессии — X3DH). Вызывать под [sendLock].
    private func sealLocked(_ peerDeviceId: String, _ plaintext: String) async throws -> Envelope {
        guard let myDeviceId = keys.deviceId() else { throw ApiError("error.deviceNotRegistered") }
        var initHeader: Envelope?
        var state: RatchetState
        if let existing = sessions.get(peerDeviceId) {
            state = existing
            initHeader = sessions.pendingInit(peerDeviceId)
        } else {
            guard let token = session.token else { throw ApiError("error.notSignedIn") }
            let bundle = try await api.getPrekeyBundle(token: token, deviceId: peerDeviceId)
            if let accountId = bundle["account_id"]?.string { peerAccounts.save(peerDeviceId, accountId) }
            if let dh = bundle["identity_dh_pubkey"]?.string { peerIdentities.save(peerDeviceId, dh) }
            let me = try keys.getOrCreateIdentity()
            let (fresh, header) = try PeerCipher.startOutgoingSession(bundle: bundle, myDeviceId: myDeviceId, myIdentityDh: me.identityDh)
            state = fresh
            initHeader = header
            sessions.savePendingInit(peerDeviceId, header)
            log.log("PeerMessenger: fresh X3DH session to=\(peerDeviceId)")
        }
        let envelope = try PeerCipher.sealText(&state, plaintext: plaintext, myDeviceId: myDeviceId, initHeader: initHeader)
        sessions.save(peerDeviceId, state) // ключ израсходован — сохраняем ДО отправки
        return envelope
    }

    /// Служебное сообщение; ошибки только в журнал.
    public func sendControl(to peerDeviceId: String, _ inner: InnerMessage) async {
        guard !peerDeviceId.isEmpty else { return }
        do { try await send(to: peerDeviceId, inner, silent: true) }
        catch { log.log("ControlMessageSender send-FAILED to=\(peerDeviceId) type=\(inner.type) error=\(error)") }
    }

    /// Актуальный device_id собеседника по логину (и запомнить его в чате); при ошибке — [fallback].
    public func resolvePeerDeviceId(login: String, fallback: String) async -> String {
        guard let token = session.token,
              let devices = try? await api.getDevicesByLogin(token: token, login: login),
              let id = devices.devices.first?["device_id"]?.string else { return fallback }
        chats.setLastKnownDeviceId(login, deviceId: id)
        return id
    }
}

/// Регистрация устройства и пополнение одноразовых prekey.
public final class DeviceSetup: @unchecked Sendable {
    private let api: ApiClient
    private let keys: KeyStore
    private let log: Logger
    private static let lowWatermark = 5
    private static let targetPool = 20

    public init(api: ApiClient, keys: KeyStore, log: Logger = NoopLogger()) {
        self.api = api
        self.keys = keys
        self.log = log
    }

    /// Первый вход на этом устройстве: ключи → /register-device → prekeys → сохранить device_id.
    public func ensureDeviceRegistered(token: String) async throws {
        if keys.deviceId() != nil { return }
        let me = try keys.getOrCreateIdentity()
        let deviceId = try await api.registerDevice(token: token, identityPubkey: b64(me.identity.publicKey),
                                                    identityDhPubkey: b64(me.identityDh.publicKey), identityDhSignature: b64(me.identityDhSignature))
        let spk = try keys.createSignedPrekey(identity: me.identity)
        let otps = keys.createOneTimePrekeys(Self.targetPool)
        try await api.uploadPrekeys(token: token, deviceId: deviceId, signedPrekey: b64(spk.publicKey),
                                    signedPrekeySignature: b64(spk.signature), oneTimePrekeys: otps.map(b64))
        // device_id — последним: пока его нет, при следующем запуске регистрация повторится
        keys.saveDeviceId(deviceId)
    }

    /// На сервере осталось ≤ 5 одноразовых ключей — догоняем до 20.
    public func ensurePrekeysTopped(token: String, deviceId: String) async {
        guard let remaining = await api.getPrekeyCount(token: token, deviceId: deviceId), remaining <= Self.lowWatermark,
              let identity = keys.loadIdentity(), let spk = identity.signedPrekey else { return }
        let needed = Self.targetPool - remaining
        guard needed > 0 else { return }
        do {
            let fresh = keys.createOneTimePrekeys(needed)
            try await api.uploadPrekeys(token: token, deviceId: deviceId, signedPrekey: b64(spk.publicKey),
                                        signedPrekeySignature: b64(try identity.identity.sign(spk.publicKey)), oneTimePrekeys: fresh.map(b64))
            log.log("PrekeyReplenisher topped up \(needed) one-time prekeys (had \(remaining))")
        } catch {
            log.log("PrekeyReplenisher failed: \(error)")
        }
    }
}
