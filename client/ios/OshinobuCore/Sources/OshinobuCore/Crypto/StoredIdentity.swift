import Foundation

/// Долговременные ключи устройства: плоский набор строк "имя → base64",
/// одноразовые prekey — JSON-список {"public", "private"} (имена — как у Android,
/// core/crypto/StoredIdentity.kt). На iOS лежит в Keychain ([KeyStore]).
public final class StoredIdentity: LocalIdentity {
    public let deviceId: String?
    public let identity: Ed25519KeyPair
    public let identityDh: X25519KeyPair
    public let identityDhSignature: Data
    public let signedPrekey: X25519KeyPair?
    public private(set) var oneTimePrekeys: [X25519KeyPair]

    public init(deviceId: String?, identity: Ed25519KeyPair, identityDh: X25519KeyPair, identityDhSignature: Data,
                signedPrekey: X25519KeyPair?, oneTimePrekeys: [X25519KeyPair]) {
        self.deviceId = deviceId
        self.identity = identity
        self.identityDh = identityDh
        self.identityDhSignature = identityDhSignature
        self.signedPrekey = signedPrekey
        self.oneTimePrekeys = oneTimePrekeys
    }

    public func findOneTimePrekey(_ publicKeyB64: String) -> X25519KeyPair? {
        oneTimePrekeys.first { b64($0.publicKey) == publicKeyB64 }
    }

    /// Одноразовый ключ использован в DH — приватную часть больше не держим (forward secrecy).
    @discardableResult
    public func deleteOneTimePrekey(_ publicKeyB64: String) -> Bool {
        let before = oneTimePrekeys.count
        oneTimePrekeys.removeAll { b64($0.publicKey) == publicKeyB64 }
        return oneTimePrekeys.count != before
    }

    public func addOneTimePrekeys(_ keys: [X25519KeyPair]) { oneTimePrekeys += keys }

    public enum Key {
        public static let deviceId = "device_id"
        public static let identityPrivate = "identity_private_key"
        public static let identityPublic = "identity_public_key"
        public static let identityDhPrivate = "identity_dh_private_key"
        public static let identityDhPublic = "identity_dh_public_key"
        public static let identityDhSignature = "identity_dh_signature"
        public static let signedPrekeyPrivate = "signed_prekey_private_key"
        public static let signedPrekeyPublic = "signed_prekey_public_key"
        public static let oneTimePrekeys = "one_time_prekeys"
    }

    public func toStore() -> [String: String] {
        var m: [String: String] = [
            Key.identityPrivate: b64(identity.seed),
            Key.identityPublic: b64(identity.publicKey),
            Key.identityDhPrivate: b64(identityDh.privateKey),
            Key.identityDhPublic: b64(identityDh.publicKey),
            Key.identityDhSignature: b64(identityDhSignature),
            Key.oneTimePrekeys: JSONValue.array(oneTimePrekeys.map {
                .object(["public": .string(b64($0.publicKey)), "private": .string(b64($0.privateKey))])
            }).encoded(),
        ]
        if let deviceId { m[Key.deviceId] = deviceId }
        if let spk = signedPrekey {
            m[Key.signedPrekeyPrivate] = b64(spk.privateKey)
            m[Key.signedPrekeyPublic] = b64(spk.publicKey)
        }
        return m
    }

    /// nil — identity-ключей нет (устройство не зарегистрировано).
    public static func fromStore(_ store: [String: String]) throws -> StoredIdentity? {
        func bytes(_ name: String) throws -> Data? { try store[name].map(unb64) }
        guard let idPriv = try bytes(Key.identityPrivate), let idPub = try bytes(Key.identityPublic),
              let dhPriv = try bytes(Key.identityDhPrivate), let dhPub = try bytes(Key.identityDhPublic),
              let sig = try bytes(Key.identityDhSignature) else { return nil }
        var spk: X25519KeyPair?
        if let p = try bytes(Key.signedPrekeyPrivate), let q = try bytes(Key.signedPrekeyPublic) { spk = try X25519KeyPair(privateKey: p, publicKey: q) }
        var otps: [X25519KeyPair] = []
        if let raw = store[Key.oneTimePrekeys] {
            for item in try JSONValue.parse(raw).array ?? [] {
                guard let pr = item["private"]?.string, let pu = item["public"]?.string else { continue }
                otps.append(try X25519KeyPair(privateKey: try unb64(pr), publicKey: try unb64(pu)))
            }
        }
        _ = idPub // публичная часть хранится рядом; seed однозначно задаёт её
        return StoredIdentity(
            deviceId: store[Key.deviceId],
            identity: try Ed25519KeyPair.fromSeed(idPriv),
            identityDh: try X25519KeyPair(privateKey: dhPriv, publicKey: dhPub),
            identityDhSignature: sig,
            signedPrekey: spk,
            oneTimePrekeys: otps
        )
    }

    /// Новый набор ключей устройства (регистрация).
    public static func generate(deviceId: String? = nil, oneTimePrekeyCount: Int = 0) throws -> StoredIdentity {
        let identity = Ed25519KeyPair.generate()
        let identityDh = X25519KeyPair.generate()
        return StoredIdentity(
            deviceId: deviceId,
            identity: identity,
            identityDh: identityDh,
            identityDhSignature: try identity.sign(identityDh.publicKey),
            signedPrekey: X25519KeyPair.generate(),
            oneTimePrekeys: (0..<oneTimePrekeyCount).map { _ in X25519KeyPair.generate() }
        )
    }

    /// prekey-бандл в формате ответа `GET /devices/{id}/prekey-bundle` (для тестов).
    public func bundle(oneTimePrekey: X25519KeyPair? = nil) throws -> [String: JSONValue] {
        guard let spk = signedPrekey else { throw CryptoError.badKeyLength }
        var m: [String: JSONValue] = [
            "identity_pubkey": .string(b64(identity.publicKey)),
            "identity_dh_pubkey": .string(b64(identityDh.publicKey)),
            "identity_dh_signature": .string(b64(identityDhSignature)),
            "signed_prekey": .string(b64(spk.publicKey)),
            "signature": .string(b64(try identity.sign(spk.publicKey))),
        ]
        if let otp = oneTimePrekey ?? oneTimePrekeys.first { m["one_time_prekey"] = .string(b64(otp.publicKey)) }
        return m
    }
}
