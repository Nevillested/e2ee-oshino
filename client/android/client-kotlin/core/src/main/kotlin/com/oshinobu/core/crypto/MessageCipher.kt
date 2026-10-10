package com.oshinobu.core.crypto

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

// Шифрование тела конверта (порт client/lib/crypto/message_cipher.dart).
//
// Заголовочные поля конверта (какой ключ ratchet, номер сообщения, чей это
// X3DH) лежат рядом с шифротекстом открыто, но связаны с ним через AAD
// AES-GCM: подмена любого из них ломает MAC. Строка AAD должна совпадать с
// Dart-клиентом посимвольно: "name=value" через "|", в фиксированном
// порядке; отсутствующее поле и null дают одинаковое "null", число — без
// кавычек и дробной части.

private val aadFieldNames = listOf(
    "sender_device_id",
    "ratchet_pubkey",
    "message_number",
    "ephemeral_pubkey",
    "sender_identity_dh_pubkey",
    "used_one_time_prekey",
)

private fun aadValue(element: JsonElement?): String = when (element) {
    null, JsonNull -> "null"
    is JsonPrimitive -> element.contentOrNull ?: "null"
    else -> element.toString()
}

fun buildAad(fields: Map<String, JsonElement?>): ByteArray =
    aadFieldNames.joinToString("|") { "$it=${aadValue(fields[it])}" }.toByteArray(Charsets.UTF_8)

/** Возвращает поля nonce/ciphertext/mac (base64) — их кладут в конверт рядом с [aad]. */
fun encryptMessage(messageKey: ByteArray, plaintext: String, aad: Map<String, JsonElement?>): Map<String, JsonPrimitive> {
    val box = AesGcm.encrypt(messageKey, plaintext.toByteArray(Charsets.UTF_8), buildAad(aad))
    return mapOf(
        "nonce" to JsonPrimitive(b64(box.nonce)),
        "ciphertext" to JsonPrimitive(b64(box.ciphertext)),
        "mac" to JsonPrimitive(b64(box.mac)),
    )
}

/** AAD собирается из того же [envelope] — лишние поля игнорируются. */
fun decryptMessage(messageKey: ByteArray, envelope: JsonObject): String {
    fun field(name: String) = envelope[name]?.jsonPrimitive?.content
        ?: throw IllegalArgumentException("в конверте нет поля $name")
    val box = SealedBox(unb64(field("nonce")), unb64(field("ciphertext")), unb64(field("mac")))
    return AesGcm.decrypt(messageKey, box, buildAad(envelope)).toString(Charsets.UTF_8)
}
