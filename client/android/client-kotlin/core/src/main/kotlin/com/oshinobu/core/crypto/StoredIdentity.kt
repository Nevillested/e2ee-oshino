package com.oshinobu.core.crypto

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Долговременные ключи устройства в том виде, в каком их держит
 * Flutter-клиент в secure storage (client/lib/crypto/key_store.dart): плоский
 * набор строк "имя → base64", одноразовые prekey — JSON-список
 * {"public", "private"}. Kotlin-клиент хранит те же строки под теми же
 * именами — это и формат миграции при установке поверх Flutter.
 */
class StoredIdentity(
    val deviceId: String?,
    val identity: Ed25519KeyPair,
    override val identityDh: X25519KeyPair,
    val identityDhSignature: ByteArray,
    override val signedPrekey: X25519KeyPair?,
    oneTimePrekeys: List<X25519KeyPair>,
) : LocalIdentity {
    private val oneTime = oneTimePrekeys.toMutableList()

    val oneTimePrekeys: List<X25519KeyPair> get() = oneTime.toList()

    override fun findOneTimePrekey(publicKeyB64: String): X25519KeyPair? =
        oneTime.firstOrNull { b64(it.publicKey) == publicKeyB64 }

    /** Одноразовый ключ использован в DH — приватную часть больше не держим (forward secrecy). */
    fun deleteOneTimePrekey(publicKeyB64: String): Boolean =
        oneTime.removeAll { b64(it.publicKey) == publicKeyB64 }

    fun addOneTimePrekeys(keys: List<X25519KeyPair>) {
        oneTime += keys
    }

    fun toStore(): Map<String, String> = buildMap {
        deviceId?.let { put(DEVICE_ID, it) }
        put(IDENTITY_PRIVATE, b64(identity.seed))
        put(IDENTITY_PUBLIC, b64(identity.publicKey))
        put(IDENTITY_DH_PRIVATE, b64(identityDh.privateKey))
        put(IDENTITY_DH_PUBLIC, b64(identityDh.publicKey))
        put(IDENTITY_DH_SIGNATURE, b64(identityDhSignature))
        signedPrekey?.let {
            put(SIGNED_PREKEY_PRIVATE, b64(it.privateKey))
            put(SIGNED_PREKEY_PUBLIC, b64(it.publicKey))
        }
        put(
            ONE_TIME_PREKEYS,
            JsonArray(
                oneTime.map {
                    JsonObject(mapOf("public" to JsonPrimitive(b64(it.publicKey)), "private" to JsonPrimitive(b64(it.privateKey))))
                },
            ).toString(),
        )
    }

    companion object {
        const val DEVICE_ID = "device_id"
        const val IDENTITY_PRIVATE = "identity_private_key"
        const val IDENTITY_PUBLIC = "identity_public_key"
        const val IDENTITY_DH_PRIVATE = "identity_dh_private_key"
        const val IDENTITY_DH_PUBLIC = "identity_dh_public_key"
        const val IDENTITY_DH_SIGNATURE = "identity_dh_signature"
        const val SIGNED_PREKEY_PRIVATE = "signed_prekey_private_key"
        const val SIGNED_PREKEY_PUBLIC = "signed_prekey_public_key"
        const val ONE_TIME_PREKEYS = "one_time_prekeys"

        /** null — в хранилище нет identity-ключей (устройство не зарегистрировано). */
        fun fromStore(store: Map<String, String>): StoredIdentity? {
            fun bytes(name: String) = store[name]?.let { unb64(it) }
            val identity = Ed25519KeyPair(bytes(IDENTITY_PRIVATE) ?: return null, bytes(IDENTITY_PUBLIC) ?: return null)
            val identityDh = X25519KeyPair(bytes(IDENTITY_DH_PRIVATE) ?: return null, bytes(IDENTITY_DH_PUBLIC) ?: return null)
            val spkPriv = bytes(SIGNED_PREKEY_PRIVATE)
            val spkPub = bytes(SIGNED_PREKEY_PUBLIC)
            val otps = store[ONE_TIME_PREKEYS]?.let { raw ->
                Json.parseToJsonElement(raw).jsonArray.map {
                    val o = it.jsonObject
                    X25519KeyPair(unb64(o["private"]!!.jsonPrimitive.content), unb64(o["public"]!!.jsonPrimitive.content))
                }
            }.orEmpty()
            return StoredIdentity(
                deviceId = store[DEVICE_ID],
                identity = identity,
                identityDh = identityDh,
                identityDhSignature = bytes(IDENTITY_DH_SIGNATURE) ?: return null,
                signedPrekey = if (spkPriv != null && spkPub != null) X25519KeyPair(spkPriv, spkPub) else null,
                oneTimePrekeys = otps,
            )
        }

        /** Новый набор ключей устройства (регистрация). */
        fun generate(deviceId: String? = null, oneTimePrekeyCount: Int = 0): StoredIdentity {
            val identity = Ed25519KeyPair.generate()
            val identityDh = X25519KeyPair.generate()
            return StoredIdentity(
                deviceId = deviceId,
                identity = identity,
                identityDh = identityDh,
                identityDhSignature = identity.sign(identityDh.publicKey),
                signedPrekey = X25519KeyPair.generate(),
                oneTimePrekeys = List(oneTimePrekeyCount) { X25519KeyPair.generate() },
            )
        }
    }

    /** prekey-бандл в формате ответа `GET /devices/{id}/prekey-bundle` (для тестов и самопроверки). */
    fun bundle(oneTimePrekey: X25519KeyPair? = oneTime.firstOrNull()): JsonObject = JsonObject(
        buildMap {
            put("identity_pubkey", JsonPrimitive(b64(identity.publicKey)))
            put("identity_dh_pubkey", JsonPrimitive(b64(identityDh.publicKey)))
            put("identity_dh_signature", JsonPrimitive(b64(identityDhSignature)))
            put("signed_prekey", JsonPrimitive(b64(signedPrekey!!.publicKey)))
            put("signature", JsonPrimitive(b64(identity.sign(signedPrekey.publicKey))))
            oneTimePrekey?.let { put("one_time_prekey", JsonPrimitive(b64(it.publicKey))) }
        },
    )
}
