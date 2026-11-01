#pragma once

// Звонки (как CallManager.kt): сигнальный протокол поверх зашифрованного канала
// (сигналы шифруются той же сессией ratchet, что и сообщения), медиа — WebRTC за
// [RtcEngine]. Perfect negotiation при перезапросе, «занято», 2 мин дозвона,
// таймаут каждого шага, запись в историю, «пропущенный» собеседнику, отчёт о
// проблеме (call_problem).

#include "net/ApiClient.h"
#include "net/WebSocketClient.h"
#include "service/MessageRouter.h"
#include "service/Messaging.h"
#include "storage/ChatStore.h"

#include <QObject>
#include <functional>
#include <memory>

namespace osh {

enum class CallState { Idle, OutgoingRinging, IncomingRinging, Connected };
enum class SignalingState { Stable, HaveLocalOffer, Other };

struct IceServer {
    QStringList urls;
    QString username;
    QString credential;
};

/// Устройство звука: [id] — стабильное имя для настроек, [name] — для людей.
struct AudioDevice {
    QString id;
    QString name;
    bool isDefault = false;
};

/// Кадр видео RGBA (своя камера или собеседник) — для экрана звонка.
struct VideoFrame {
    QByteArray rgba;
    int width = 0;
    int height = 0;
};

/// События медиасессии (из потока движка — возобновляются в главном).
struct RtcEvents {
    std::function<void(QString candidate, QString sdpMid, int sdpMLineIndex)> onIceCandidate;
    std::function<void()> onConnected;
    std::function<void()> onFailed;
    std::function<void()> onRenegotiationNeeded;
    std::function<void(bool local, VideoFrame frame)> onVideoFrame;
};

class RtcSession {
public:
    virtual ~RtcSession() = default;
    virtual SignalingState signalingState() const = 0;
    virtual Task<QString> createOffer() = 0;
    virtual Task<QString> createAnswer() = 0;
    virtual Task<void> setRemoteDescription(QString type, QString sdp) = 0;
    virtual Task<void> rollback() = 0;
    virtual Task<void> addIceCandidate(QString candidate, QString sdpMid, int sdpMLineIndex) = 0;
    virtual Task<void> startAudio(bool micEnabled) = 0;
    virtual void setMicEnabled(bool enabled) = 0;
    virtual Task<void> setVideoEnabled(bool enabled) = 0;
    /// Сменить микрофон / вывод посреди разговора (пустой id — системный по умолчанию).
    virtual void setAudioDevice(bool input, const QString &id) {
        Q_UNUSED(input)
        Q_UNUSED(id)
    }
    virtual void close() = 0;
};

class RtcEngine {
public:
    virtual ~RtcEngine() = default;
    virtual std::unique_ptr<RtcSession> createSession(const QList<IceServer> &servers, RtcEvents events) = 0;
    virtual QList<AudioDevice> audioDevices(bool input) {
        Q_UNUSED(input)
        return {};
    }
    /// Устройство для следующих звонков (текущий меняет RtcSession::setAudioDevice).
    virtual void setPreferredAudioDevice(bool input, const QString &id) {
        Q_UNUSED(input)
        Q_UNUSED(id)
    }
    virtual bool hasCamera() { return false; }
};

struct CallPeer {
    QString deviceId;
    QString login;
    QString accountId;
};

class CallManager : public QObject {
    Q_OBJECT
public:
    CallManager(WebSocketClient &ws, PeerMessenger &messenger, MessageRouter &router, ApiClient &api, Session &session, ChatStore &chats,
                RtcEngine &engine, QObject *parent = nullptr);

    void start();
    CallState state() const { return state_; }
    QString status() const { return status_; }
    std::optional<CallPeer> peer() const { return peer_; }
    std::optional<qint64> connectedAt() const { return connectedAt_; }
    bool micEnabled() const { return micEnabled_; }
    bool videoEnabled() const { return videoEnabled_; }
    bool remoteVideoEnabled() const { return remoteVideoEnabled_; }

    Task<void> startCall(CallPeer peer);
    Task<void> acceptCall();
    Task<void> declineCall();
    Task<void> hangUp();
    Task<void> toggleMic();
    Task<void> toggleVideo();
    /// Выбор микрофона / вывода: запоминается в движке и применяется к идущему звонку.
    void setAudioDevice(bool input, const QString &id);

Q_SIGNALS:
    void changed();
    void incomingCall(const QString &callId, const QString &peerLogin);
    void problem(const QString &text);
    void videoFrame(bool local, const osh::VideoFrame &frame);

private:
    Task<void> handleSignal(QJsonObject envelope);
    Task<void> onOffer(QString sender, std::optional<QString> callId, QJsonObject payload);
    Task<bool> send(QString type, QJsonObject payload);
    Task<void> releaseLocalCandidates();
    Task<bool> sendTo(QString toDeviceId, QString type, QJsonObject payload, std::optional<QString> callId);
    Task<RtcSession *> createSession();
    Task<QList<IceServer>> iceServers();
    Task<void> renegotiate();
    Task<void> flushPendingCandidates();
    Task<void> endWithReason(QString reasonKey);
    Task<void> resetLocal(bool peerWasUnavailable = false);
    Task<void> logCall(bool peerWasUnavailable);
    Task<void> resolvePeer();
    Task<void> ringTimeout(std::optional<QString> callId, CallState ringing);
    Task<void> cancelCall();
    Task<void> endCall();
    void armRingTimeout();
    void reportProblem(const QString &what);
    void setState(CallState s);
    void setStatus(const QString &s);
    void resetMediaFlags();
    CallPeer knownPeer(const QString &deviceId);

    WebSocketClient &ws_;
    PeerMessenger &messenger_;
    MessageRouter &router_;
    ApiClient &api_;
    Session &session_;
    ChatStore &chats_;
    RtcEngine &engine_;

    CallState state_ = CallState::Idle;
    QString status_;
    std::optional<CallPeer> peer_;
    std::optional<qint64> connectedAt_;
    bool micEnabled_ = true, videoEnabled_ = false, remoteVideoEnabled_ = false;
    std::unique_ptr<RtcSession> rtc_;
    std::optional<QString> currentCallId_;
    std::optional<QString> pendingOfferSdp_;
    bool remoteDescriptionSet_ = false;
    QList<std::tuple<QString, QString, int>> pendingCandidates_;
    /// Свои кандидаты — только после offer/answer: webrtcbin выдаёт их раньше, чем offer уходит,
    /// а Android игнорирует call_ice до call_offer.
    bool localDescriptionSent_ = false;
    QList<QJsonObject> pendingLocalCandidates_;
    std::optional<qint64> startedAt_;
    bool isOutgoing_ = false, makingOffer_ = false, accepting_ = false, started_ = false;
    int ringGeneration_ = 0;
};

/// Движок без медиа (сборка без GStreamer): сессию создать нельзя — звонок честно не состоится.
class NullRtcEngine : public RtcEngine {
public:
    std::unique_ptr<RtcSession> createSession(const QList<IceServer> &, RtcEvents) override;
};

} // namespace osh
