package com.oshinobu.core.crypto

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

// Double Ratchet — порт client/lib/crypto/double_ratchet.dart один в один:
// те же info-строки HKDF, те же маркеры HMAC цепочки, тот же JSON состояния
// (Kotlin-клиент при установке поверх Flutter читает уже сохранённые им
// сессии, а Flutter-собеседник должен расшифровывать то, что шлёт Kotlin).

private const val MAX_SKIPPED_KEYS = 100 // защита от чрезмерного расхода памяти/диска
private val INFO_INIT = "oshinobu-init".toByteArray()
private val INFO_RATCHET = "oshinobu-ratchet".toByteArray()

private fun chainStep(key: ByteArray, marker: Int) = hmacSha256(key, byteArrayOf(marker.toByte()))

/**
 * Сообщение с этим номером уже было честно расшифровано раньше — повторная
 * доставка, а не рассинхрон. Вызывающему коду нужно отличать это от
 * настоящей ошибки, иначе всплеск дублей после реконнекта сносит рабочую
 * сессию.
 */
class AlreadyProcessedException(val messageNumber: Int) :
    Exception("Сообщение с номером $messageNumber уже было обработано ранее")

class RatchetGapTooLargeException(message: String) : Exception(message)

/** Заголовок исходящего сообщения + ключ, которым его шифровать. */
class SendingKey(val ratchetPubkey: ByteArray, val messageNumber: Int, val messageKey: ByteArray) {
    val header: Map<String, JsonElement>
        get() = mapOf(
            "ratchet_pubkey" to JsonPrimitive(b64(ratchetPubkey)),
            "message_number" to JsonPrimitive(messageNumber),
        )
}

/**
 * Всё состояние сессии с одним устройством собеседника.
 *
 * ВАЖНОЕ ПРАВИЛО: сохранять состояние на диск можно ТОЛЬКО после успешной
 * расшифровки сообщения этим ключом. Сохранишь раньше, а расшифровка упадёт —
 * состояние навсегда "убежит вперёд".
 */
