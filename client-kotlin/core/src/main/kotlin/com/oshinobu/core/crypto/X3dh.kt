package com.oshinobu.core.crypto

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive

// X3DH — порт client/lib/crypto/x3dh.dart.
//
// Identity-ключ устройства — Ed25519 (подписи); для самого DH используется
// ОТДЕЛЬНЫЙ X25519-ключ "identity_dh", подписанный identity-ключом
// (Ed25519 для DH не годится — сознательное решение, не недоделка).
// IKM = 32×0xFF || DH1 || DH2 || DH3 [|| DH4], root = HKDF(IKM, "OshinobuX3DHRoot").

private val INFO_ROOT = "OshinobuX3DHRoot".toByteArray()

class X3dhSignatureException : SecurityException("Подпись ключей собеседника недействительна — возможна подмена")

/** Свои долговременные ключи, нужные для X3DH. */
interface LocalIdentity {
    val identityDh: X25519KeyPair
    val signedPrekey: X25519KeyPair?

    /** Приватная часть одноразового prekey по его публичной части (base64), если он ещё есть. */
    fun findOneTimePrekey(publicKeyB64: String): X25519KeyPair?
}

class X3dhOutgoing(
    val rootKey: ByteArray,
    val ephemeralKeyPair: X25519KeyPair,
    /** Поля, которые уходят в первом конверте новой сессии (и входят в AAD). */
    val initHeader: Map<String, JsonElement>,
)

private fun deriveRootKey(ikm: ByteArray) = hkdfSha256(ikm, INFO_ROOT, 32)

private fun ffPrefix() = ByteArray(32) { 0xFF.toByte() }

/**
 * Сторона-инициатор. [bundle] — ответ `GET /devices/{id}/prekey-bundle`:
 * identity_pubkey, identity_dh_pubkey, identity_dh_signature, signed_prekey,
 * signature, one_time_prekey (может отсутствовать — тогда 3-DH).
 */
fun establishOutgoingRoot(bundle: JsonObject, myDeviceId: String, myIdentityDh: X25519KeyPair): X3dhOutgoing {
    fun field(name: String) = unb64(bundle[name]!!.jsonPrimitive.content)
    val remoteIdentity = field("identity_pubkey")
    val remoteIdentityDh = field("identity_dh_pubkey")
    val remoteSignedPrekey = field("signed_prekey")
    val oneTimeB64 = bundle["one_time_prekey"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content

    val signedPrekeyValid = Ed25519KeyPair.verify(remoteIdentity, remoteSignedPrekey, field("signature"))
    val identityDhValid = Ed25519KeyPair.verify(remoteIdentity, remoteIdentityDh, field("identity_dh_signature"))
    if (!signedPrekeyValid || !identityDhValid) throw X3dhSignatureException()

    val ephemeral = X25519KeyPair.generate()
    var ikm = ffPrefix() +
        myIdentityDh.sharedSecret(remoteSignedPrekey) +
        ephemeral.sharedSecret(remoteIdentityDh) +
        ephemeral.sharedSecret(remoteSignedPrekey)
    if (oneTimeB64 != null) ikm += ephemeral.sharedSecret(unb64(oneTimeB64))

    return X3dhOutgoing(
        rootKey = deriveRootKey(ikm),
        ephemeralKeyPair = ephemeral,
        initHeader = mapOf(
            "sender_device_id" to JsonPrimitive(myDeviceId),
            "sender_identity_dh_pubkey" to JsonPrimitive(b64(myIdentityDh.publicKey)),
            "ephemeral_pubkey" to JsonPrimitive(b64(ephemeral.publicKey)),
            "used_one_time_prekey" to (oneTimeB64?.let { JsonPrimitive(it) } ?: JsonNull),
        ),
    )
}

class X3dhIncoming(
    val rootKey: ByteArray,
    /** Использованный одноразовый prekey (base64) — его приватную часть пора удалить с диска. */
    val consumedOneTimePrekey: String?,
    /** Собеседник заявил одноразовый ключ, которого у нас уже нет — сессия на 3-DH. */
    val missingOneTimePrekey: Boolean,
)

/**
 * Сторона-получатель первого сообщения. null — в конверте нет X3DH-полей
 * или у нас нет signed prekey (устройство не до конца настроено).
 */
fun establishIncomingRoot(envelope: JsonObject, me: LocalIdentity): X3dhIncoming? {
    fun str(name: String) = envelope[name]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content
    val senderIdentityDh = str("sender_identity_dh_pubkey")?.let { unb64(it) } ?: return null
    val senderEphemeral = str("ephemeral_pubkey")?.let { unb64(it) } ?: return null
    val signedPrekey = me.signedPrekey ?: return null

    var ikm = ffPrefix() +
        signedPrekey.sharedSecret(senderIdentityDh) +
        me.identityDh.sharedSecret(senderEphemeral) +
        signedPrekey.sharedSecret(senderEphemeral)

    val usedOneTime = str("used_one_time_prekey")
    var consumed: String? = null
    var missing = false
    if (usedOneTime != null) {
        val otp = me.findOneTimePrekey(usedOneTime)
        if (otp != null) {
            ikm += otp.sharedSecret(senderEphemeral)
            consumed = usedOneTime
        } else {
            missing = true
        }
    }
    return X3dhIncoming(deriveRootKey(ikm), consumed, missing)
}
