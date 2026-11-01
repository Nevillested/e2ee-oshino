#include "crypto/StoredIdentity.h"

#include "support/Json.h"

#include <algorithm>

namespace osh {

StoredIdentity::StoredIdentity(std::optional<QString> id, Ed25519KeyPair ident, X25519KeyPair dh, QByteArray dhSignature,
                               std::optional<X25519KeyPair> spk, std::vector<X25519KeyPair> otps)
    : deviceId(std::move(id)), identity(std::move(ident)), identityDhSignature(std::move(dhSignature)), identityDh_(std::move(dh)),
      signedPrekey_(std::move(spk)), oneTime_(std::move(otps)) {}

std::optional<X25519KeyPair> StoredIdentity::findOneTimePrekey(const QString &publicKeyB64) const {
    for (const auto &k : oneTime_) {
        if (b64(k.publicKey) == publicKeyB64) return k;
    }
    return std::nullopt;
}

bool StoredIdentity::deleteOneTimePrekey(const QString &publicKeyB64) {
    const auto before = oneTime_.size();
    oneTime_.erase(std::remove_if(oneTime_.begin(), oneTime_.end(), [&](const X25519KeyPair &k) { return b64(k.publicKey) == publicKeyB64; }),
                   oneTime_.end());
    return oneTime_.size() != before;
}

void StoredIdentity::addOneTimePrekeys(const std::vector<X25519KeyPair> &keys) { oneTime_.insert(oneTime_.end(), keys.begin(), keys.end()); }

QMap<QString, QString> StoredIdentity::toStore() const {
    QMap<QString, QString> m;
    if (deviceId) m[DeviceId] = *deviceId;
    m[IdentityPrivate] = b64(identity.seed);
    m[IdentityPublic] = b64(identity.publicKey);
    m[IdentityDhPrivate] = b64(identityDh_.privateKey);
    m[IdentityDhPublic] = b64(identityDh_.publicKey);
    m[IdentityDhSignature] = b64(identityDhSignature);
    if (signedPrekey_) {
        m[SignedPrekeyPrivate] = b64(signedPrekey_->privateKey);
        m[SignedPrekeyPublic] = b64(signedPrekey_->publicKey);
    }
    QJsonArray otps;
    for (const auto &k : oneTime_) otps.append(QJsonObject{{"public", b64(k.publicKey)}, {"private", b64(k.privateKey)}});
    m[OneTimePrekeys] = json::compact(otps);
    return m;
}

std::optional<StoredIdentity> StoredIdentity::fromStore(const QMap<QString, QString> &store) {
    auto bytes = [&](const char *name) -> std::optional<QByteArray> {
        const auto it = store.find(name);
        return it == store.end() ? std::nullopt : std::optional(unb64(*it));
    };
    const auto idPriv = bytes(IdentityPrivate), idPub = bytes(IdentityPublic);
    const auto dhPriv = bytes(IdentityDhPrivate), dhPub = bytes(IdentityDhPublic);
    const auto dhSig = bytes(IdentityDhSignature);
    if (!idPriv || !idPub || !dhPriv || !dhPub || !dhSig) return std::nullopt;

    const auto spkPriv = bytes(SignedPrekeyPrivate), spkPub = bytes(SignedPrekeyPublic);
    std::vector<X25519KeyPair> otps;
    if (const auto it = store.find(OneTimePrekeys); it != store.end()) {
        const QJsonArray arr = QJsonDocument::fromJson(it->toUtf8()).array();
        for (const QJsonValue &v : arr) {
            const QJsonObject o = v.toObject();
            otps.emplace_back(unb64(json::string(o, "private")), unb64(json::string(o, "public")));
        }
    }
    const auto id = store.find(DeviceId);
    return StoredIdentity(id == store.end() ? std::nullopt : std::optional(*id), Ed25519KeyPair(*idPriv, *idPub), X25519KeyPair(*dhPriv, *dhPub),
                          *dhSig, spkPriv && spkPub ? std::optional(X25519KeyPair(*spkPriv, *spkPub)) : std::nullopt, std::move(otps));
}

StoredIdentity StoredIdentity::generate(std::optional<QString> deviceId, int oneTimePrekeyCount) {
    const Ed25519KeyPair identity = Ed25519KeyPair::generate();
    const X25519KeyPair identityDh = X25519KeyPair::generate();
    std::vector<X25519KeyPair> otps;
    for (int i = 0; i < oneTimePrekeyCount; ++i) otps.push_back(X25519KeyPair::generate());
    return StoredIdentity(std::move(deviceId), identity, identityDh, identity.sign(identityDh.publicKey), X25519KeyPair::generate(),
                          std::move(otps));
}

QJsonObject StoredIdentity::bundle() const {
    return bundle(oneTime_.empty() ? std::nullopt : std::optional(oneTime_.front()));
}

QJsonObject StoredIdentity::bundle(const std::optional<X25519KeyPair> &oneTimePrekey) const {
    QJsonObject o{
        {"identity_pubkey", b64(identity.publicKey)},
        {"identity_dh_pubkey", b64(identityDh_.publicKey)},
        {"identity_dh_signature", b64(identityDhSignature)},
        {"signed_prekey", b64(signedPrekey_->publicKey)},
        {"signature", b64(identity.sign(signedPrekey_->publicKey))},
    };
    if (oneTimePrekey) o.insert("one_time_prekey", b64(oneTimePrekey->publicKey));
    return o;
}

} // namespace osh
