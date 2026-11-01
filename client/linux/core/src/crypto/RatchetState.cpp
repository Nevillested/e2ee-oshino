#include "crypto/RatchetState.h"

#include "support/Json.h"

namespace osh {

namespace {

constexpr int MaxSkippedKeys = 100; // защита от чрезмерного расхода памяти/диска
const QByteArray InfoInit = QByteArrayLiteral("oshinobu-init");
const QByteArray InfoRatchet = QByteArrayLiteral("oshinobu-ratchet");

QByteArray chainStep(const QByteArray &key, int marker) { return hmacSha256(key, QByteArray(1, char(marker))); }

QJsonValue optB64(const std::optional<QByteArray> &b) { return b ? QJsonValue(b64(*b)) : QJsonValue(QJsonValue::Null); }

} // namespace

AlreadyProcessedError::AlreadyProcessedError(int n)
    : std::runtime_error("Сообщение с номером " + std::to_string(n) + " уже было обработано ранее"), messageNumber(n) {}

QJsonObject SendingKey::header() const { return {{"ratchet_pubkey", b64(ratchetPubkey)}, {"message_number", messageNumber}}; }

RatchetState::RatchetState(QByteArray root, X25519KeyPair sending) : rootKey(std::move(root)), sendingRatchetKeyPair(std::move(sending)) {}

void RatchetState::dhRatchetStepForSending() {
    const X25519KeyPair newKeyPair = X25519KeyPair::generate();
    const QByteArray derived = hkdfSha256(rootKey + newKeyPair.sharedSecret(*receivingRatchetPublicKey), InfoRatchet, 64);
    rootKey = derived.left(32);
    sendingChainKey = derived.mid(32, 32);
    sendingRatchetKeyPair = newKeyPair;
    sendMessageNumber = 0;
    needsSendingRatchet = false;
}

void RatchetState::dhRatchetStepForReceiving(const QByteArray &newRemotePubkey) {
    const QByteArray derived = hkdfSha256(rootKey + sendingRatchetKeyPair.sharedSecret(newRemotePubkey), InfoRatchet, 64);
    rootKey = derived.left(32);
    receivingChainKey = derived.mid(32, 32);
    receivingRatchetPublicKey = newRemotePubkey;
    receiveMessageNumber = 0;
    needsSendingRatchet = true;
    // ключи прошлой эпохи относились к другой цепочке — больше не нужны
    skippedReceivingKeys.clear();
}

SendingKey RatchetState::nextSendingKey() {
    if (needsSendingRatchet) dhRatchetStepForSending();
    if (!sendingChainKey) throw CryptoError("ratchet: нет цепочки отправки");
    const QByteArray chain = *sendingChainKey;
    SendingKey key{sendingRatchetKeyPair.publicKey, sendMessageNumber, chainStep(chain, 1)};
    sendingChainKey = chainStep(chain, 2);
    ++sendMessageNumber;
    return key;
}

QByteArray RatchetState::nextReceivingKey(const QByteArray &ratchetPubkey, int messageNumber) {
    if (!receivingRatchetPublicKey || !constantTimeEquals(*receivingRatchetPublicKey, ratchetPubkey)) {
        dhRatchetStepForReceiving(ratchetPubkey);
    }

    if (auto it = skippedReceivingKeys.find(messageNumber); it != skippedReceivingKeys.end()) {
        QByteArray key = it->second;
        skippedReceivingKeys.erase(it);
        return key;
    }

    // ключ уже израсходован, но сама сессия здорова — это дубль
    if (messageNumber < receiveMessageNumber) throw AlreadyProcessedError(messageNumber);
    if (messageNumber - receiveMessageNumber > MaxSkippedKeys) {
        throw RatchetGapTooLargeError("Слишком большой разрыв в номерах сообщений (" + std::to_string(receiveMessageNumber) + " → " +
                                      std::to_string(messageNumber) + ") — отказ от обработки");
    }

    while (receiveMessageNumber < messageNumber) {
        const QByteArray chain = *receivingChainKey;
        skippedReceivingKeys[receiveMessageNumber] = chainStep(chain, 1);
        receivingChainKey = chainStep(chain, 2);
        ++receiveMessageNumber;
    }

    const QByteArray chain = *receivingChainKey;
    const QByteArray messageKey = chainStep(chain, 1);
    receivingChainKey = chainStep(chain, 2);
    ++receiveMessageNumber;
    return messageKey;
}

QByteArray RatchetState::nextReceivingKey(const QJsonObject &envelope) {
    const QJsonValue n = envelope.value(QLatin1String("message_number"));
    if (!n.isDouble()) throw CryptoError("в конверте нет message_number");
    return nextReceivingKey(unb64(json::string(envelope, "ratchet_pubkey")), int(n.toInteger()));
}

QJsonObject RatchetState::toJson() const {
    QJsonObject skipped;
    for (const auto &[n, k] : skippedReceivingKeys) skipped.insert(QString::number(n), b64(k));
    return {
        {"root_key", b64(rootKey)},
        {"sending_chain_key", optB64(sendingChainKey)},
        {"receiving_chain_key", optB64(receivingChainKey)},
        {"sending_ratchet_private", b64(sendingRatchetKeyPair.privateKey)},
        {"sending_ratchet_public", b64(sendingRatchetKeyPair.publicKey)},
        {"receiving_ratchet_public", optB64(receivingRatchetPublicKey)},
        {"send_message_number", sendMessageNumber},
        {"receive_message_number", receiveMessageNumber},
        {"needs_sending_ratchet", needsSendingRatchet},
        {"skipped_receiving_keys", skipped},
    };
}

RatchetState RatchetState::initAsSender(const QByteArray &rootKey, const X25519KeyPair &ephemeralKeyPair) {
    RatchetState s(rootKey, ephemeralKeyPair);
    s.sendingChainKey = hkdfSha256(rootKey, InfoInit, 32);
    return s;
}

RatchetState RatchetState::initAsReceiver(const QByteArray &rootKey, const QByteArray &remoteEphemeralPubkey) {
    RatchetState s(rootKey, X25519KeyPair::generate());
    s.receivingChainKey = hkdfSha256(rootKey, InfoInit, 32);
    s.receivingRatchetPublicKey = remoteEphemeralPubkey;
    s.needsSendingRatchet = true;
    return s;
}

RatchetState RatchetState::fromJson(const QJsonObject &obj) {
    auto bytes = [&](const char *name) -> std::optional<QByteArray> {
        const auto s = json::optString(obj, name);
        return s ? std::optional(unb64(*s)) : std::nullopt;
    };
    auto required = [&](const char *name) {
        auto b = bytes(name);
        if (!b) throw CryptoError(std::string("состояние ratchet: нет поля ") + name);
        return *b;
    };
    // публичный ключ хранится явно, рядом с приватным — берём его, а не пересчитываем
    RatchetState s(required("root_key"), X25519KeyPair(required("sending_ratchet_private"), required("sending_ratchet_public")));
    s.sendingChainKey = bytes("sending_chain_key");
    s.receivingChainKey = bytes("receiving_chain_key");
    s.receivingRatchetPublicKey = bytes("receiving_ratchet_public");
    s.sendMessageNumber = int(obj.value(QLatin1String("send_message_number")).toInteger());
    s.receiveMessageNumber = int(obj.value(QLatin1String("receive_message_number")).toInteger());
    s.needsSendingRatchet = obj.value(QLatin1String("needs_sending_ratchet")).toBool();
    const QJsonObject skipped = obj.value(QLatin1String("skipped_receiving_keys")).toObject();
    for (auto it = skipped.begin(); it != skipped.end(); ++it) s.skippedReceivingKeys[it.key().toInt()] = unb64(it.value().toString());
    return s;
}

} // namespace osh
