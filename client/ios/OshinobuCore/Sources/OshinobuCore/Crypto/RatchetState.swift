import Foundation

// Double Ratchet (как core/crypto/RatchetState.kt). Info-строки HKDF, маркеры
// HMAC цепочки и JSON состояния — зафиксированный формат: собеседник на Android
// должен расшифровывать, векторы сторожат совпадение.

private let maxSkippedKeys = 100
private let infoInit = Data("oshinobu-init".utf8)
private let infoRatchet = Data("oshinobu-ratchet".utf8)

private func chainStep(_ key: Data, _ marker: UInt8) -> Data { hmacSha256(key: key, data: Data([marker])) }

public enum RatchetError: Error, Equatable {
    /// Сообщение с этим номером уже расшифровано раньше — дубль, а не рассинхрон.
    case alreadyProcessed(Int)
    case gapTooLarge(from: Int, to: Int)
    case missingChain
}

/// Заголовок исходящего сообщения + ключ, которым его шифровать.
public struct SendingKey {
    public let ratchetPubkey: Data
    public let messageNumber: Int
    public let messageKey: Data

    public var header: Envelope {
        ["ratchet_pubkey": .string(b64(ratchetPubkey)), "message_number": .int(Int64(messageNumber))]
    }
}

/// Всё состояние сессии с одним устройством собеседника. Значимый тип: пробная
/// расшифровка работает с копией, а сохраняется только удачная.
///
/// ВАЖНО: сохранять состояние на диск — ТОЛЬКО после успешной расшифровки.
public struct RatchetState: Sendable {
    public var rootKey: Data
    public var sendingRatchetKeyPair: X25519KeyPair
    public var sendingChainKey: Data?
    public var receivingChainKey: Data?
    public var receivingRatchetPublicKey: Data?
    public var sendMessageNumber: Int = 0
    public var receiveMessageNumber: Int = 0
    public var needsSendingRatchet: Bool = false
    /// Ключи "перескоченных" сообщений текущей эпохи.
    public var skippedReceivingKeys: [Int: Data] = [:]

    private mutating func dhRatchetStepForSending() throws {
        guard let remote = receivingRatchetPublicKey else { throw RatchetError.missingChain }
        let newKeyPair = X25519KeyPair.generate()
        let shared = try newKeyPair.sharedSecret(remote)
        let derived = hkdfSha256(ikm: rootKey + shared, info: infoRatchet, length: 64)
        rootKey = Data(derived.prefix(32))
        sendingChainKey = Data(derived.suffix(32))
        sendingRatchetKeyPair = newKeyPair
        sendMessageNumber = 0
        needsSendingRatchet = false
    }

    private mutating func dhRatchetStepForReceiving(_ newRemotePubkey: Data) throws {
        let shared = try sendingRatchetKeyPair.sharedSecret(newRemotePubkey)
        let derived = hkdfSha256(ikm: rootKey + shared, info: infoRatchet, length: 64)
        rootKey = Data(derived.prefix(32))
        receivingChainKey = Data(derived.suffix(32))
        receivingRatchetPublicKey = newRemotePubkey
        receiveMessageNumber = 0
        needsSendingRatchet = true
        // ключи прошлой эпохи относились к другой цепочке — больше не нужны
        skippedReceivingKeys = [:]
    }

    public mutating func nextSendingKey() throws -> SendingKey {
        if needsSendingRatchet { try dhRatchetStepForSending() }
        guard let chain = sendingChainKey else { throw RatchetError.missingChain }
        let messageKey = chainStep(chain, 1)
        sendingChainKey = chainStep(chain, 2)
        let key = SendingKey(ratchetPubkey: sendingRatchetKeyPair.publicKey, messageNumber: sendMessageNumber, messageKey: messageKey)
        sendMessageNumber += 1
        return key
    }

