package com.oshinobu.core.crypto

import org.bouncycastle.math.ec.rfc7748.X25519
import org.bouncycastle.math.ec.rfc8032.Ed25519
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

// Криптографические примитивы — байт-в-байт те же, что даёт Dart-пакет
// `cryptography` во Flutter-клиенте (X25519, Ed25519, HMAC-SHA256, HKDF,
// AES-256-GCM с 12-байтным nonce и 16-байтным тегом). Совместимость
// проверяется векторами из настоящего Dart-кода, см. DartInteropTest.

internal val secureRandom = SecureRandom()

fun randomBytes(n: Int): ByteArray = ByteArray(n).also { secureRandom.nextBytes(it) }

fun b64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

fun unb64(s: String): ByteArray = Base64.getDecoder().decode(s)

fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean = MessageDigest.isEqual(a, b)

/**
 * Пара X25519. [privateKey] — 32 байта в том виде, в каком их хранит
 * Dart-клиент (`extractPrivateKeyBytes`); клампинг скаляра BouncyCastle
 * делает сам при каждом умножении, поэтому неклампленный и клампленный
 * вариант дают один и тот же результат.
 */
class X25519KeyPair(val privateKey: ByteArray, val publicKey: ByteArray) {
    init {
        require(privateKey.size == 32 && publicKey.size == 32) { "X25519: ключи должны быть по 32 байта" }
    }

    fun sharedSecret(remotePublic: ByteArray): ByteArray {
        require(remotePublic.size == 32) { "X25519: публичный ключ собеседника должен быть 32 байта" }
        val out = ByteArray(32)
        if (!X25519.calculateAgreement(privateKey, 0, remotePublic, 0, out, 0)) {
            // нулевой общий секрет — публичный ключ малого порядка (подмена)
            throw SecurityException("X25519: недопустимый публичный ключ собеседника")
        }
        return out
    }

    companion object {
        fun generate(): X25519KeyPair = fromPrivate(randomBytes(32))

        fun fromPrivate(privateKey: ByteArray): X25519KeyPair {
            val pub = ByteArray(32)
            X25519.generatePublicKey(privateKey, 0, pub, 0)
            return X25519KeyPair(privateKey.copyOf(), pub)
        }
    }
}

/** Пара Ed25519. [seed] — 32-байтный приватный seed (формат Dart-клиента). */
class Ed25519KeyPair(val seed: ByteArray, val publicKey: ByteArray) {
    init {
        require(seed.size == 32 && publicKey.size == 32) { "Ed25519: ключи должны быть по 32 байта" }
    }

    fun sign(message: ByteArray): ByteArray {
        val sig = ByteArray(Ed25519.SIGNATURE_SIZE)
        Ed25519.sign(seed, 0, publicKey, 0, message, 0, message.size, sig, 0)
        return sig
    }

    companion object {
        fun generate(): Ed25519KeyPair = fromSeed(randomBytes(32))

        fun fromSeed(seed: ByteArray): Ed25519KeyPair {
            val pub = ByteArray(Ed25519.PUBLIC_KEY_SIZE)
            Ed25519.generatePublicKey(seed, 0, pub, 0)
            return Ed25519KeyPair(seed.copyOf(), pub)
        }

        fun verify(publicKey: ByteArray, message: ByteArray, signature: ByteArray): Boolean {
            if (publicKey.size != Ed25519.PUBLIC_KEY_SIZE || signature.size != Ed25519.SIGNATURE_SIZE) return false
            return try {
                Ed25519.verify(signature, 0, publicKey, 0, message, 0, message.size)
            } catch (_: Exception) {
                false
            }
        }
    }
}

fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
    val mac = Mac.getInstance("HmacSHA256")
    // пустой ключ javax не принимает; по RFC 2104 он эквивалентен ключу из нулей
    mac.init(SecretKeySpec(if (key.isEmpty()) ByteArray(32) else key, "HmacSHA256"))
    return mac.doFinal(data)
}

/** HKDF-SHA256 (RFC 5869) с пустой солью — так её вызывает Dart-клиент (`nonce: []`). */
fun hkdfSha256(ikm: ByteArray, info: ByteArray, length: Int, salt: ByteArray = ByteArray(0)): ByteArray {
    val prk = hmacSha256(salt, ikm)
    val out = ByteArray(length)
    var prev = ByteArray(0)
    var pos = 0
    var counter = 1
    while (pos < length) {
        prev = hmacSha256(prk, prev + info + byteArrayOf(counter.toByte()))
        val n = minOf(prev.size, length - pos)
        System.arraycopy(prev, 0, out, pos, n)
        pos += n
        counter++
    }
    return out
}

/** Результат AES-GCM в раскладке Dart-клиента: шифротекст и тег отдельно. */
class SealedBox(val nonce: ByteArray, val ciphertext: ByteArray, val mac: ByteArray)

object AesGcm {
    const val NONCE_BYTES = 12
    const val TAG_BYTES = 16

    fun encrypt(key: ByteArray, plaintext: ByteArray, aad: ByteArray? = null, nonce: ByteArray = randomBytes(NONCE_BYTES)): SealedBox {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BYTES * 8, nonce))
        if (aad != null) cipher.updateAAD(aad)
        val sealed = cipher.doFinal(plaintext)
        return SealedBox(
            nonce,
            sealed.copyOfRange(0, sealed.size - TAG_BYTES),
            sealed.copyOfRange(sealed.size - TAG_BYTES, sealed.size),
        )
    }

    /** Бросает [AEADBadTagException], если ключ/nonce/AAD не те или данные подменены. */
    fun decrypt(key: ByteArray, box: SealedBox, aad: ByteArray? = null): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BYTES * 8, box.nonce))
        if (aad != null) cipher.updateAAD(aad)
        return cipher.doFinal(box.ciphertext + box.mac)
    }
}
