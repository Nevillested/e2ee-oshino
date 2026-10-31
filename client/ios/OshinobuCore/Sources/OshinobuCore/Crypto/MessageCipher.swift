import Foundation

// Шифрование тела конверта (как core/crypto/MessageCipher.kt).
//
// Заголовочные поля лежат рядом с шифротекстом открыто, но связаны с ним через
// AAD AES-GCM. Строка AAD — зафиксированный формат, посимвольно: "name=value"
// через "|", в фиксированном порядке; отсутствующее поле и null дают "null",
// число — без кавычек и дробной части.

/// Конверт на проводе: JSON-объект с полями заголовка и nonce/ciphertext/mac.
public typealias Envelope = [String: JSONValue]

private let aadFieldNames = [
    "sender_device_id",
    "ratchet_pubkey",
    "message_number",
    "ephemeral_pubkey",
    "sender_identity_dh_pubkey",
    "used_one_time_prekey",
]

public func buildAad(_ fields: Envelope) -> Data {
    let text = aadFieldNames.map { name in "\(name)=\(fields[name]?.primitiveContent ?? "null")" }.joined(separator: "|")
    return Data(text.utf8)
}

/// Поля nonce/ciphertext/mac (base64) — их кладут в конверт рядом с полями [aad].
public func encryptMessage(messageKey: Data, plaintext: String, aad: Envelope) throws -> Envelope {
    let box = try AesGcm.encrypt(key: messageKey, plaintext: Data(plaintext.utf8), aad: buildAad(aad))
    return [
        "nonce": .string(b64(box.nonce)),
        "ciphertext": .string(b64(box.ciphertext)),
        "mac": .string(b64(box.mac)),
    ]
}

/// AAD собирается из того же [envelope] — лишние поля игнорируются.
public func decryptMessage(messageKey: Data, envelope: Envelope) throws -> String {
    func field(_ name: String) throws -> Data {
        guard let s = envelope[name]?.string else { throw CryptoError.badEnvelope("в конверте нет поля \(name)") }
        return try unb64(s)
    }
    let box = SealedBox(nonce: try field("nonce"), ciphertext: try field("ciphertext"), mac: try field("mac"))
    let plain = try AesGcm.decrypt(key: messageKey, box: box, aad: buildAad(envelope))
    return String(decoding: plain, as: UTF8.self)
}
