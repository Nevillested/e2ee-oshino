import Foundation

// X3DH — установка сессии по бандлу prekey собеседника (как core/crypto/X3dh.kt).
//
// Identity-ключ устройства — Ed25519 (подписи); для DH — отдельный X25519-ключ
// "identity_dh", подписанный identity-ключом.
// IKM = 32×0xFF || DH1 || DH2 || DH3 [|| DH4], root = HKDF(IKM, "OshinobuX3DHRoot").

private let infoRoot = Data("OshinobuX3DHRoot".utf8)

private func deriveRootKey(_ ikm: Data) -> Data { hkdfSha256(ikm: ikm, info: infoRoot, length: 32) }

private let ffPrefix = Data(repeating: 0xFF, count: 32)

/// Свои долговременные ключи, нужные для X3DH.
public protocol LocalIdentity {
    var identityDh: X25519KeyPair { get }
    var signedPrekey: X25519KeyPair? { get }
    /// Приватная часть одноразового prekey по его публичной части (base64), если он ещё есть.
    func findOneTimePrekey(_ publicKeyB64: String) -> X25519KeyPair?
}

public struct X3dhOutgoing {
    public let rootKey: Data
    public let ephemeralKeyPair: X25519KeyPair
    /// Поля, которые уходят в первом конверте новой сессии (и входят в AAD).
    public let initHeader: Envelope
}

/// Сторона-инициатор. [bundle] — ответ `GET /devices/{id}/prekey-bundle`.
public func establishOutgoingRoot(bundle: [String: JSONValue], myDeviceId: String, myIdentityDh: X25519KeyPair) throws -> X3dhOutgoing {
    func field(_ name: String) throws -> Data {
        guard let s = bundle[name]?.string else { throw CryptoError.badEnvelope("в бандле нет поля \(name)") }
        return try unb64(s)
    }
    let remoteIdentity = try field("identity_pubkey")
    let remoteIdentityDh = try field("identity_dh_pubkey")
    let remoteSignedPrekey = try field("signed_prekey")
    let oneTimeB64 = bundle["one_time_prekey"]?.string

    let signedPrekeyValid = Ed25519KeyPair.verify(publicKey: remoteIdentity, message: remoteSignedPrekey, signature: try field("signature"))
    let identityDhValid = Ed25519KeyPair.verify(publicKey: remoteIdentity, message: remoteIdentityDh, signature: try field("identity_dh_signature"))
    guard signedPrekeyValid, identityDhValid else { throw CryptoError.signatureInvalid }

    let ephemeral = X25519KeyPair.generate()
    var ikm = ffPrefix
    ikm += try myIdentityDh.sharedSecret(remoteSignedPrekey)
    ikm += try ephemeral.sharedSecret(remoteIdentityDh)
    ikm += try ephemeral.sharedSecret(remoteSignedPrekey)
    if let otp = oneTimeB64 { ikm += try ephemeral.sharedSecret(try unb64(otp)) }

    return X3dhOutgoing(
        rootKey: deriveRootKey(ikm),
        ephemeralKeyPair: ephemeral,
        initHeader: [
            "sender_device_id": .string(myDeviceId),
            "sender_identity_dh_pubkey": .string(b64(myIdentityDh.publicKey)),
            "ephemeral_pubkey": .string(b64(ephemeral.publicKey)),
            "used_one_time_prekey": .optional(oneTimeB64),
        ]
    )
}

public struct X3dhIncoming {
    public let rootKey: Data
    /// Использованный одноразовый prekey (base64) — его приватную часть пора удалить.
    public let consumedOneTimePrekey: String?
    /// Собеседник заявил одноразовый ключ, которого у нас уже нет — сессия на 3-DH.
    public let missingOneTimePrekey: Bool
}

/// Сторона-получатель первого сообщения. nil — в конверте нет X3DH-полей
/// или у нас нет signed prekey.
public func establishIncomingRoot(envelope: Envelope, me: LocalIdentity) throws -> X3dhIncoming? {
    guard let senderIdentityDhB64 = envelope["sender_identity_dh_pubkey"]?.string,
          let senderEphemeralB64 = envelope["ephemeral_pubkey"]?.string,
          let signedPrekey = me.signedPrekey else { return nil }
    let senderIdentityDh = try unb64(senderIdentityDhB64)
    let senderEphemeral = try unb64(senderEphemeralB64)

    var ikm = ffPrefix
    ikm += try signedPrekey.sharedSecret(senderIdentityDh)
    ikm += try me.identityDh.sharedSecret(senderEphemeral)
    ikm += try signedPrekey.sharedSecret(senderEphemeral)

    var consumed: String?
    var missing = false
    if let used = envelope["used_one_time_prekey"]?.string {
        if let otp = me.findOneTimePrekey(used) {
            ikm += try otp.sharedSecret(senderEphemeral)
            consumed = used
        } else {
            missing = true
        }
    }
    return X3dhIncoming(rootKey: deriveRootKey(ikm), consumedOneTimePrekey: consumed, missingOneTimePrekey: missing)
}
