#pragma once

// Отправка (как SendQueueProcessor.kt + PeerMessenger.kt + DeviceSetup).
//
// SendQueueProcessor — надёжная исходящая очередь: конверт сначала ложится на
// диск и уходит из очереди ТОЛЬКО по ack сервера. Нет связи — ждёт
// переподключения; ack не пришёл за 8 с — слушаем опоздавший ack, при
// переподключении конверт уходит снова (дубли гасятся на приёме по message_id).
// Отказ сервера ("rejected") — конверт убирается, сообщение «не отправлено».
//
// PeerMessenger — шифрует и ставит в очередь; нет сессии — X3DH по бандлу.
// DeviceSetup — регистрация устройства и пополнение одноразовых prekey.

#include "net/ApiClient.h"
#include "net/WebSocketClient.h"
#include "protocol/InnerMessage.h"
#include "service/Infra.h"
#include "storage/ChatStore.h"
#include "storage/Stores.h"

#include <QSet>
#include <functional>

namespace osh {

class SendQueueProcessor : public QObject {
    Q_OBJECT
public:
    SendQueueProcessor(SendQueueStore &store, WebSocketClient &ws, AckRegistry &acks, ChatStore &chats, QObject *parent = nullptr);

    void start();
    using OnAcked = std::function<void()>;
    void enqueue(const QString &toDeviceId, const QJsonObject &envelope, const QString &deliveryId, bool silent = false,
                 const std::optional<QString> &messageId = std::nullopt, const std::optional<QString> &peerLogin = std::nullopt,
                 OnAcked onAcked = {});
    void sweep();
    /// id конвертов, ждущих ack (переживают перезапуск).
    QSet<QString> pendingIds() const;
    /// Снять с очереди конверты этих сообщений (отмена отправки).
    void drop(const QSet<QString> &messageIds);

private:
    Task<void> attempt(QString id, QString toDeviceId, QJsonObject envelope, bool silent, std::optional<QString> messageId,
                       std::optional<QString> peerLogin);
    Task<void> awaitLateAck(Deferred<bool> ack, QString id, std::optional<QString> messageId, std::optional<QString> peerLogin);
    void finalizeAcked(const QString &id, const std::optional<QString> &messageId, const std::optional<QString> &peerLogin);
    void finalizeRejected(const QString &id, const std::optional<QString> &messageId, const std::optional<QString> &peerLogin, const QString &reason);

    SendQueueStore &store_;
    WebSocketClient &ws_;
    AckRegistry &acks_;
    ChatStore &chats_;
    QSet<QString> inFlight_;
    QHash<QString, OnAcked> onAcked_;
    bool started_ = false;
};

class PeerMessenger {
public:
    PeerMessenger(ApiClient &api, Session &session, KeyStore &keys, SessionStore &sessions, PeerAccountStore &peerAccounts,
                  PeerIdentityStore &peerIdentities, ChatStore &chats, SendQueueProcessor &queue, KeyedMutex &sendLock);

    /// Зашифровать и поставить в очередь; trackStatus — сообщение станет 'sent' по ack.
    Task<void> send(QString peerDeviceId, InnerMessage inner, std::optional<QString> peerLogin = std::nullopt, bool silent = false,
                    std::optional<bool> trackStatus = std::nullopt, SendQueueProcessor::OnAcked onAcked = {});
    Task<QJsonObject> sealCallSignal(QString peerDeviceId, QJsonObject payload);
    /// Служебное (реакция, правка, прочтение…): ошибка — только в журнал.
    Task<void> sendControl(QString peerDeviceId, InnerMessage inner);
    /// Текущее устройство собеседника (вход с нового телефона — новое); нет связи — [fallback].
    Task<QString> resolvePeerDeviceId(QString peerLogin, QString fallback);

private:
    Task<QJsonObject> sealLocked(QString peerDeviceId, QString plaintext);

    ApiClient &api_;
    Session &session_;
    KeyStore &keys_;
    SessionStore &sessions_;
    PeerAccountStore &peerAccounts_;
    PeerIdentityStore &peerIdentities_;
    ChatStore &chats_;
    SendQueueProcessor &queue_;
    KeyedMutex &sendLock_;
};

class DeviceSetup {
public:
    DeviceSetup(ApiClient &api, KeyStore &keys) : api_(api), keys_(keys) {}
    Task<void> ensureDeviceRegistered(QString token);
    Task<void> ensurePrekeysTopped(QString token, QString deviceId);

private:
    ApiClient &api_;
    KeyStore &keys_;
};

} // namespace osh
