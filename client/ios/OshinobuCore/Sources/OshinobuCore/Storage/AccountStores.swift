import Foundation

// Хранилища аккаунта и ключей (как core/storage/AccountStores.kt, те же ключи).

/// Токен и логин — в [Prefs].
public final class Session: @unchecked Sendable {
    private let prefs: Prefs

    public init(prefs: Prefs) { self.prefs = prefs }

    private func get(_ k: String) -> String? { prefs.string(k) }
    private func put(_ k: String, _ v: String?) { if let v { prefs.set(k, v) } else { prefs.remove(k) } }

    public var token: String? { get { get("auth_token") } set { put("auth_token", newValue) } }
    public var login: String? { get { get("saved_login") } set { put("saved_login", newValue) } }
    public var accountId: String? { get { get("saved_account_id") } set { put("saved_account_id", newValue) } }
}

/// Identity-ключ устройства (подписи) и подписанный им X25519-ключ для DH.
public struct DeviceIdentity: Sendable {
    public let identity: Ed25519KeyPair
    public let identityDh: X25519KeyPair
    public let identityDhSignature: Data
}

/// Долговременные ключи устройства — отдельными строками secure storage.
public final class KeyStore: @unchecked Sendable {
    private let secure: SecureStore
    private let lock = NSLock()
    private typealias K = StoredIdentity.Key

    public init(secure: SecureStore) { self.secure = secure }

    public func deviceId() -> String? { secure.read(K.deviceId) }
    public func saveDeviceId(_ id: String) { secure.write(K.deviceId, id) }

    /// Ключи для X3DH и подписей; nil — устройство ещё не настроено.
    public func loadIdentity() -> StoredIdentity? {
        let names = [K.deviceId, K.identityPrivate, K.identityPublic, K.identityDhPrivate, K.identityDhPublic, K.identityDhSignature,
                     K.signedPrekeyPrivate, K.signedPrekeyPublic, K.oneTimePrekeys]
        var store: [String: String] = [:]
        for n in names { if let v = secure.read(n) { store[n] = v } }
        return try? StoredIdentity.fromStore(store)
    }

    /// Identity Ed25519 + подписанный X25519 identity_dh — создаются один раз за жизнь устройства.
    public func getOrCreateIdentity() throws -> DeviceIdentity {
        try lock.sync {
            let identity: Ed25519KeyPair
            if let seed = secure.read(K.identityPrivate) {
                identity = try Ed25519KeyPair.fromSeed(try unb64(seed))
            } else {
                identity = Ed25519KeyPair.generate()
                secure.write(K.identityPrivate, b64(identity.seed))
                secure.write(K.identityPublic, b64(identity.publicKey))
            }
            if let p = secure.read(K.identityDhPrivate), let q = secure.read(K.identityDhPublic), let s = secure.read(K.identityDhSignature) {
                return DeviceIdentity(identity: identity, identityDh: try X25519KeyPair(privateKey: try unb64(p), publicKey: try unb64(q)), identityDhSignature: try unb64(s))
            }
            let dh = X25519KeyPair.generate()
            let sig = try identity.sign(dh.publicKey)
            secure.write(K.identityDhPrivate, b64(dh.privateKey))
            secure.write(K.identityDhPublic, b64(dh.publicKey))
            secure.write(K.identityDhSignature, b64(sig))
            return DeviceIdentity(identity: identity, identityDh: dh, identityDhSignature: sig)
        }
    }

    /// Новый signed prekey (заменяет прежний). Возвращает публичную часть и подпись.
    public func createSignedPrekey(identity: Ed25519KeyPair) throws -> (publicKey: Data, signature: Data) {
        let kp = X25519KeyPair.generate()
        secure.write(K.signedPrekeyPrivate, b64(kp.privateKey))
        secure.write(K.signedPrekeyPublic, b64(kp.publicKey))
        return (kp.publicKey, try identity.sign(kp.publicKey))
    }

    private func oneTimeList() -> [JSONValue] {
        secure.read(K.oneTimePrekeys).flatMap { try? JSONValue.parse($0).array } ?? []
    }

    /// ДОПОЛНЯЕТ сохранённые одноразовые prekey; возвращает новые публичные части.
    public func createOneTimePrekeys(_ count: Int) -> [Data] {
        lock.sync {
            let fresh = (0..<count).map { _ in X25519KeyPair.generate() }
            let list = oneTimeList() + fresh.map { JSONValue.object(["public": .string(b64($0.publicKey)), "private": .string(b64($0.privateKey))]) }
            secure.write(K.oneTimePrekeys, JSONValue.array(list).encoded())
            return fresh.map(\.publicKey)
        }
    }

    /// Одноразовый prekey использован — приватную часть удаляем сразу (forward secrecy).
    public func deleteOneTimePrekey(_ publicKeyB64: String) {
        lock.sync {
            let list = oneTimeList()
            let kept = list.filter { $0["public"]?.string != publicKeyB64 }
            if kept.count != list.count { secure.write(K.oneTimePrekeys, JSONValue.array(kept).encoded()) }
        }
    }

    /// Стирает ВСЁ secure storage (выход из аккаунта).
    public func wipeAll() { secure.deleteAll() }
}

/**
 * Состояние ratchet по устройствам собеседников + архив прежних сессий (до 3) —
 * только для приёма: собеседник, ещё не узнавший о сбросе или новой X3DH,
 * шифрует старой (см. MessageRouter). Как на Android с +70.
 */
public final class SessionStore: @unchecked Sendable {
    private let secure: SecureStore
    private static let maxArchived = 3

