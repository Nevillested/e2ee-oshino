#include "crypto/X3dh.h"

#include "support/Json.h"

namespace osh {

namespace {

const QByteArray InfoRoot = QByteArrayLiteral("OshinobuX3DHRoot");

QByteArray deriveRootKey(const QByteArray &ikm) { return hkdfSha256(ikm, InfoRoot, 32); }

QByteArray ffPrefix() { return QByteArray(32, char(0xFF)); }

} // namespace

X3dhOutgoing establishOutgoingRoot(const QJsonObject &bundle, const QString &myDeviceId, const X25519KeyPair &myIdentityDh) {
    auto field = [&](const char *name) { return unb64(json::string(bundle, name)); };
    const QByteArray remoteIdentity = field("identity_pubkey");
    const QByteArray remoteIdentityDh = field("identity_dh_pubkey");
    const QByteArray remoteSignedPrekey = field("signed_prekey");
    const auto oneTimeB64 = json::optString(bundle, "one_time_prekey");

    const bool signedPrekeyValid = Ed25519KeyPair::verify(remoteIdentity, remoteSignedPrekey, field("signature"));
    const bool identityDhValid = Ed25519KeyPair::verify(remoteIdentity, remoteIdentityDh, field("identity_dh_signature"));
    if (!signedPrekeyValid || !identityDhValid) throw X3dhSignatureError();

    const X25519KeyPair ephemeral = X25519KeyPair::generate();
    QByteArray ikm = ffPrefix() + myIdentityDh.sharedSecret(remoteSignedPrekey) + ephemeral.sharedSecret(remoteIdentityDh) +
                     ephemeral.sharedSecret(remoteSignedPrekey);
    if (oneTimeB64) ikm += ephemeral.sharedSecret(unb64(*oneTimeB64));

    return X3dhOutgoing{
        deriveRootKey(ikm),
        ephemeral,
        QJsonObject{
            {"sender_device_id", myDeviceId},
            {"sender_identity_dh_pubkey", b64(myIdentityDh.publicKey)},
            {"ephemeral_pubkey", b64(ephemeral.publicKey)},
            {"used_one_time_prekey", json::nullable(oneTimeB64)},
        },
    };
}

std::optional<X3dhIncoming> establishIncomingRoot(const QJsonObject &envelope, const LocalIdentity &me) {
    const auto senderIdentityDhB64 = json::optString(envelope, "sender_identity_dh_pubkey");
    const auto senderEphemeralB64 = json::optString(envelope, "ephemeral_pubkey");
    if (!senderIdentityDhB64 || !senderEphemeralB64 || !me.signedPrekey()) return std::nullopt;
    const QByteArray senderIdentityDh = unb64(*senderIdentityDhB64);
    const QByteArray senderEphemeral = unb64(*senderEphemeralB64);
    const X25519KeyPair &signedPrekey = *me.signedPrekey();

    QByteArray ikm = ffPrefix() + signedPrekey.sharedSecret(senderIdentityDh) + me.identityDh().sharedSecret(senderEphemeral) +
                     signedPrekey.sharedSecret(senderEphemeral);

    X3dhIncoming result;
    if (const auto usedOneTime = json::optString(envelope, "used_one_time_prekey")) {
        if (const auto otp = me.findOneTimePrekey(*usedOneTime)) {
            ikm += otp->sharedSecret(senderEphemeral);
            result.consumedOneTimePrekey = *usedOneTime;
        } else {
            result.missingOneTimePrekey = true;
        }
    }
    result.rootKey = deriveRootKey(ikm);
    return result;
}

} // namespace osh
