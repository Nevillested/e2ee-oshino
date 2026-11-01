#pragma once

// Приём (как MessageRouter.kt): расшифровка текущей сессией → архивной → новой
// X3DH; дубль — ack без обработки; самолечение: 3 провала подряд — автосброс
// сессии (не чаще раза в 30 с, и не для неподтверждённой сессии); долго нет
// сессии — заглушка «не удалось расшифровать». Затем — применение по типу.

#include "net/ApiClient.h"
#include "net/WebSocketClient.h"
#include "protocol/InnerMessage.h"
#include "service/Infra.h"
#include "service/Messaging.h"
#include "storage/ChatStore.h"
#include "storage/Stores.h"

#include <QHash>
#include <QObject>
#include <functional>

namespace osh {

/// Что ядру нужно от приложения при приёме.
class RouterHost {
public:
    virtual ~RouterHost() = default;
    virtual QString openChatPeerLogin() const = 0;
    virtual bool isAppInForeground() const = 0;
    virtual void playMessageSound() = 0;
    virtual void showMessageNotification(const QString &peerLogin, const QString &preview) = 0;
};

struct DeviceOwnerRef {
    QString accountId;
    QString login;
};

class MessageRouter : public QObject {
    Q_OBJECT
public:
    MessageRouter(WebSocketClient &ws, ApiClient &api, Session &session, KeyStore &keys, SessionStore &sessions, PeerAccountStore &peerAccounts,
                  PeerIdentityStore &peerIdentities, ChatStore &chats, Prefs &prefs, SendQueueProcessor &queue, KeyedMutex &sendLock,
                  RouterHost &host, std::function<void(const QList<StoredMessage> &)> purgeMedia, QObject *parent = nullptr);

    void start();
    Task<void> handleIncoming(QJsonObject envelope, QString deliveryId);
    /// Сигнал звонка, зашифрованный тем же ratchet; nullopt — не расшифровался.
    Task<std::optional<QJsonObject>> openCallSignal(QString senderDeviceId, QJsonObject envelope);
    Task<void> resetSessionWith(QString deviceId, QString reason);
    std::optional<DeviceOwnerRef> knownOwner(const QString &deviceId);
    Task<std::optional<DeviceOwnerRef>> resolveOwner(QString deviceId);

Q_SIGNALS:
    void incomingReaction(const QString &peerLogin, const QString &messageId);
    void incomingDelete(const QString &peerLogin, const QStringList &targetIds);

private:
    struct Opened {
        enum Kind { Ok, Duplicate, Failed } kind;
        QString raw;
        std::optional<RatchetState> current;
        bool triedFresh = false;
    };

    Task<void> process(QString senderDeviceId, QJsonObject envelope, QString deliveryId);
    Opened open(const QString &senderDeviceId, const QJsonObject &envelope);
    Opened opened(const QString &senderDeviceId, const QString &raw);
    Task<std::optional<InnerMessage>> decrypt(QString senderDeviceId, QJsonObject envelope, QString deliveryId);
    Task<void> handleUnrecoverable(QString senderDeviceId, QJsonObject envelope, QString deliveryId, RatchetState state);
    std::optional<RatchetState> establishFreshIncoming(const QString &senderDeviceId, const QJsonObject &envelope);
    Task<bool> onDecryptFailure(QString senderDeviceId, QString deliveryId);
    void resetLocked(const QString &deviceId, const QString &reason);
    bool giveUpIfNoSessionTooLong(const QString &deviceId);
    void rememberDecrypted(const QString &deviceId, const QJsonObject &envelope);
    Task<void> recordUndecryptable(QString deviceId, QJsonObject envelope, bool requireKnownHistory = false);
    void apply(const InnerMessage &inner, const DeviceOwnerRef &owner, bool chatIsOpen);
    void ack(const QString &deliveryId);

    WebSocketClient &ws_;
    ApiClient &api_;
    Session &session_;
    KeyStore &keys_;
    SessionStore &sessions_;
    PeerAccountStore &peerAccounts_;
    PeerIdentityStore &peerIdentities_;
    ChatStore &chats_;
    Prefs &prefs_;
    SendQueueProcessor &queue_;
    KeyedMutex &sendLock_;
    RouterHost &host_;
    std::function<void(const QList<StoredMessage> &)> purgeMedia_;
    QHash<QString, DeviceOwnerRef> ownerCache_;
    bool started_ = false;
};

/// Сообщение-вложение из полей body 'media' (и элементов 'media_group').
StoredMessage mediaMessageFromBody(const QString &messageId, const QJsonObject &b, qint64 sentAt, const std::optional<QString> &groupId);

} // namespace osh