    public init(secure: SecureStore) { self.secure = secure }

    private func key(_ d: String) -> String { "ratchet:\(d)" }
    private func initKey(_ d: String) -> String { "x3dh_init:\(d)" }
    private func archiveKey(_ d: String) -> String { "ratchet_archive:\(d)" }

    public func get(_ deviceId: String) -> RatchetState? {
        secure.read(key(deviceId)).flatMap { try? RatchetState.fromJSON(try JSONValue.parse($0)) }
    }

    public func save(_ deviceId: String, _ state: RatchetState) { secure.write(key(deviceId), state.toJSON().encoded()) }

    public func clear(_ deviceId: String) {
        secure.delete(key(deviceId))
        clearPendingInit(deviceId)
    }

    /// X3DH-поля исходящей сессии — к КАЖДОМУ сообщению, пока собеседник не ответил.
    public func pendingInit(_ deviceId: String) -> Envelope? {
        secure.read(initKey(deviceId)).flatMap { try? JSONValue.parse($0).object }
    }

    public func savePendingInit(_ deviceId: String, _ header: Envelope) { secure.write(initKey(deviceId), JSONValue.object(header).encoded()) }

    /// Собеседник ответил — сессия у него точно есть.
    public func clearPendingInit(_ deviceId: String) { secure.delete(initKey(deviceId)) }

    public func archived(_ deviceId: String) -> [RatchetState] {
        (secure.read(archiveKey(deviceId)).flatMap { try? JSONValue.parse($0).array } ?? []).compactMap { try? RatchetState.fromJSON($0) }
    }

    private func saveArchive(_ deviceId: String, _ states: [RatchetState]) {
        if states.isEmpty { secure.delete(archiveKey(deviceId)) }
        else { secure.write(archiveKey(deviceId), JSONValue.array(states.prefix(Self.maxArchived).map { $0.toJSON() }).encoded()) }
    }

    /// Текущую сессию — в архив; текущей больше нет, X3DH-поля стёрты.
    public func retire(_ deviceId: String) {
        if let current = get(deviceId) { saveArchive(deviceId, [current] + archived(deviceId)) }
        clear(deviceId)
    }

    /// [state] — новая текущая (поднята из X3DH-полей входящего), прежняя — в архив.
    public func replace(_ deviceId: String, _ state: RatchetState) {
        retire(deviceId)
        save(deviceId, state)
    }

    /// Архивная сессия [index] расшифровала входящее — она снова текущая, текущая — в архив.
    public func promote(_ deviceId: String, index: Int, state: RatchetState) {
        var rest = archived(deviceId)
        if rest.indices.contains(index) { rest.remove(at: index) }
        saveArchive(deviceId, (get(deviceId).map { [$0] } ?? []) + rest)
        clearPendingInit(deviceId)
        save(deviceId, state)
    }
}

/// device_id собеседника → его account_id.
public final class PeerAccountStore: @unchecked Sendable {
    private let secure: SecureStore
    public init(secure: SecureStore) { self.secure = secure }
    public func get(_ deviceId: String) -> String? { secure.read("peer_account:\(deviceId)") }
    public func save(_ deviceId: String, _ accountId: String) { secure.write("peer_account:\(deviceId)", accountId) }
}

/// Последний виденный identity DH-ключ устройства собеседника (диагностика подмены).
public final class PeerIdentityStore: @unchecked Sendable {
    private let secure: SecureStore
    public init(secure: SecureStore) { self.secure = secure }
    public func get(_ deviceId: String) -> String? { secure.read("peer_identity:\(deviceId)") }
    public func save(_ deviceId: String, _ identityDhB64: String) { secure.write("peer_identity:\(deviceId)", identityDhB64) }
}

/// JSON-список заданий под одним ключом secure storage.
public class JsonQueueStore: @unchecked Sendable {
    private let secure: SecureStore
    private let key: String
    private let lock = NSLock()

    public init(secure: SecureStore, key: String) {
        self.secure = secure
        self.key = key
    }

    public func all() -> [[String: JSONValue]] {
        lock.sync { (secure.read(key).flatMap { try? JSONValue.parse($0).array } ?? []).compactMap(\.object) }
    }

    /// Добавляет задание; задание с тем же "id" заменяется.
    public func put(_ job: [String: JSONValue]) {
        lock.sync {
            let id = job["id"]?.string
            var items = (secure.read(key).flatMap { try? JSONValue.parse($0).array } ?? []).filter { $0["id"]?.string != id }
            items.append(.object(job))
            secure.write(key, JSONValue.array(items).encoded())
        }
    }

    public func remove(_ id: String) {
        lock.sync {
            let items = (secure.read(key).flatMap { try? JSONValue.parse($0).array } ?? []).filter { $0["id"]?.string != id }
            secure.write(key, JSONValue.array(items).encoded())
        }
    }
}

/// Готовые конверты, ждущие ack сервера.
public final class SendQueueStore: JsonQueueStore, @unchecked Sendable {
    public init(secure: SecureStore) { super.init(secure: secure, key: "send_queue") }

    public func add(id: String, toDeviceId: String, envelope: Envelope, silent: Bool = false, messageId: String? = nil, peerLogin: String? = nil) {
        var job: [String: JSONValue] = ["id": .string(id), "to_device_id": .string(toDeviceId), "envelope": .object(envelope), "silent": .bool(silent)]
        if let messageId { job["message_id"] = .string(messageId) }
        if let peerLogin { job["peer_login"] = .string(peerLogin) }
        put(job)
    }
}
