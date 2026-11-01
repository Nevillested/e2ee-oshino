#include "crypto/Primitives.h"

#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>

#include <memory>

namespace osh {

namespace {

using PKey = std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)>;
using PKeyCtx = std::unique_ptr<EVP_PKEY_CTX, decltype(&EVP_PKEY_CTX_free)>;
using MdCtx = std::unique_ptr<EVP_MD_CTX, decltype(&EVP_MD_CTX_free)>;
using CipherCtx = std::unique_ptr<EVP_CIPHER_CTX, decltype(&EVP_CIPHER_CTX_free)>;

const auto *u8(const QByteArray &b) { return reinterpret_cast<const unsigned char *>(b.constData()); }
auto *u8(QByteArray &b) { return reinterpret_cast<unsigned char *>(b.data()); }

PKey rawPrivate(int type, const QByteArray &key) {
    PKey k(EVP_PKEY_new_raw_private_key(type, nullptr, u8(key), size_t(key.size())), EVP_PKEY_free);
    if (!k) throw CryptoError("OpenSSL: приватный ключ не принят");
    return k;
}

PKey rawPublic(int type, const QByteArray &key) {
    PKey k(EVP_PKEY_new_raw_public_key(type, nullptr, u8(key), size_t(key.size())), EVP_PKEY_free);
    if (!k) throw CryptoError("OpenSSL: публичный ключ не принят");
    return k;
}

QByteArray publicOf(EVP_PKEY *key) {
    QByteArray out(32, '\0');
    size_t len = 32;
    if (EVP_PKEY_get_raw_public_key(key, u8(out), &len) != 1 || len != 32) throw CryptoError("OpenSSL: нет публичного ключа");
    return out;
}

void requireSize(const QByteArray &b, int n, const char *what) {
    if (b.size() != n) throw CryptoError(what);
}

} // namespace

QByteArray randomBytes(int n) {
    QByteArray out(n, '\0');
    if (n > 0 && RAND_bytes(u8(out), n) != 1) throw CryptoError("OpenSSL: нет случайных байтов");
    return out;
}

QString b64(const QByteArray &bytes) { return QString::fromLatin1(bytes.toBase64()); }

QByteArray unb64(const QString &s) {
    auto r = QByteArray::fromBase64Encoding(s.toLatin1(), QByteArray::AbortOnBase64DecodingErrors);
    if (!r) throw CryptoError("неверная строка base64");
    return *r;
}

bool constantTimeEquals(const QByteArray &a, const QByteArray &b) {
    return a.size() == b.size() && CRYPTO_memcmp(a.constData(), b.constData(), size_t(a.size())) == 0;
}

// ---- X25519 ----

X25519KeyPair::X25519KeyPair(QByteArray priv, QByteArray pub) : privateKey(std::move(priv)), publicKey(std::move(pub)) {
    if (privateKey.size() != 32 || publicKey.size() != 32) throw CryptoError("X25519: ключи должны быть по 32 байта");
}

QByteArray X25519KeyPair::sharedSecret(const QByteArray &remotePublic) const {
    requireSize(remotePublic, 32, "X25519: публичный ключ собеседника должен быть 32 байта");
    auto mine = rawPrivate(EVP_PKEY_X25519, privateKey);
    auto peer = rawPublic(EVP_PKEY_X25519, remotePublic);
    PKeyCtx ctx(EVP_PKEY_CTX_new(mine.get(), nullptr), EVP_PKEY_CTX_free);
    QByteArray out(32, '\0');
    size_t len = 32;
    if (!ctx || EVP_PKEY_derive_init(ctx.get()) != 1 || EVP_PKEY_derive_set_peer(ctx.get(), peer.get()) != 1) {
        throw CryptoError("OpenSSL: X25519 не инициализирован");
    }
    // OpenSSL отказывает, если общий секрет нулевой — ключ малого порядка (подмена)
    if (EVP_PKEY_derive(ctx.get(), u8(out), &len) != 1 || len != 32) {
        throw SecurityError("X25519: недопустимый публичный ключ собеседника");
    }
    return out;
}

X25519KeyPair X25519KeyPair::generate() { return fromPrivate(randomBytes(32)); }

X25519KeyPair X25519KeyPair::fromPrivate(const QByteArray &priv) {
    requireSize(priv, 32, "X25519: приватный ключ должен быть 32 байта");
    return X25519KeyPair(priv, publicOf(rawPrivate(EVP_PKEY_X25519, priv).get()));
}

// ---- Ed25519 ----

Ed25519KeyPair::Ed25519KeyPair(QByteArray s, QByteArray pub) : seed(std::move(s)), publicKey(std::move(pub)) {
    if (seed.size() != 32 || publicKey.size() != 32) throw CryptoError("Ed25519: ключи должны быть по 32 байта");
}

QByteArray Ed25519KeyPair::sign(const QByteArray &message) const {
    auto key = rawPrivate(EVP_PKEY_ED25519, seed);
    MdCtx ctx(EVP_MD_CTX_new(), EVP_MD_CTX_free);
    QByteArray sig(64, '\0');
    size_t len = 64;
    if (!ctx || EVP_DigestSignInit(ctx.get(), nullptr, nullptr, nullptr, key.get()) != 1 ||
        EVP_DigestSign(ctx.get(), u8(sig), &len, u8(message), size_t(message.size())) != 1 || len != 64) {
        throw CryptoError("OpenSSL: Ed25519 подпись не удалась");
    }
    return sig;
}

