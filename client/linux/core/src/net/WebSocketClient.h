#pragma once

// WebSocket сервера (как WebSocketClient.kt): одно соединение, переподключение
// через 3 с (перед ним — проверка сессии: не признана — sessionInvalidated),
// таймаут готовности 8 с, ping раз в 45 с (нет pong — соединение мертво).
// Входящие кадры разбираются по Type и уходят сигналами.

#include "support/Task.h"

#include <QJsonObject>
#include <QObject>
#include <QTimer>
#include <QWebSocket>

namespace osh {

class ApiClient;

enum class ConnectionStatus { WaitingForNetwork, Connecting, Connected, Reconnecting };

class WebSocketClient : public QObject {
    Q_OBJECT

public:
    explicit WebSocketClient(ApiClient &api, QObject *parent = nullptr);

    ConnectionStatus status() const { return status_; }
    bool isConnected() const { return status_ == ConnectionStatus::Connected && socket_; }

    void connectTo(const QString &token, const QString &deviceId);
    void disconnectFromServer();
    void onNetworkAvailable();
    void onNetworkLost();

    /// Конверт собеседнику; нет связи — std::runtime_error.
    void sendEnvelope(const QString &toDeviceId, const QJsonObject &envelope, const QString &deliveryId, bool silent = false);
    void ackDelivery(const QString &deliveryId);
    /// Сигнал звонка; нет связи — ждём переподключения до 5 с.
    Task<bool> sendCallSignal(QString toDeviceId, QString type, QJsonObject payload);
    void subscribePresence(const QString &peerDeviceId);
    void unsubscribePresence(const QString &peerDeviceId);
    void sendForegroundState(bool foreground);
    void sendTyping(const QString &peerDeviceId);

Q_SIGNALS:
    void statusChanged(osh::ConnectionStatus status);
    void envelopeReceived(const QJsonObject &envelope, const QString &deliveryId);
    void callSignalReceived(const QJsonObject &signal);
    void presenceEvent(const QJsonObject &frame);
    void blockStatusChanged();
    void profileChanged(const QString &accountId, const QString &field);
    void wallpaperChanged(const QString &accountId);
    void acked(const QString &deliveryId);
    void rejected(const QString &deliveryId, const QString &reason);
    void sessionInvalidated();

private:
    void setStatus(ConnectionStatus s);
    void openConnection();
    void closeCurrent();
    void scheduleReconnect(int generation);
    void forceReconnect();
    void handleFrame(const QJsonObject &outer);
    bool send(const QJsonObject &frame);
    Task<void> reconnectLater(int generation);

    ApiClient &api_;
    QWebSocket *socket_ = nullptr;
    int generation_ = 0;
    QString token_, deviceId_;
    bool manuallyDisconnected_ = false;
    bool hadNetwork_ = true;
    bool lastKnownForeground_ = false;
    bool awaitingPong_ = false;
    ConnectionStatus status_ = ConnectionStatus::Connecting;
    QTimer readyTimeout_, pingTimer_, reconnectTimer_;
};

} // namespace osh
