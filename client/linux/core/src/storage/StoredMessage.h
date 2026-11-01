#pragma once

// Сообщение в истории и запись чата в списке (как StoredMessage.kt). Имена полей
// JSON — как на Android.

#include <QJsonObject>
#include <QString>
#include <optional>

namespace osh {

namespace MessageStatus {
inline const QString Sending = QStringLiteral("sending");
inline const QString Queued = QStringLiteral("queued");
inline const QString Sent = QStringLiteral("sent");
inline const QString Read = QStringLiteral("read");
inline const QString Failed = QStringLiteral("failed");
} // namespace MessageStatus

struct StoredMessage {
    QString messageId;
    QString text;
    bool isMine = false;
    qint64 timestamp = 0;
    bool isMedia = false;
    bool isFile = false;
    bool isVideo = false;
    qint64 fileSize = 0;
    bool chunked = false;
    std::optional<QString> mediaId;
    std::optional<QString> mediaKeyBase64;
    std::optional<QString> mediaNonceBase64;
    std::optional<QString> mediaMacBase64;
    std::optional<QString> fileName;
    bool isSpoiler = false;
    bool isVoice = false;
    bool isVideoNote = false;
    std::optional<qint64> durationMs;
    std::optional<QString> stickerId;
    QString status = MessageStatus::Sent;
    std::optional<QString> processingStep;
    std::optional<QString> localPreviewPath;
    std::optional<QString> localSourcePath;
    std::optional<QString> groupId;
    bool isCallLog = false;
    std::optional<QString> callDirection; // outgoing | incoming
    std::optional<QString> callOutcome;   // answered | no_answer | missed
    std::optional<qint64> callDurationSeconds;
    bool isUndecryptable = false;
    std::optional<QString> replyToMessageId;
    std::optional<QString> replyToPreview;
    bool edited = false;
    std::optional<QString> myReaction;
    std::optional<QString> peerReaction;
    bool readReceiptSent = false;

    bool isSticker() const { return stickerId.has_value(); }
    QJsonObject toJson() const;
    static StoredMessage fromJson(const QJsonObject &j);
};

struct ChatSummary {
    QString peerLogin;
    QString lastMessage;
    qint64 lastTimestamp = 0;
    std::optional<QString> lastKnownAccountId;
    std::optional<QString> lastKnownDeviceId;
    bool isDeleted = false;
    int unreadCount = 0;
    std::optional<QString> pinnedMessageId;
    std::optional<qint64> chatPinnedAt;
    bool muted = false;
    bool blockedByMe = false;
    bool blockingMe = false;
    bool lastMessageIsMine = false;
    bool lastMessageIsRead = false;

    QJsonObject toJson() const;
    static ChatSummary fromJson(const QJsonObject &j);
    /// Порядок списка: закреплённые (новые закрепы выше), затем по времени последнего сообщения.
    static bool listOrder(const ChatSummary &a, const ChatSummary &b);
};

} // namespace osh
