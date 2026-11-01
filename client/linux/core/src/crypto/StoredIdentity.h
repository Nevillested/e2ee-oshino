#pragma once

// Долговременные ключи устройства (как StoredIdentity.kt): плоский набор
// строк "имя → base64", одноразовые prekey — JSON-список {"public", "private"}.
// Имена совпадают с Android — формат хранения устройства.

#include "crypto/X3dh.h"

#include <QJsonObject>
#include <QMap>
#include <optional>
#include <vector>

namespace osh {

class StoredIdentity : public LocalIdentity {
public:
    static constexpr const char *DeviceId = "device_id";
    static constexpr const char *IdentityPrivate = "identity_private_key";
    static constexpr const char *IdentityPublic = "identity_public_key";
    static constexpr const char *IdentityDhPrivate = "identity_dh_private_key";
    static constexpr const char *IdentityDhPublic = "identity_dh_public_key";
    static constexpr const char *IdentityDhSignature = "identity_dh_signature";
    static constexpr const char *SignedPrekeyPrivate = "signed_prekey_private_key";
    static constexpr const char *SignedPrekeyPublic = "signed_prekey_public_key";
    static constexpr const char *OneTimePrekeys = "one_time_prekeys";

    StoredIdentity(std::optional<QString> deviceId, Ed25519KeyPair identity, X25519KeyPair identityDh, QByteArray identityDhSignature,
                   std::optional<X25519KeyPair> signedPrekey, std::vector<X25519KeyPair> oneTimePrekeys);

    std::optional<QString> deviceId;
    Ed25519KeyPair identity;
    QByteArray identityDhSignature;

    const X25519KeyPair &identityDh() const override { return identityDh_; }
    const std::optional<X25519KeyPair> &signedPrekey() const override { return signedPrekey_; }
    std::optional<X25519KeyPair> findOneTimePrekey(const QString &publicKeyB64) const override;

    const std::vector<X25519KeyPair> &oneTimePrekeys() const { return oneTime_; }
    /// Одноразовый ключ использован в DH — приватную часть больше не держим (forward secrecy).
    bool deleteOneTimePrekey(const QString &publicKeyB64);
    void addOneTimePrekeys(const std::vector<X25519KeyPair> &keys);

    QMap<QString, QString> toStore() const;
    /// nullopt — в хранилище нет identity-ключей (устройство не зарегистрировано).
    static std::optional<StoredIdentity> fromStore(const QMap<QString, QString> &store);
    /// Новый набор ключей устройства (регистрация).
    static StoredIdentity generate(std::optional<QString> deviceId = std::nullopt, int oneTimePrekeyCount = 0);

    /// prekey-бандл в формате ответа `GET /devices/{id}/prekey-bundle` (для тестов и самопроверки).
    QJsonObject bundle() const;
    QJsonObject bundle(const std::optional<X25519KeyPair> &oneTimePrekey) const;

private:
    X25519KeyPair identityDh_;
    std::optional<X25519KeyPair> signedPrekey_;
    std::vector<X25519KeyPair> oneTime_;
};

} // namespace osh
