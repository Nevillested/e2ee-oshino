import Foundation

// Сборка и вскрытие конверта — чистая криптография отправки и приёма (как
// core/protocol/PeerCipher.kt). Хранилище, сеть и самолечение сюда НЕ входят.
//
// Конверт на проводе: { nonce, ciphertext, mac, ratchet_pubkey, message_number,
// sender_device_id [, sender_identity_dh_pubkey, ephemeral_pubkey,
// used_one_time_prekey] } — все заголовочные поля входят в AAD.

public enum PeerCipher {
    /// Новая исходящая сессия по prekey-бандлу собеседника. initHeader прикладывается
    /// к сообщениям, пока собеседник не ответил.
    public static func startOutgoingSession(bundle: [String: JSONValue], myDeviceId: String, myIdentityDh: X25519KeyPair) throws -> (RatchetState, Envelope) {
        let out = try establishOutgoingRoot(bundle: bundle, myDeviceId: myDeviceId, myIdentityDh: myIdentityDh)
        return (RatchetState.initAsSender(rootKey: out.rootKey, ephemeralKeyPair: out.ephemeralKeyPair), out.initHeader)
    }

    /// Шифрует [plaintext] следующим ключом [state] (state продвигается — сохранить его до отправки).
    public static func sealText(_ state: inout RatchetState, plaintext: String, myDeviceId: String, initHeader: Envelope? = nil) throws -> Envelope {
        let next = try state.nextSendingKey()
        var header = next.header
        header["sender_device_id"] = .string(myDeviceId)
        if let initHeader { header.merge(initHeader) { _, new in new } }
        let encrypted = try encryptMessage(messageKey: next.messageKey, plaintext: plaintext, aad: header)
        return encrypted.merging(header) { a, _ in a }
    }

    public static func seal(_ state: inout RatchetState, inner: InnerMessage, myDeviceId: String, initHeader: Envelope? = nil) throws -> Envelope {
        try sealText(&state, plaintext: inner.encode(), myDeviceId: myDeviceId, initHeader: initHeader)
    }

    /// Расшифровка входящего конверта текущим состоянием (state продвигается).
    public static func open(_ state: inout RatchetState, envelope: Envelope) throws -> InnerMessage {
        let key = try state.nextReceivingKey(envelope: envelope)
        return try InnerMessage.decode(try decryptMessage(messageKey: key, envelope: envelope))
    }

    /// Свежая входящая сессия из X3DH-полей конверта; nil — их там нет.
    public static func startIncomingSession(envelope: Envelope, me: LocalIdentity) throws -> (RatchetState, X3dhIncoming)? {
        guard let incoming = try establishIncomingRoot(envelope: envelope, me: me),
              let ephemeralB64 = envelope["ephemeral_pubkey"]?.string else { return nil }
        let state = RatchetState.initAsReceiver(rootKey: incoming.rootKey, remoteEphemeralPubkey: try unb64(ephemeralB64))
        return (state, incoming)
    }
}