class RatchetState(
    var rootKey: ByteArray,
    var sendingRatchetKeyPair: X25519KeyPair,
    var sendingChainKey: ByteArray? = null,
    var receivingChainKey: ByteArray? = null,
    var receivingRatchetPublicKey: ByteArray? = null,
    var sendMessageNumber: Int = 0,
    var receiveMessageNumber: Int = 0,
    var needsSendingRatchet: Boolean = false,
    /** Ключи "перескоченных" сообщений текущей эпохи — вдруг они придут с опозданием. */
    var skippedReceivingKeys: MutableMap<Int, ByteArray> = mutableMapOf(),
) {
    private fun dhRatchetStepForSending() {
        val newKeyPair = X25519KeyPair.generate()
        val shared = newKeyPair.sharedSecret(receivingRatchetPublicKey!!)
        val derived = hkdfSha256(rootKey + shared, INFO_RATCHET, 64)
        rootKey = derived.copyOfRange(0, 32)
        sendingChainKey = derived.copyOfRange(32, 64)
        sendingRatchetKeyPair = newKeyPair
        sendMessageNumber = 0
        needsSendingRatchet = false
    }

    private fun dhRatchetStepForReceiving(newRemotePubkey: ByteArray) {
        val shared = sendingRatchetKeyPair.sharedSecret(newRemotePubkey)
        val derived = hkdfSha256(rootKey + shared, INFO_RATCHET, 64)
        rootKey = derived.copyOfRange(0, 32)
        receivingChainKey = derived.copyOfRange(32, 64)
        receivingRatchetPublicKey = newRemotePubkey
        receiveMessageNumber = 0
        needsSendingRatchet = true
        // ключи прошлой эпохи относились к другой цепочке — больше не нужны
        skippedReceivingKeys = mutableMapOf()
    }

    fun nextSendingKey(): SendingKey {
        if (needsSendingRatchet) dhRatchetStepForSending()
        val chain = sendingChainKey!!
        val messageKey = chainStep(chain, 1)
        sendingChainKey = chainStep(chain, 2)
        val key = SendingKey(sendingRatchetKeyPair.publicKey, sendMessageNumber, messageKey)
        sendMessageNumber++
        return key
    }

    /** Ключ для конкретного входящего сообщения по полям его заголовка. */
    fun nextReceivingKey(ratchetPubkey: ByteArray, messageNumber: Int): ByteArray {
        val current = receivingRatchetPublicKey
        if (current == null || !constantTimeEquals(current, ratchetPubkey)) {
            dhRatchetStepForReceiving(ratchetPubkey)
        }

        skippedReceivingKeys.remove(messageNumber)?.let { return it }

        if (messageNumber < receiveMessageNumber) {
            // ключ уже израсходован, но сама сессия здорова — это дубль
            throw AlreadyProcessedException(messageNumber)
        }
        if (messageNumber - receiveMessageNumber > MAX_SKIPPED_KEYS) {
            throw RatchetGapTooLargeException(
                "Слишком большой разрыв в номерах сообщений ($receiveMessageNumber → $messageNumber) — отказ от обработки",
            )
        }

        while (receiveMessageNumber < messageNumber) {
            val chain = receivingChainKey!!
            skippedReceivingKeys[receiveMessageNumber] = chainStep(chain, 1)
            receivingChainKey = chainStep(chain, 2)
            receiveMessageNumber++
        }

        val chain = receivingChainKey!!
        val messageKey = chainStep(chain, 1)
        receivingChainKey = chainStep(chain, 2)
        receiveMessageNumber++
        return messageKey
    }

    fun nextReceivingKey(envelope: JsonObject): ByteArray = nextReceivingKey(
        unb64(envelope["ratchet_pubkey"]!!.jsonPrimitive.content),
        envelope["message_number"]!!.jsonPrimitive.int,
    )

    /** Тот же JSON, что пишет Dart-клиент (`RatchetState.toJson`). */
    fun toJson(): JsonObject = buildJsonObject {
        put("root_key", b64(rootKey))
        put("sending_chain_key", sendingChainKey?.let { b64(it) })
        put("receiving_chain_key", receivingChainKey?.let { b64(it) })
        put("sending_ratchet_private", b64(sendingRatchetKeyPair.privateKey))
        put("sending_ratchet_public", b64(sendingRatchetKeyPair.publicKey))
        put("receiving_ratchet_public", receivingRatchetPublicKey?.let { b64(it) })
        put("send_message_number", sendMessageNumber)
        put("receive_message_number", receiveMessageNumber)
        put("needs_sending_ratchet", needsSendingRatchet)
        put(
            "skipped_receiving_keys",
            JsonObject(skippedReceivingKeys.entries.associate { (n, k) -> n.toString() to JsonPrimitive(b64(k)) }),
        )
    }

    companion object {
        fun initAsSender(rootKey: ByteArray, ephemeralKeyPair: X25519KeyPair) = RatchetState(
            rootKey = rootKey,
            sendingRatchetKeyPair = ephemeralKeyPair,
            sendingChainKey = hkdfSha256(rootKey, INFO_INIT, 32),
        )

        fun initAsReceiver(rootKey: ByteArray, remoteEphemeralPubkey: ByteArray) = RatchetState(
            rootKey = rootKey,
            sendingRatchetKeyPair = X25519KeyPair.generate(),
            receivingChainKey = hkdfSha256(rootKey, INFO_INIT, 32),
            receivingRatchetPublicKey = remoteEphemeralPubkey,
            needsSendingRatchet = true,
        )

        fun fromJson(json: JsonObject): RatchetState {
            fun str(name: String): String? = json[name]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content
            fun bytes(name: String): ByteArray? = str(name)?.let { unb64(it) }
            val skipped = (json["skipped_receiving_keys"] as? JsonObject).orEmpty()
                .entries.associate { (n, k) -> n.toInt() to unb64(k.jsonPrimitive.content) }
                .toMutableMap()
            return RatchetState(
                rootKey = bytes("root_key")!!,
                // публичная часть хранится рядом — берём её, а не пересчитываем,
                // ровно как Dart (SimpleKeyPairData с явным publicKey)
                sendingRatchetKeyPair = X25519KeyPair(bytes("sending_ratchet_private")!!, bytes("sending_ratchet_public")!!),
                sendingChainKey = bytes("sending_chain_key"),
                receivingChainKey = bytes("receiving_chain_key"),
                receivingRatchetPublicKey = bytes("receiving_ratchet_public"),
                sendMessageNumber = json["send_message_number"]!!.jsonPrimitive.int,
                receiveMessageNumber = json["receive_message_number"]!!.jsonPrimitive.int,
                needsSendingRatchet = json["needs_sending_ratchet"]!!.jsonPrimitive.boolean,
                skippedReceivingKeys = skipped,
            )
        }
    }
}