Ed25519KeyPair Ed25519KeyPair::generate() { return fromSeed(randomBytes(32)); }

Ed25519KeyPair Ed25519KeyPair::fromSeed(const QByteArray &s) {
    requireSize(s, 32, "Ed25519: seed должен быть 32 байта");
    return Ed25519KeyPair(s, publicOf(rawPrivate(EVP_PKEY_ED25519, s).get()));
}

bool Ed25519KeyPair::verify(const QByteArray &publicKey, const QByteArray &message, const QByteArray &signature) {
    if (publicKey.size() != 32 || signature.size() != 64) return false;
    PKey key(EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, nullptr, u8(publicKey), 32), EVP_PKEY_free);
    MdCtx ctx(EVP_MD_CTX_new(), EVP_MD_CTX_free);
    if (!key || !ctx || EVP_DigestVerifyInit(ctx.get(), nullptr, nullptr, nullptr, key.get()) != 1) return false;
    return EVP_DigestVerify(ctx.get(), u8(signature), 64, u8(message), size_t(message.size())) == 1;
}

// ---- HMAC / HKDF ----

QByteArray hmacSha256(const QByteArray &key, const QByteArray &data) {
    // пустой ключ по RFC 2104 эквивалентен ключу из нулей (как на Android)
    const QByteArray k = key.isEmpty() ? QByteArray(32, '\0') : key;
    QByteArray out(32, '\0');
    unsigned int len = 32;
    if (!HMAC(EVP_sha256(), k.constData(), k.size(), u8(data), size_t(data.size()), u8(out), &len) || len != 32) {
        throw CryptoError("OpenSSL: HMAC не удался");
    }
    return out;
}

QByteArray hkdfSha256(const QByteArray &ikm, const QByteArray &info, int length, const QByteArray &salt) {
    const QByteArray prk = hmacSha256(salt, ikm);
    QByteArray out;
    out.reserve(length);
    QByteArray prev;
    for (int counter = 1; out.size() < length; ++counter) {
        prev = hmacSha256(prk, prev + info + QByteArray(1, char(counter)));
        out += prev.left(length - out.size());
    }
    return out;
}

// ---- AES-256-GCM ----

namespace AesGcm {

SealedBox encrypt(const QByteArray &key, const QByteArray &plaintext, const QByteArray &aad, QByteArray nonce) {
    requireSize(key, 32, "AES-GCM: ключ должен быть 32 байта");
    if (nonce.isEmpty()) nonce = randomBytes(NonceBytes);
    requireSize(nonce, NonceBytes, "AES-GCM: nonce должен быть 12 байт");
    CipherCtx ctx(EVP_CIPHER_CTX_new(), EVP_CIPHER_CTX_free);
    QByteArray ct(plaintext.size(), '\0');
    QByteArray tag(TagBytes, '\0');
    int len = 0;
    bool ok = ctx && EVP_EncryptInit_ex(ctx.get(), EVP_aes_256_gcm(), nullptr, nullptr, nullptr) == 1 &&
              EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_SET_IVLEN, NonceBytes, nullptr) == 1 &&
              EVP_EncryptInit_ex(ctx.get(), nullptr, nullptr, u8(key), u8(nonce)) == 1;
    if (ok && !aad.isEmpty()) ok = EVP_EncryptUpdate(ctx.get(), nullptr, &len, u8(aad), aad.size()) == 1;
    if (ok && !plaintext.isEmpty()) ok = EVP_EncryptUpdate(ctx.get(), u8(ct), &len, u8(plaintext), plaintext.size()) == 1;
    unsigned char tail[16];
    ok = ok && EVP_EncryptFinal_ex(ctx.get(), tail, &len) == 1 &&
         EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_GET_TAG, TagBytes, tag.data()) == 1;
    if (!ok) throw CryptoError("OpenSSL: AES-GCM шифрование не удалось");
    return {nonce, ct, tag};
}

QByteArray decrypt(const QByteArray &key, const SealedBox &box, const QByteArray &aad) {
    requireSize(key, 32, "AES-GCM: ключ должен быть 32 байта");
    if (box.nonce.size() != NonceBytes || box.mac.size() != TagBytes) throw AuthFailedError();
    CipherCtx ctx(EVP_CIPHER_CTX_new(), EVP_CIPHER_CTX_free);
    QByteArray plain(box.ciphertext.size(), '\0');
    QByteArray tag = box.mac;
    int len = 0;
    bool ok = ctx && EVP_DecryptInit_ex(ctx.get(), EVP_aes_256_gcm(), nullptr, nullptr, nullptr) == 1 &&
              EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_SET_IVLEN, NonceBytes, nullptr) == 1 &&
              EVP_DecryptInit_ex(ctx.get(), nullptr, nullptr, u8(key), u8(box.nonce)) == 1;
    if (ok && !aad.isEmpty()) ok = EVP_DecryptUpdate(ctx.get(), nullptr, &len, u8(aad), aad.size()) == 1;
    if (ok && !box.ciphertext.isEmpty()) {
        ok = EVP_DecryptUpdate(ctx.get(), u8(plain), &len, u8(box.ciphertext), box.ciphertext.size()) == 1;
    }
    ok = ok && EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_SET_TAG, TagBytes, tag.data()) == 1;
    unsigned char tail[16];
    if (!ok || EVP_DecryptFinal_ex(ctx.get(), tail, &len) != 1) throw AuthFailedError();
    return plain;
}

} // namespace AesGcm

} // namespace osh
