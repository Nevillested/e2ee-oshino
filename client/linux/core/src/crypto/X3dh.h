#pragma once

// X3DH — установка сессии по бандлу prekey собеседника (как X3dh.kt).
//
// Identity-ключ устройства — Ed25519 (подписи); для самого DH используется
// ОТДЕЛЬНЫЙ X25519-ключ "identity_dh", подписанный identity-ключом.
// IKM = 32×0xFF || DH1 || DH2 || DH3 [|| DH4], root = HKDF(IKM, "OshinobuX3DHRoot").

#include "crypto/Primitives.h"

#include <QJsonObject>
#include <optional>

namespace osh {

struct X3dhSignatureError : SecurityError {
    X3dhSignatureError() : SecurityError("Подпись ключей собеседника недействительна — возможна подмена") {}
};

/// Свои долговременные ключи, нужные для X3DH.
class LocalIdentity {
public:
    virtual ~LocalIdentity() = default;
    virtual const X25519KeyPair &identityDh() const = 0;
    virtual const std::optional<X25519KeyPair> &signedPrekey() const = 0;
    /// Приватная часть одноразового prekey по его публичной части (base64), если он ещё есть.
    virtual std::optional<X25519KeyPair> findOneTimePrekey(const QString &publicKeyB64) const = 0;
};

struct X3dhOutgoing {
    QByteArray rootKey;
    X25519KeyPair ephemeralKeyPair;
    /// Поля, которые уходят в первом конверте новой сессии (и входят в AAD).
    QJsonObject initHeader;
};

/**
 * Сторона-инициатор. [bundle] — ответ `GET /devices/{id}/prekey-bundle`:
 * identity_pubkey, identity_dh_pubkey, identity_dh_signature, signed_prekey,
 * signature, one_time_prekey (может отсутствовать — тогда 3-DH).
 */
X3dhOutgoing establishOutgoingRoot(const QJsonObject &bundle, const QString &myDeviceId, const X25519KeyPair &myIdentityDh);

struct X3dhIncoming {
    QByteArray rootKey;
    /// Использованный одноразовый prekey (base64) — его приватную часть пора удалить.
    std::optional<QString> consumedOneTimePrekey;
    /// Собеседник заявил одноразовый ключ, которого у нас уже нет — сессия на 3-DH.
    bool missingOneTimePrekey = false;
};

/// Сторона-получатель первого сообщения. nullopt — в конверте нет X3DH-полей или нет signed prekey.
std::optional<X3dhIncoming> establishIncomingRoot(const QJsonObject &envelope, const LocalIdentity &me);

} // namespace osh
