#pragma once

// Криптографические примитивы: X25519, Ed25519, HMAC-SHA256, HKDF,
// AES-256-GCM с 12-байтным nonce и 16-байтным тегом (как Primitives.kt на
// Android). Формат ключей и результатов зафиксирован — его сторожат
// векторы ProtocolVectorsTest. Реализация — OpenSSL 3.

#include <QByteArray>
#include <QString>
#include <stdexcept>

namespace osh {

/// Ошибка криптографии (неверные данные, ключ не того размера).
struct CryptoError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

/// Подмена: ключ малого порядка, неверная подпись.
struct SecurityError : CryptoError {
    using CryptoError::CryptoError;
};

/// AES-GCM: ключ, nonce или AAD не те, либо данные подменены.
struct AuthFailedError : CryptoError {
    AuthFailedError() : CryptoError("AES-GCM: тег не сходится") {}
};

QByteArray randomBytes(int n);

/// Стандартный base64 с дополнением — как java.util.Base64 на Android.
QString b64(const QByteArray &bytes);
/// Строгая расшифровка base64; неверная строка — CryptoError.
QByteArray unb64(const QString &s);

bool constantTimeEquals(const QByteArray &a, const QByteArray &b);

/// Пара X25519. privateKey — 32 байта как есть (клампинг делает OpenSSL при умножении).
struct X25519KeyPair {
    QByteArray privateKey;
    QByteArray publicKey;

    X25519KeyPair(QByteArray privateKey, QByteArray publicKey);

    /// Общий секрет; ключ малого порядка (нулевой секрет) — SecurityError.
    QByteArray sharedSecret(const QByteArray &remotePublic) const;

    static X25519KeyPair generate();
    static X25519KeyPair fromPrivate(const QByteArray &privateKey);
};

/// Пара Ed25519. seed — 32-байтный приватный seed (RFC 8032).
struct Ed25519KeyPair {
    QByteArray seed;
    QByteArray publicKey;

    Ed25519KeyPair(QByteArray seed, QByteArray publicKey);

    QByteArray sign(const QByteArray &message) const;

    static Ed25519KeyPair generate();
    static Ed25519KeyPair fromSeed(const QByteArray &seed);
    static bool verify(const QByteArray &publicKey, const QByteArray &message, const QByteArray &signature);
};

QByteArray hmacSha256(const QByteArray &key, const QByteArray &data);

/// HKDF-SHA256 (RFC 5869), по умолчанию с пустой солью.
QByteArray hkdfSha256(const QByteArray &ikm, const QByteArray &info, int length, const QByteArray &salt = {});

/// Результат AES-GCM: шифротекст и тег отдельно.
struct SealedBox {
    QByteArray nonce;
    QByteArray ciphertext;
    QByteArray mac;
};

namespace AesGcm {
constexpr int NonceBytes = 12;
constexpr int TagBytes = 16;

/// nonce не задан — случайный.
SealedBox encrypt(const QByteArray &key, const QByteArray &plaintext, const QByteArray &aad = {}, QByteArray nonce = {});
/// AuthFailedError, если ключ/nonce/AAD не те или данные подменены.
QByteArray decrypt(const QByteArray &key, const SealedBox &box, const QByteArray &aad = {});
} // namespace AesGcm

} // namespace osh
