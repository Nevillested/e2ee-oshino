#include "net/WebSocketClient.h"

#include "net/ApiClient.h"
#include "support/Json.h"
#include "support/Log.h"

#include <QNetworkRequest>

namespace osh {

namespace {
constexpr int ReadyTimeoutMs = 8000;
constexpr int ReconnectDelayMs = 3000;
constexpr int CallSignalWaitMs = 5000;
constexpr int PingIntervalMs = 45000;

const char *statusName(ConnectionStatus s) {
    switch (s) {
    case ConnectionStatus::WaitingForNetwork: return "WAITING_FOR_NETWORK";
    case ConnectionStatus::Connecting: return "CONNECTING";
    case ConnectionStatus::Connected: return "CONNECTED";
    case ConnectionStatus::Reconnecting: return "RECONNECTING";
    }
    return "?";
}
} // namespace

WebSocketClient::WebSocketClient(ApiClient &api, QObject *parent) : QObject(parent), api_(api) {
    readyTimeout_.setSingleShot(true);
    readyTimeout_.setInterval(ReadyTimeoutMs);
    connect(&readyTimeout_, &QTimer::timeout, this, [this] {
        if (status_ != ConnectionStatus::Connected) {
            log("WS connect timeout — will retry");
            scheduleReconnect(generation_);
        }
    });
    pingTimer_.setInterval(PingIntervalMs);
    connect(&pingTimer_, &QTimer::timeout, this, [this] {
        if (!socket_) return;
        // прошлый ping остался без ответа — соединение мертво (как pingInterval в OkHttp)
        if (awaitingPong_) {
            log("WS ping timeout — reconnecting");
            scheduleReconnect(generation_);
            return;
        }
        awaitingPong_ = true;
        socket_->ping();
    });
    reconnectTimer_.setSingleShot(true);
}

void WebSocketClient::setStatus(ConnectionStatus s) {
    if (status_ == s) return;
    status_ = s;
    log(QStringLiteral("WS status -> %1").arg(QLatin1String(statusName(s))));
    Q_EMIT statusChanged(s);
}

void WebSocketClient::connectTo(const QString &token, const QString &deviceId) {
    token_ = token;
    deviceId_ = deviceId;
    manuallyDisconnected_ = false;
    closeCurrent();
    openConnection();
}

void WebSocketClient::disconnectFromServer() {
    manuallyDisconnected_ = true;
    reconnectTimer_.stop();
    closeCurrent();
}

void WebSocketClient::onNetworkAvailable() {
    const bool wasOffline = !hadNetwork_;
    hadNetwork_ = true;
    if (wasOffline) forceReconnect();
}

void WebSocketClient::onNetworkLost() {
    hadNetwork_ = false;
    setStatus(ConnectionStatus::WaitingForNetwork);
}

void WebSocketClient::forceReconnect() {
    if (manuallyDisconnected_) return;
    reconnectTimer_.stop();
    closeCurrent();
    openConnection();
}

void WebSocketClient::closeCurrent() {
    ++generation_;
    readyTimeout_.stop();
    pingTimer_.stop();
    if (socket_) {
        socket_->disconnect(this);
        socket_->abort();
        socket_->deleteLater();
        socket_ = nullptr;
    }
}

void WebSocketClient::openConnection() {
    if (token_.isEmpty() || deviceId_.isEmpty()) return;
    ++generation_;
    const int gen = generation_;
    setStatus(ConnectionStatus::Connecting);
    socket_ = new QWebSocket(QString(), QWebSocketProtocol::VersionLatest, this);
    QNetworkRequest req(QUrl(api_.wsBaseUrl() + "/ws?device_id=" + deviceId_));
    req.setRawHeader("Authorization", "Bearer " + token_.toUtf8());

    connect(socket_, &QWebSocket::connected, this, [this, gen] {
        if (gen != generation_) return;
        readyTimeout_.stop();
        awaitingPong_ = false;
        pingTimer_.start();
        setStatus(ConnectionStatus::Connected);
        sendForegroundState(lastKnownForeground_);
    });
    connect(socket_, &QWebSocket::textMessageReceived, this, [this, gen](const QString &text) {
        if (gen != generation_) return;
        try {
            handleFrame(json::parseObject(text));
        } catch (const std::exception &e) {
            log(QStringLiteral("WS recv: failed to parse frame: %1").arg(QString::fromUtf8(e.what())));
        }
    });
    connect(socket_, &QWebSocket::pong, this, [this] { awaitingPong_ = false; });
    connect(socket_, &QWebSocket::disconnected, this, [this, gen] {
        if (gen != generation_) return;
        log(QStringLiteral("WS closed code=%1 — reconnecting").arg(socket_ ? int(socket_->closeCode()) : 0));
        scheduleReconnect(gen);
    });
    connect(socket_, qOverload<QAbstractSocket::SocketError>(&QWebSocket::error), this, [this, gen](QAbstractSocket::SocketError) {
        if (gen != generation_) return;
        log(QStringLiteral("WS failure: %1 — reconnecting").arg(socket_ ? socket_->errorString() : QString()));
        scheduleReconnect(gen);
    });
    readyTimeout_.start();
    socket_->open(req);
}

void WebSocketClient::scheduleReconnect(int gen) {
    if (gen != generation_) return;
    closeCurrent();
    if (manuallyDisconnected_) return;
    setStatus(hadNetwork_ ? ConnectionStatus::Reconnecting : ConnectionStatus::WaitingForNetwork);
    spawn(reconnectLater(generation_));
}

Task<void> WebSocketClient::reconnectLater(int gen) {
    co_await delay{ReconnectDelayMs};
    if (gen != generation_ || manuallyDisconnected_ || socket_) co_return;
    std::optional<bool> sessionValid;
    if (!token_.isEmpty()) sessionValid = co_await api_.checkSession(token_); // не внутри && (GCC 11)
    if (sessionValid == std::optional(false)) {
        log("WS session invalid — stopping reconnect");
        manuallyDisconnected_ = true;
        Q_EMIT sessionInvalidated();
        co_return;
    }
    if (gen != generation_ || manuallyDisconnected_ || socket_) co_return;
    openConnection();
}

void WebSocketClient::handleFrame(const QJsonObject &outer) {
    const QString type = outer.value("Type").toString();
    const QString deliveryId = outer.value("DeliveryId").toString();
    if (type == "ack") {
        if (!deliveryId.isEmpty()) Q_EMIT acked(deliveryId);
    } else if (type == "rejected") {
        if (!deliveryId.isEmpty()) {
            const QString reason = outer.value("Reason").toString();
            log(QStringLiteral("WS recv rejected deliveryId=%1 reason=%2").arg(deliveryId, reason));
            Q_EMIT rejected(deliveryId, reason);
        }
    } else if (type == "presence" || type == "typing") {
        Q_EMIT presenceEvent(outer);
    } else if (type == "block_status_changed") {
        log("WS recv block_status_changed");
        Q_EMIT blockStatusChanged();
    } else if (type == "profile_updated") {
        const QString accountId = outer.value("AccountId").toString(), field = outer.value("Field").toString();
        log(QStringLiteral("WS recv profile_updated account=%1 field=%2").arg(accountId, field));
        if (!accountId.isEmpty() && !field.isEmpty()) Q_EMIT profileChanged(accountId, field);
    } else if (type == "wallpaper_changed") {
        const QString accountId = outer.value("AccountId").toString();
        log(QStringLiteral("WS recv wallpaper_changed account=%1").arg(accountId));
        if (!accountId.isEmpty()) Q_EMIT wallpaperChanged(accountId);
    } else if (type.startsWith("call_")) {
        if (!deliveryId.isEmpty()) send({{"Type", "ack"}, {"DeliveryId", deliveryId}});
        log(QStringLiteral("WS recv %1").arg(type));
        QJsonObject payload;
        if (outer.value("Ciphertext").isString()) payload = json::parseObject(outer.value("Ciphertext").toString());
        payload.insert("type", type);
        Q_EMIT callSignalReceived(payload);
    } else if (outer.value("Ciphertext").isString()) {
        Q_EMIT envelopeReceived(json::parseObject(outer.value("Ciphertext").toString()), deliveryId);
    }
}

bool WebSocketClient::send(const QJsonObject &frame) {
    if (!socket_ || status_ != ConnectionStatus::Connected) return false;
    return socket_->sendTextMessage(json::compact(frame)) > 0;
}

void WebSocketClient::ackDelivery(const QString &deliveryId) {
    if (isConnected()) send({{"Type", "ack"}, {"DeliveryId", deliveryId}});
}

void WebSocketClient::sendEnvelope(const QString &toDeviceId, const QJsonObject &envelope, const QString &deliveryId, bool silent) {
    if (!isConnected()) throw std::runtime_error("WebSocket не подключен");
    send({{"ToDeviceId", toDeviceId}, {"Ciphertext", json::compact(envelope)}, {"Type", "message"}, {"DeliveryId", deliveryId}, {"Silent", silent}});
}

Task<bool> WebSocketClient::sendCallSignal(QString toDeviceId, QString type, QJsonObject payload) {
    const QJsonObject frame{{"ToDeviceId", toDeviceId}, {"Ciphertext", json::compact(payload)}, {"Type", type}};
    if (!isConnected()) {
        log(QStringLiteral("WS send %1: not connected, waiting up to %2ms").arg(type).arg(CallSignalWaitMs));
        Deferred<bool> ready;
        auto conn = connect(this, &WebSocketClient::statusChanged, this, [ready](ConnectionStatus s) {
            if (s == ConnectionStatus::Connected) ready.resolve(true);
        });
        const bool ok = (co_await ready.waitFor(CallSignalWaitMs)).has_value();
        disconnect(conn);
        if (!ok || !isConnected()) {
            log(QStringLiteral("WS sendCallSignal type=%1 DROPPED — no connection within %2ms").arg(type).arg(CallSignalWaitMs));
            co_return false;
        }
    }
    const bool ok = send(frame);
    log(QStringLiteral("WS send %1 to=%2 ok=%3").arg(type, toDeviceId).arg(ok));
    co_return ok;
}

void WebSocketClient::subscribePresence(const QString &peer) { send({{"Type", "presence_subscribe"}, {"ToDeviceId", peer}}); }
void WebSocketClient::unsubscribePresence(const QString &peer) { send({{"Type", "presence_unsubscribe"}, {"ToDeviceId", peer}}); }

void WebSocketClient::sendForegroundState(bool foreground) {
    lastKnownForeground_ = foreground;
    send({{"Type", "presence_foreground"}, {"Foreground", foreground}});
}

void WebSocketClient::sendTyping(const QString &peer) { send({{"Type", "typing"}, {"ToDeviceId", peer}}); }

} // namespace osh
