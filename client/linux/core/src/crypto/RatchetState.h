#pragma once

// Double Ratchet (как RatchetState.kt). Info-строки HKDF, маркеры HMAC цепочки
// и JSON состояния — зафиксированный формат (сессии сохранены на телефонах,
// собеседники на других версиях должны расшифровывать), его сторожит
// ProtocolVectorsTest.

#include "crypto/Primitives.h"

#include <QJsonObject>
#include <map>
#include <optional>

namespace osh {

/**
 * Сообщение с этим номером уже было честно расшифровано раньше — повторная
 * доставка, а не рассинхрон: вызывающему коду нужно отличать это от настоящей
 * ошибки, иначе всплеск дублей после реконнекта сносит рабочую сессию.
 */
struct AlreadyProcessedError : std::runtime_error {
    int messageNumber;
    explicit AlreadyProcessedError(int n);
};

struct RatchetGapTooLargeError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

/// Заголовок исходящего сообщения + ключ, которым его шифровать.
struct SendingKey {
    QByteArray ratchetPubkey;
    int messageNumber;
    QByteArray messageKey;

    QJsonObject header() const;
};

/**
 * Всё состояние сессии с одним устройством собеседника.
 *
 * ВАЖНОЕ ПРАВИЛО: сохранять состояние на диск можно ТОЛЬКО после успешной
 * расшифровки сообщения этим ключом. Сохранишь раньше, а расшифровка упадёт —
 * состояние навсегда "убежит вперёд".
 */
class RatchetState {
public:
    QByteArray rootKey;
    X25519KeyPair sendingRatchetKeyPair;
    std::optional<QByteArray> sendingChainKey;
    std::optional<QByteArray> receivingChainKey;
    std::optional<QByteArray> receivingRatchetPublicKey;
    int sendMessageNumber = 0;
    int receiveMessageNumber = 0;
    bool needsSendingRatchet = false;
    /// Ключи "перескоченных" сообщений текущей эпохи — вдруг они придут с опозданием.
    std::map<int, QByteArray> skippedReceivingKeys;

    RatchetState(QByteArray rootKey, X25519KeyPair sendingRatchetKeyPair);

    SendingKey nextSendingKey();
    /// Ключ для конкретного входящего сообщения по полям его заголовка.
    QByteArray nextReceivingKey(const QByteArray &ratchetPubkey, int messageNumber);
    QByteArray nextReceivingKey(const QJsonObject &envelope);

    /// JSON состояния — формат хранения (не менять без миграции).
    QJsonObject toJson() const;

    static RatchetState initAsSender(const QByteArray &rootKey, const X25519KeyPair &ephemeralKeyPair);
    static RatchetState initAsReceiver(const QByteArray &rootKey, const QByteArray &remoteEphemeralPubkey);
    static RatchetState fromJson(const QJsonObject &obj);

private:
    void dhRatchetStepForSending();
    void dhRatchetStepForReceiving(const QByteArray &newRemotePubkey);
};

} // namespace osh
