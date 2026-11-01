#include "service/Calls.h"

#include "support/Json.h"
#include "support/Log.h"

#include <QDateTime>
#include <QSet>
#include <QUuid>

namespace osh {

namespace {
constexpr int EndReasonDelayMs = 1800;
constexpr int RingTimeoutMs = 120000;
constexpr int StepTimeoutMs = 20000;
const char *Stun = "stun:stun.l.google.com:19302";

qint64 now() { return QDateTime::currentMSecsSinceEpoch(); }
QString what(const std::exception &e) { return QString::fromUtf8(e.what()); }

const QSet<QString> &requiresActivePeer() {
    static const QSet<QString> s{"call_answer", "call_ice", "call_video_state", "call_reject", "call_busy", "call_cancel", "call_end"};
    return s;
}

const char *stateName(CallState s) {
    switch (s) {
    case CallState::Idle: return "IDLE";
    case CallState::OutgoingRinging: return "OUTGOING_RINGING";
    case CallState::IncomingRinging: return "INCOMING_RINGING";
    case CallState::Connected: return "CONNECTED";
    }
    return "?";
}

/// Шаг WebRTC с ограничением времени: зависший движок не держит звонок вечно.
/// Состояние общее (shared_ptr): по таймауту ждущий уходит, а шаг дописывает результат в живой объект.
template <typename T>
Task<T> withStepTimeout(QString status, Task<T> task) {
    struct State {
        std::optional<T> result;
        std::exception_ptr error;
        Deferred<bool> done;
    };
    auto st = std::make_shared<State>();
    spawn([](Task<T> t, std::shared_ptr<State> s) -> Task<void> {
        try {
            s->result.emplace(co_await t);
        } catch (...) {
            s->error = std::current_exception();
        }
        s->done.resolve(true);
    }(std::move(task), st));
    if (!(co_await st->done.waitFor(StepTimeoutMs))) throw std::runtime_error(("WebRTC step " + status + " timed out").toStdString());
    if (st->error) std::rethrow_exception(st->error);
    co_return std::move(*st->result);
}

Task<void> withStepTimeoutVoid(QString status, Task<void> task) {
    struct State {
        std::exception_ptr error;
        Deferred<bool> done;
    };
    auto st = std::make_shared<State>();
    spawn([](Task<void> t, std::shared_ptr<State> s) -> Task<void> {
        try {
            co_await t;
        } catch (...) {
            s->error = std::current_exception();
        }
        s->done.resolve(true);
    }(std::move(task), st));
    if (!(co_await st->done.waitFor(StepTimeoutMs))) throw std::runtime_error(("WebRTC step " + status + " timed out").toStdString());
    if (st->error) std::rethrow_exception(st->error);
}
} // namespace

std::unique_ptr<RtcSession> NullRtcEngine::createSession(const QList<IceServer> &, RtcEvents) {
    throw std::runtime_error("звонки недоступны: сборка без WebRTC (GStreamer)");
}

CallManager::CallManager(WebSocketClient &ws, PeerMessenger &messenger, MessageRouter &router, ApiClient &api, Session &session, ChatStore &chats,
                         RtcEngine &engine, QObject *parent)
    : QObject(parent), ws_(ws), messenger_(messenger), router_(router), api_(api), session_(session), chats_(chats), engine_(engine) {}

void CallManager::start() {
    if (started_) return;
    started_ = true;
    connect(&ws_, &WebSocketClient::callSignalReceived, this, [this](const QJsonObject &envelope) {
        spawn(handleSignal(envelope), [](std::exception_ptr e) {
            try {
                std::rethrow_exception(e);
            } catch (const std::exception &err) {
                logError(QStringLiteral("CallManager handleSignal FAILED: %1").arg(what(err)));
            }
        });
    });
}

void CallManager::reportProblem(const QString &text) {
    const QString full = QStringLiteral("%1 (callId=%2 outgoing=%3 state=%4 status=%5 peer=%6)")
                             .arg(text, currentCallId_.value_or("-"))
                             .arg(isOutgoing_)
                             .arg(QLatin1String(stateName(state_)), status_, peer_ ? peer_->deviceId : QStringLiteral("-"));
    log("CallManager PROBLEM " + full);
    Q_EMIT problem(full);
}

void CallManager::setState(CallState s) {
    log(QStringLiteral("CallManager state %1 -> %2").arg(QLatin1String(stateName(state_)), QLatin1String(stateName(s))));
    state_ = s;
    Q_EMIT changed();
}

void CallManager::setStatus(const QString &s) {
    status_ = s;
    Q_EMIT changed();
}

void CallManager::resetMediaFlags() {
    micEnabled_ = true;
    videoEnabled_ = false;
    remoteVideoEnabled_ = false;
}

Task<void> CallManager::startCall(CallPeer peer) {
    if (state_ != CallState::Idle) co_return;
    log(QStringLiteral("CallManager startCall to=%1").arg(peer.deviceId));
    currentCallId_ = QUuid::createUuid().toString(QUuid::WithoutBraces);
    peer_ = peer;
    resetMediaFlags();
    remoteDescriptionSet_ = false;
    pendingCandidates_.clear();
    startedAt_ = now();
    connectedAt_.reset();
    isOutgoing_ = true;
    setState(CallState::OutgoingRinging);
    try {
        setStatus("call.securingConnection");
        if (!peer.login.isEmpty()) {
            const QString current = co_await messenger_.resolvePeerDeviceId(peer.login, peer.deviceId);
            if (current != peer.deviceId) {
                log(QStringLiteral("CallManager startCall: peer device changed %1 -> %2").arg(peer.deviceId, current));
                peer_->deviceId = current;
            }
        }
        RtcSession *session = co_await createSession();
        setStatus("call.enablingMic");
        Task<void> audio = session->startAudio(micEnabled_);
        co_await withStepTimeoutVoid("call.enablingMic", std::move(audio));
        setStatus("call.buildingOffer");
        Task<QString> makeOffer = session->createOffer();
        const QString offer = co_await withStepTimeout<QString>("call.buildingOffer", std::move(makeOffer));
        const QJsonObject payload{{"sdp", offer}};
        if (!(co_await send("call_offer", payload))) {
            log("CallManager startCall: offer not sent — no connection");
            reportProblem("outgoing call: offer not sent, no connection to server");
            startedAt_.reset();
            co_await endWithReason("call.noConnection");
            co_return;
        }
        co_await releaseLocalCandidates();
        setStatus("call.ringing");
        armRingTimeout();
    } catch (const std::exception &e) {
        logError(QStringLiteral("CallManager startCall FAILED: %1").arg(what(e)));
        reportProblem(QStringLiteral("outgoing call setup failed: %1").arg(what(e)));
        co_await resetLocal();
    }
}

Task<void> CallManager::acceptCall() {
    if (!pendingOfferSdp_ || accepting_ || state_ == CallState::Connected) {
        log(QStringLiteral("CallManager accept SKIP pendingOffer=%1 accepting=%2").arg(pendingOfferSdp_.has_value()).arg(accepting_));
        co_return;
    }
    accepting_ = true;
    const QString offer = *pendingOfferSdp_;
    bool failed = false;
    try {
        resetMediaFlags();
        setStatus("call.securingConnection");
        RtcSession *session = co_await createSession();
        Task<void> remote = session->setRemoteDescription("offer", offer);
        co_await withStepTimeoutVoid("call.securingConnection", std::move(remote));
        remoteDescriptionSet_ = true;
        co_await flushPendingCandidates();
        setStatus("call.enablingMic");
        Task<void> audio = session->startAudio(micEnabled_);
        co_await withStepTimeoutVoid("call.enablingMic", std::move(audio));
        setStatus("call.buildingAnswer");
        Task<QString> makeAnswer = session->createAnswer();
        const QString answer = co_await withStepTimeout<QString>("call.buildingAnswer", std::move(makeAnswer));
        const QJsonObject payload{{"sdp", answer}};
        co_await send("call_answer", payload);
        co_await releaseLocalCandidates();
        setStatus("call.connecting");
        setState(CallState::Connected);
    } catch (const std::exception &e) {
        logError(QStringLiteral("CallManager accept FAILED: %1").arg(what(e)));
        reportProblem(QStringLiteral("accept failed: %1").arg(what(e)));
        failed = true;
    }
    accepting_ = false;
    if (failed) {
        co_await send("call_end", QJsonObject());
        co_await resetLocal();
    }
}

Task<void> CallManager::declineCall() {
    if (state_ == CallState::Idle) co_return;
    co_await send("call_reject", QJsonObject());
    co_await resetLocal();
}

Task<void> CallManager::cancelCall() {
    if (state_ == CallState::Idle) co_return;
    co_await send("call_cancel", QJsonObject());
    co_await resetLocal();
}

Task<void> CallManager::endCall() {
    if (state_ == CallState::Idle) co_return;
    co_await send("call_end", QJsonObject());
    co_await resetLocal();
}

Task<void> CallManager::hangUp() {
    if (state_ == CallState::OutgoingRinging) co_await cancelCall();
    else co_await endCall();
}

Task<void> CallManager::toggleMic() {
    micEnabled_ = !micEnabled_;
    if (rtc_) rtc_->setMicEnabled(micEnabled_);
    Q_EMIT changed();
    co_return;
}

Task<void> CallManager::toggleVideo() {
    if (!rtc_) co_return;
    const bool enabled = !videoEnabled_;
    try {
        co_await rtc_->setVideoEnabled(enabled);
    } catch (const std::exception &e) {
        logError(QStringLiteral("CallManager toggleVideo FAILED: %1").arg(what(e)));
        co_return;
    }
    videoEnabled_ = enabled;
    Q_EMIT changed();
    const QJsonObject payload{{"enabled", enabled}};
    co_await send("call_video_state", payload);
}

void CallManager::setAudioDevice(bool input, const QString &id) {
    engine_.setPreferredAudioDevice(input, id);
    if (rtc_) rtc_->setAudioDevice(input, id);
}

Task<QList<IceServer>> CallManager::iceServers() {
    const IceServer stun{{Stun}, {}, {}};
    const auto token = session_.token();
    if (!token) co_return QList<IceServer>{stun};
    const auto creds = co_await api_.getTurnCredentials(*token);
    if (!creds) co_return QList<IceServer>{stun};
    QStringList urls;
    const QJsonValue u = creds->value("urls");
    if (u.isArray()) {
        for (const QJsonValue &v : u.toArray()) urls << v.toString();
    } else if (u.isString()) {
        urls << u.toString();
    }
    if (urls.isEmpty()) co_return QList<IceServer>{stun};
    co_return QList<IceServer>{stun, IceServer{urls, creds->value("username").toString(), creds->value("password").toString()}};
}

Task<RtcSession *> CallManager::createSession() {
    RtcEvents events;
    events.onIceCandidate = [this](QString candidate, QString mid, int index) {
        const QJsonObject payload{{"candidate", candidate}, {"sdpMid", mid.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(mid)}, {"sdpMLineIndex", index}};
        if (!localDescriptionSent_) {
            pendingLocalCandidates_ << payload;
            return;
        }
        spawn([](CallManager *self, QJsonObject p) -> Task<void> { co_await self->send("call_ice", p); }(this, payload));
    };
    events.onConnected = [this] {
        if (!connectedAt_) connectedAt_ = now();
        if (state_ != CallState::Connected && state_ != CallState::Idle) setState(CallState::Connected);
        Q_EMIT changed();
    };
    events.onFailed = [this] {
        spawn([](CallManager *self) -> Task<void> {
            log("CallManager connection FAILED — ending call");
            if (self->state_ == CallState::Idle) co_return;
            self->reportProblem(QStringLiteral("WebRTC connection failed, media %1").arg(self->connectedAt_ ? "was connected" : "never connected"));
            co_await self->send("call_end", QJsonObject());
            co_await self->resetLocal();
        }(this));
    };
    events.onRenegotiationNeeded = [this] {
        if (state_ == CallState::Connected) spawn(renegotiate());
    };
    events.onVideoFrame = [this](bool local, VideoFrame frame) { Q_EMIT videoFrame(local, frame); };
    localDescriptionSent_ = false;
    pendingLocalCandidates_.clear();
    const QList<IceServer> servers = co_await iceServers();
    log(QStringLiteral("CallManager createSession ice=%1").arg(servers.size()));
    rtc_ = engine_.createSession(servers, std::move(events));
    co_return rtc_.get();
}

Task<void> CallManager::renegotiate() {
    // просьбу о перезапросе шлют и webrtcbin, и движок сам (см. GstRtcEngine) — второй не нужен
    if (!rtc_ || makingOffer_ || rtc_->signalingState() != SignalingState::Stable) co_return;
    makingOffer_ = true;
    try {
        const QString offer = co_await rtc_->createOffer();
        const QJsonObject payload{{"sdp", offer}, {"renegotiation", true}};
        co_await send("call_offer", payload);
    } catch (const std::exception &e) {
        logError(QStringLiteral("CallManager renegotiate FAILED: %1").arg(what(e)));
    }
    makingOffer_ = false;
}

Task<void> CallManager::releaseLocalCandidates() {
    localDescriptionSent_ = true;
    const auto list = std::exchange(pendingLocalCandidates_, {});
    for (const QJsonObject &p : list) co_await send("call_ice", p);
}

Task<void> CallManager::flushPendingCandidates() {
    if (!rtc_) co_return;
    const auto list = pendingCandidates_;
    pendingCandidates_.clear();
    for (const auto &[c, mid, index] : list) co_await rtc_->addIceCandidate(c, mid, index);
}

Task<bool> CallManager::send(QString type, QJsonObject payload) {
    if (!peer_) co_return false;
    co_return co_await sendTo(peer_->deviceId, type, payload, currentCallId_);
}

Task<bool> CallManager::sendTo(QString toDeviceId, QString type, QJsonObject payload, std::optional<QString> callId) {
    payload.insert("type", type);
    QJsonObject envelope;
    try {
        envelope = co_await messenger_.sealCallSignal(toDeviceId, payload);
    } catch (const std::exception &e) {
        logError(QStringLiteral("CallManager encrypt-FAILED type=%1 to=%2: %3 — dropped").arg(type, toDeviceId, what(e)));
        co_return false;
    }
    envelope.insert("call_id", json::nullable(callId));
    co_return co_await ws_.sendCallSignal(toDeviceId, type, envelope);
}

Task<void> CallManager::handleSignal(QJsonObject envelope) {
    const QString type = envelope.value("type").toString();
    if (type.isEmpty()) co_return;
    if (type == "call_unavailable") {
        if (state_ != CallState::Idle) co_await resetLocal(true);
        co_return;
    }
    const auto sender = json::optString(envelope, "sender_device_id");
    if (!sender) {
        if (state_ == CallState::OutgoingRinging && (type == "call_reject" || type == "call_busy")) {
            const QString reason = type == "call_busy" ? QStringLiteral("call.busy") : QStringLiteral("call.declined");
            co_await endWithReason(reason);
        }
        co_return;
    }
    if (requiresActivePeer().contains(type) && (!peer_ || *sender != peer_->deviceId)) {
        log(QStringLiteral("CallManager IGNORING %1 from=%2").arg(type, *sender));
        co_return;
    }
    const auto payload = co_await router_.openCallSignal(*sender, envelope);
    if (!payload) {
        log(QStringLiteral("CallManager %1 from=%2: decrypt failed, dropped").arg(type, *sender));
        reportProblem(QStringLiteral("call signal %1 from=%2 could not be decrypted").arg(type, *sender));
        co_return;
    }
    const auto callId = json::optString(envelope, "call_id");
    log(QStringLiteral("CallManager signal %1 from=%2 state=%3").arg(type, *sender, QLatin1String(stateName(state_))));
    if (type == "call_offer") {
        co_await onOffer(*sender, callId, *payload);
    } else if (type == "call_answer") {
        const auto sdp = json::optString(*payload, "sdp");
        if (!sdp || !rtc_) co_return;
        if (rtc_->signalingState() != SignalingState::HaveLocalOffer) {
            log("CallManager call_answer while not have-local-offer — duplicate/stale, ignored");
            co_return;
        }
        co_await rtc_->setRemoteDescription("answer", *sdp);
        remoteDescriptionSet_ = true;
        co_await flushPendingCandidates();
    } else if (type == "call_ice") {
        const auto candidate = json::optString(*payload, "candidate");
        if (!candidate) co_return;
        const QString mid = payload->value("sdpMid").toString();
        const int index = int(payload->value("sdpMLineIndex").toInteger());
        if (remoteDescriptionSet_ && rtc_) co_await rtc_->addIceCandidate(*candidate, mid, index);
        else pendingCandidates_ << std::tuple{*candidate, mid, index};
    } else if (type == "call_video_state") {
        remoteVideoEnabled_ = payload->value("enabled").toBool();
        Q_EMIT changed();
    } else if (type == "call_reject") {
        co_await endWithReason("call.declined");
    } else if (type == "call_busy") {
        co_await endWithReason("call.busy");
    } else if (type == "call_cancel" || type == "call_end") {
        co_await resetLocal();
    }
}

Task<void> CallManager::onOffer(QString sender, std::optional<QString> callId, QJsonObject payload) {
    const auto sdp = json::optString(payload, "sdp");
    if (!sdp) co_return;
    if (payload.value("renegotiation").toBool()) {
        if (!peer_ || sender != peer_->deviceId || !rtc_) co_return;
        const bool collision = makingOffer_ || rtc_->signalingState() != SignalingState::Stable;
        const bool polite = !isOutgoing_;
        if (collision && !polite) {
            log("CallManager renegotiation offer collision — impolite side, ignoring theirs");
            co_return;
        }
        try {
            if (collision) co_await rtc_->rollback();
            co_await rtc_->setRemoteDescription("offer", *sdp);
            const QString answer = co_await rtc_->createAnswer();
            const QJsonObject p{{"sdp", answer}};
            co_await send("call_answer", p);
        } catch (const std::exception &e) {
            logError(QStringLiteral("CallManager renegotiation FAILED: %1").arg(what(e)));
        }
        co_return;
    }
    if (state_ != CallState::Idle) {
        co_await sendTo(sender, "call_busy", QJsonObject(), callId);
        co_return;
    }
    currentCallId_ = callId;
    peer_ = knownPeer(sender);
    pendingOfferSdp_ = *sdp;
    startedAt_ = now();
    connectedAt_.reset();
    isOutgoing_ = false;
    remoteDescriptionSet_ = false;
    pendingCandidates_.clear();
    setState(CallState::IncomingRinging);
    armRingTimeout();
    Q_EMIT incomingCall(callId.value_or(QString()), peer_->login);
    spawn(resolvePeer());
}

void CallManager::armRingTimeout() { spawn(ringTimeout(currentCallId_, state_)); }

Task<void> CallManager::ringTimeout(std::optional<QString> callId, CallState ringing) {
    const int generation = ++ringGeneration_;
    co_await delay{ringing == CallState::OutgoingRinging ? RingTimeoutMs : RingTimeoutMs + 5000};
    if (generation != ringGeneration_ || state_ != ringing || currentCallId_ != callId) co_return;
    log(QStringLiteral("CallManager ring timeout state=%1").arg(QLatin1String(stateName(ringing))));
    if (ringing == CallState::OutgoingRinging) {
        co_await send("call_cancel", QJsonObject());
        setStatus("call.noAnswer");
        co_await delay{EndReasonDelayMs};
        co_await resetLocal(true);
    } else {
        co_await resetLocal();
    }
}

CallPeer CallManager::knownPeer(const QString &deviceId) {
    if (const auto owner = router_.knownOwner(deviceId)) return CallPeer{deviceId, owner->login, owner->accountId};
    for (const auto &c : chats_.knownPeers()) {
        if (c.lastKnownDeviceId == deviceId) return CallPeer{deviceId, c.peerLogin, c.lastKnownAccountId.value_or(QString())};
    }
    return CallPeer{deviceId, {}, {}};
}

Task<void> CallManager::resolvePeer() {
    if (!peer_ || !peer_->login.isEmpty()) co_return;
    const QString deviceId = peer_->deviceId;
    const auto token = session_.token();
    if (!token) co_return;
    const auto owner = co_await api_.getDeviceOwnerInfo(*token, deviceId);
    if (owner && peer_ && peer_->deviceId == deviceId) {
        peer_->login = owner->login;
        peer_->accountId = owner->accountId;
        Q_EMIT changed();
    }
}

Task<void> CallManager::endWithReason(QString reasonKey) {
    setStatus(reasonKey);
    co_await delay{EndReasonDelayMs};
    co_await resetLocal();
}

Task<void> CallManager::resetLocal(bool peerWasUnavailable) {
    if (state_ == CallState::Idle && !rtc_) co_return;
    if (state_ == CallState::Connected && !connectedAt_) reportProblem("call ended before media connected");
    ++ringGeneration_;
    co_await logCall(peerWasUnavailable);
    if (rtc_) rtc_->close();
    rtc_.reset();
    pendingOfferSdp_.reset();
    remoteDescriptionSet_ = false;
    pendingCandidates_.clear();
    pendingLocalCandidates_.clear();
    localDescriptionSent_ = false;
    currentCallId_.reset();
    resetMediaFlags();
    peer_.reset();
    status_.clear();
    connectedAt_.reset();
    setState(CallState::Idle);
}

Task<void> CallManager::logCall(bool peerWasUnavailable) {
    if (!peer_ || !startedAt_) co_return;
    const QString peerDeviceId = peer_->deviceId;
    const qint64 started = *startedAt_;
    startedAt_.reset();
    const auto connected = connectedAt_;
    const QString outcome = connected ? "answered" : isOutgoing_ ? "no_answer" : "missed";
    const auto callId = currentCallId_;
    try {
        const auto token = session_.token();
        if (!token) co_return;
        const auto owner = co_await api_.getDeviceOwnerInfo(*token, peerDeviceId);
        if (!owner) co_return;
        chats_.addCallLog(owner->login, isOutgoing_ ? "outgoing" : "incoming", outcome, started,
                          connected ? std::optional((now() - *connected) / 1000) : std::nullopt, owner->accountId, false, callId);
        if (peerWasUnavailable && isOutgoing_) {
            const InnerMessage missed = InnerMessage::missedCall(started, callId);
            co_await messenger_.send(peerDeviceId, missed, std::nullopt, false, false);
        }
    } catch (const std::exception &e) {
        log(QStringLiteral("CallManager call log FAILED: %1").arg(what(e)));
    }
}

} // namespace osh