    /// Ключ для конкретного входящего сообщения по полям его заголовка.
    public mutating func nextReceivingKey(ratchetPubkey: Data, messageNumber: Int) throws -> Data {
        if let current = receivingRatchetPublicKey, constantTimeEquals(current, ratchetPubkey) {
            // та же эпоха
        } else {
            try dhRatchetStepForReceiving(ratchetPubkey)
        }

        if let skipped = skippedReceivingKeys.removeValue(forKey: messageNumber) { return skipped }

        if messageNumber < receiveMessageNumber { throw RatchetError.alreadyProcessed(messageNumber) }
        if messageNumber - receiveMessageNumber > maxSkippedKeys {
            throw RatchetError.gapTooLarge(from: receiveMessageNumber, to: messageNumber)
        }

        while receiveMessageNumber < messageNumber {
            guard let chain = receivingChainKey else { throw RatchetError.missingChain }
            skippedReceivingKeys[receiveMessageNumber] = chainStep(chain, 1)
            receivingChainKey = chainStep(chain, 2)
            receiveMessageNumber += 1
        }

        guard let chain = receivingChainKey else { throw RatchetError.missingChain }
        let messageKey = chainStep(chain, 1)
        receivingChainKey = chainStep(chain, 2)
        receiveMessageNumber += 1
        return messageKey
    }

    public mutating func nextReceivingKey(envelope: Envelope) throws -> Data {
        guard let pub = envelope["ratchet_pubkey"]?.string, let number = envelope["message_number"]?.int else {
            throw CryptoError.badEnvelope("нет ratchet_pubkey/message_number")
        }
        return try nextReceivingKey(ratchetPubkey: try unb64(pub), messageNumber: Int(number))
    }

    // MARK: - JSON (те же имена полей, что у Android)

    public func toJSON() -> JSONValue {
        func opt(_ d: Data?) -> JSONValue { d.map { .string(b64($0)) } ?? .null }
        return .object([
            "root_key": .string(b64(rootKey)),
            "sending_chain_key": opt(sendingChainKey),
            "receiving_chain_key": opt(receivingChainKey),
            "sending_ratchet_private": .string(b64(sendingRatchetKeyPair.privateKey)),
            "sending_ratchet_public": .string(b64(sendingRatchetKeyPair.publicKey)),
            "receiving_ratchet_public": opt(receivingRatchetPublicKey),
            "send_message_number": .int(Int64(sendMessageNumber)),
            "receive_message_number": .int(Int64(receiveMessageNumber)),
            "needs_sending_ratchet": .bool(needsSendingRatchet),
            "skipped_receiving_keys": .object(Dictionary(uniqueKeysWithValues: skippedReceivingKeys.map { (String($0.key), JSONValue.string(b64($0.value))) })),
        ])
    }

    public static func fromJSON(_ json: JSONValue) throws -> RatchetState {
        func bytes(_ name: String) throws -> Data? { try json[name]?.string.map(unb64) }
        func required(_ name: String) throws -> Data {
            guard let d = try bytes(name) else { throw CryptoError.badEnvelope("в состоянии нет \(name)") }
            return d
        }
        var skipped: [Int: Data] = [:]
        for (n, k) in json["skipped_receiving_keys"]?.object ?? [:] {
            if let i = Int(n), let s = k.string { skipped[i] = try unb64(s) }
        }
        return RatchetState(
            rootKey: try required("root_key"),
            sendingRatchetKeyPair: try X25519KeyPair(privateKey: try required("sending_ratchet_private"), publicKey: try required("sending_ratchet_public")),
            sendingChainKey: try bytes("sending_chain_key"),
            receivingChainKey: try bytes("receiving_chain_key"),
            receivingRatchetPublicKey: try bytes("receiving_ratchet_public"),
            sendMessageNumber: Int(json["send_message_number"]?.int ?? 0),
            receiveMessageNumber: Int(json["receive_message_number"]?.int ?? 0),
            needsSendingRatchet: json["needs_sending_ratchet"]?.bool ?? false,
            skippedReceivingKeys: skipped
        )
    }

    public static func initAsSender(rootKey: Data, ephemeralKeyPair: X25519KeyPair) -> RatchetState {
        RatchetState(rootKey: rootKey, sendingRatchetKeyPair: ephemeralKeyPair, sendingChainKey: hkdfSha256(ikm: rootKey, info: infoInit, length: 32))
    }

    public static func initAsReceiver(rootKey: Data, remoteEphemeralPubkey: Data) -> RatchetState {
        RatchetState(
            rootKey: rootKey,
            sendingRatchetKeyPair: X25519KeyPair.generate(),
            receivingChainKey: hkdfSha256(ikm: rootKey, info: infoInit, length: 32),
            receivingRatchetPublicKey: remoteEphemeralPubkey,
            needsSendingRatchet: true
        )
    }
}
