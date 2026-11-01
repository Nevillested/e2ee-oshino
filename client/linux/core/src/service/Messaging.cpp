#include "service/Messaging.h"

#include "protocol/PeerCipher.h"
#include "support/Json.h"
#include "support/Log.h"

namespace osh {

namespace {
constexpr int AckTimeoutMs = 8000;
constexpr int LowWatermark = 5;
constexpr int TargetPool = 20;
} // namespace

// ---------------- SendQueueProcessor ----------------

SendQueueProcessor::SendQueueProcessor(SendQueueStore &store, WebSocketClient &ws, AckRegistry &acks, ChatStore &chats, QObject *parent)
    : QObject(parent), store_(store), ws_(ws), acks_(acks), chats_(chats) {}

void SendQueueProcessor::start() {
    if (started_) return;
    started_ = true;
    connect(&ws_, &WebSocketClient::statusChanged, this, [this](ConnectionStatus s) {
        if (s == ConnectionStatus::Connected) sweep();
    });
}

void SendQueueProcessor::enqueue(const QString &toDeviceId, const QJsonObject &envelope, const QString &deliveryId, bool silent,
                                 const std::optional<QString> &messageId, const std::optional<QString> &peerLogin, OnAcked onAcked) {
    store_.add(deliveryId, toDeviceId, envelope, silent, messageId, peerLogin);
    if (onAcked) onAcked_.insert(deliveryId, std::move(onAcked));
    spawn(attempt(deliveryId, toDeviceId, envelope, silent, messageId, peerLogin));
}

void SendQueueProcessor::sweep() {
    const auto items = store_.getAll();
    if (!items.isEmpty()) log(QStringLiteral("SendQueueProcessor sweep: %1 item(s) pending").arg(items.size()));
    for (const QJsonObject &item : items) {
        spawn(attempt(item.value("id").toString(), item.value("to_device_id").toString(), item.value("envelope").toObject(),
                      item.value("silent").toBool(), json::optString(item, "message_id"), json::optString(item, "peer_login")));
    }
}

QSet<QString> SendQueueProcessor::pendingIds() const {
    QSet<QString> ids;
    for (const QJsonObject &item : store_.getAll()) {
        ids.insert(item.value("id").toString());
        if (const auto m = json::optString(item, "message_id")) ids.insert(*m);
    }
    return ids;
}

void SendQueueProcessor::drop(const QSet<QString> &messageIds) {
    for (const QJsonObject &item : store_.getAll()) {
        const auto m = json::optString(item, "message_id");
        if (!m || !messageIds.contains(*m)) continue;
        const QString id = item.value("id").toString();
        store_.remove(id);
        acks_.cancel(id);
        onAcked_.remove(id);
    }
}

Task<void> SendQueueProcessor::attempt(QString id, QString toDeviceId, QJsonObject envelope, bool silent, std::optional<QString> messageId,
                                       std::optional<QString> peerLogin) {
    if (inFlight_.contains(id)) co_return; // уже в полёте — не дублируем попытку
    inFlight_.insert(id);
    const Deferred<bool> ack = acks_.waiter(id);
    try {
        ws_.sendEnvelope(toDeviceId, envelope, id, silent);
    } catch (const std::exception &e) {
        acks_.cancel(id);
        inFlight_.remove(id);
        log(QStringLiteral("SendQueueProcessor id=%1 not sent (offline): %2").arg(id, QString::fromUtf8(e.what())));
        co_return; // уйдёт при переподключении (sweep)
    }
    std::optional<bool> got;
    try {
        got = co_await ack.waitFor(AckTimeoutMs);
    } catch (const DeliveryRejectedError &e) {
        inFlight_.remove(id);
        finalizeRejected(id, messageId, peerLogin, e.reason);
        co_return;
    }
    inFlight_.remove(id);
    if (!got) {
        log(QStringLiteral("SendQueueProcessor id=%1 no ack within timeout — still listening for a late ack").arg(id));
        spawn(awaitLateAck(ack, id, messageId, peerLogin));
        co_return;
    }
    finalizeAcked(id, messageId, peerLogin);
}

Task<void> SendQueueProcessor::awaitLateAck(Deferred<bool> ack, QString id, std::optional<QString> messageId, std::optional<QString> peerLogin) {
    try {
        // ack без срока: придёт с опозданием или после повторной отправки
        if (!(co_await ack.wait())) co_return;
    } catch (const DeliveryRejectedError &e) {
        finalizeRejected(id, messageId, peerLogin, e.reason);
        co_return;
    }
    finalizeAcked(id, messageId, peerLogin);
}

void SendQueueProcessor::finalizeRejected(const QString &id, const std::optional<QString> &messageId, const std::optional<QString> &peerLogin,
                                          const QString &reason) {
    log(QStringLiteral("SendQueueProcessor id=%1 rejected by server (%2) — dropped from queue").arg(id, reason));
    store_.remove(id);
    if (messageId && peerLogin) chats_.updateMessageStatus(*peerLogin, *messageId, MessageStatus::Failed);
    onAcked_.remove(id);
}

void SendQueueProcessor::finalizeAcked(const QString &id, const std::optional<QString> &messageId, const std::optional<QString> &peerLogin) {
    store_.remove(id);
    if (messageId && peerLogin) chats_.updateMessageStatus(*peerLogin, *messageId, MessageStatus::Sent);
    if (const auto cb = onAcked_.take(id)) cb();
}

// ---------------- PeerMessenger ----------------

PeerMessenger::PeerMessenger(ApiClient &api, Session &session, KeyStore &keys, SessionStore &sessions, PeerAccountStore &peerAccounts,
                             PeerIdentityStore &peerIdentities, ChatStore &chats, SendQueueProcessor &queue, KeyedMutex &sendLock)
    : api_(api), session_(session), keys_(keys), sessions_(sessions), peerAccounts_(peerAccounts), peerIdentities_(peerIdentities),
      chats_(chats), queue_(queue), sendLock_(sendLock) {}

Task<void> PeerMessenger::send(QString peerDeviceId, InnerMessage inner, std::optional<QString> peerLogin, bool silent,
                               std::optional<bool> trackStatus, SendQueueProcessor::OnAcked onAcked) {
    if (peerDeviceId.isEmpty()) throw std::runtime_error("нет device_id собеседника");
    const bool track = trackStatus.value_or(!silent);
    auto guard = co_await sendLock_[peerDeviceId].lock();
    const QJsonObject envelope = co_await sealLocked(peerDeviceId, inner.encode());
    queue_.enqueue(peerDeviceId, envelope, inner.messageId, silent, track ? std::optional(inner.messageId) : std::nullopt,
                   track ? peerLogin : std::nullopt, std::move(onAcked));
}

Task<QJsonObject> PeerMessenger::sealCallSignal(QString peerDeviceId, QJsonObject payload) {
    auto guard = co_await sendLock_[peerDeviceId].lock();
    co_return co_await sealLocked(peerDeviceId, json::compact(payload));
}

Task<QJsonObject> PeerMessenger::sealLocked(QString peerDeviceId, QString plaintext) {
    const auto myDeviceId = keys_.deviceId();
    if (!myDeviceId) throw std::runtime_error("устройство не зарегистрировано");
    std::optional<RatchetState> state = sessions_.get(peerDeviceId);
    QJsonObject initHeader;
    if (!state) {
        const auto token = session_.token();
        if (!token) throw std::runtime_error("нет токена");
        const QJsonObject bundle = co_await api_.getPrekeyBundle(*token, peerDeviceId);
        if (const auto acc = json::optString(bundle, "account_id")) peerAccounts_.save(peerDeviceId, *acc);
        peerIdentities_.save(peerDeviceId, json::string(bundle, "identity_dh_pubkey"));
        const DeviceIdentity me = keys_.getOrCreateIdentity();
        auto [fresh, header] = PeerCipher::startOutgoingSession(bundle, *myDeviceId, me.identityDh);
        state.emplace(std::move(fresh));
        initHeader = header;
        sessions_.savePendingInit(peerDeviceId, header);
        log(QStringLiteral("PeerMessenger: fresh X3DH session to=%1").arg(peerDeviceId));
    } else {
        // собеседник ещё не ответил — X3DH-поля едут в каждом конверте, пока сессия не подтверждена
        initHeader = sessions_.pendingInit(peerDeviceId).value_or(QJsonObject());
    }
    const QJsonObject envelope = PeerCipher::sealText(*state, plaintext, *myDeviceId, initHeader);
    sessions_.save(peerDeviceId, *state);
    co_return envelope;
}

Task<void> PeerMessenger::sendControl(QString peerDeviceId, InnerMessage inner) {
    if (peerDeviceId.isEmpty()) co_return;
    try {
        co_await send(peerDeviceId, inner, std::nullopt, true);
    } catch (const std::exception &e) {
        log(QStringLiteral("ControlMessageSender send-FAILED to=%1 type=%2 error=%3").arg(peerDeviceId, inner.type, QString::fromUtf8(e.what())));
    }
}

Task<QString> PeerMessenger::resolvePeerDeviceId(QString peerLogin, QString fallback) {
    try {
        const auto token = session_.token();
        if (!token) co_return fallback;
        const AccountDevices devices = co_await api_.getDevicesByLogin(*token, peerLogin);
        if (!devices.devices.isEmpty()) {
            const QString id = devices.devices.first().value("device_id").toString();
            if (!id.isEmpty()) {
                chats_.setLastKnownDeviceId(peerLogin, id);
                co_return id;
            }
        }
    } catch (const std::exception &) {
    }
    co_return fallback;
}

// ---------------- DeviceSetup ----------------

Task<void> DeviceSetup::ensureDeviceRegistered(QString token) {
    if (keys_.deviceId()) co_return;
    const DeviceIdentity me = keys_.getOrCreateIdentity();
    const QString deviceId = co_await api_.registerDevice(token, b64(me.identity.publicKey), b64(me.identityDh.publicKey), b64(me.identityDhSignature));
    const auto [spk, spkSig] = keys_.createSignedPrekey(me.identity);
    QStringList otps;
    for (const QByteArray &k : keys_.createOneTimePrekeys(TargetPool)) otps << b64(k);
    co_await api_.uploadPrekeys(token, deviceId, b64(spk), b64(spkSig), otps);
    keys_.saveDeviceId(deviceId);
    log(QStringLiteral("DeviceSetup: device registered id=%1").arg(deviceId));
}

Task<void> DeviceSetup::ensurePrekeysTopped(QString token, QString deviceId) {
    try {
        const auto remaining = co_await api_.getPrekeyCount(token, deviceId);
        if (!remaining || *remaining > LowWatermark) co_return;
        const int needed = TargetPool - *remaining;
        if (needed <= 0) co_return;
        const auto identity = keys_.loadIdentity();
        if (!identity || !identity->signedPrekey()) co_return;
        const X25519KeyPair &spk = *identity->signedPrekey();
        QStringList fresh;
        for (const QByteArray &k : keys_.createOneTimePrekeys(needed)) fresh << b64(k);
        co_await api_.uploadPrekeys(token, deviceId, b64(spk.publicKey), b64(identity->identity.sign(spk.publicKey)), fresh);
        log(QStringLiteral("PrekeyReplenisher topped up %1 one-time prekeys (had %2)").arg(needed).arg(*remaining));
    } catch (const std::exception &e) {
        log(QStringLiteral("PrekeyReplenisher failed: %1").arg(QString::fromUtf8(e.what())));
    }
}

} // namespace osh
