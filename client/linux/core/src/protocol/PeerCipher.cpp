#include "protocol/PeerCipher.h"

#include "crypto/MessageCipher.h"
#include "support/Json.h"

namespace osh::PeerCipher {

std::pair<RatchetState, QJsonObject> startOutgoingSession(const QJsonObject &bundle, const QString &myDeviceId,
                                                          const X25519KeyPair &myIdentityDh) {
    const X3dhOutgoing out = establishOutgoingRoot(bundle, myDeviceId, myIdentityDh);
    return {RatchetState::initAsSender(out.rootKey, out.ephemeralKeyPair), out.initHeader};
}

QJsonObject seal(RatchetState &state, const InnerMessage &inner, const QString &myDeviceId, const QJsonObject &initHeader) {
    return sealText(state, inner.encode(), myDeviceId, initHeader);
}

QJsonObject sealText(RatchetState &state, const QString &plaintext, const QString &myDeviceId, const QJsonObject &initHeader) {
    const SendingKey next = state.nextSendingKey();
    QJsonObject header = next.header();
    header.insert("sender_device_id", myDeviceId);
    for (auto it = initHeader.begin(); it != initHeader.end(); ++it) header.insert(it.key(), it.value());
    QJsonObject envelope = encryptMessage(next.messageKey, plaintext, header);
    for (auto it = header.begin(); it != header.end(); ++it) envelope.insert(it.key(), it.value());
    return envelope;
}

InnerMessage open(RatchetState &state, const QJsonObject &envelope) {
    const QByteArray key = state.nextReceivingKey(envelope);
    return InnerMessage::decode(decryptMessage(key, envelope));
}

std::optional<std::pair<RatchetState, X3dhIncoming>> startIncomingSession(const QJsonObject &envelope, const LocalIdentity &me) {
    auto incoming = establishIncomingRoot(envelope, me);
    if (!incoming) return std::nullopt;
    const QByteArray ephemeral = unb64(json::string(envelope, "ephemeral_pubkey"));
    return std::pair{RatchetState::initAsReceiver(incoming->rootKey, ephemeral), std::move(*incoming)};
}

} // namespace osh::PeerCipher
