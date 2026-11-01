#include "storage/StoredMessage.h"

#include "support/Json.h"

namespace osh {

namespace {

QJsonValue opt(const std::optional<QString> &v) { return json::nullable(v); }
QJsonValue opt(const std::optional<qint64> &v) { return v ? QJsonValue(*v) : QJsonValue(QJsonValue::Null); }

std::optional<qint64> optLong(const QJsonObject &j, const char *name) {
    const QJsonValue v = j.value(QLatin1String(name));
    return v.isDouble() ? std::optional(v.toInteger()) : std::nullopt;
}

bool b(const QJsonObject &j, const char *name) { return j.value(QLatin1String(name)).toBool(); }

} // namespace

QJsonObject StoredMessage::toJson() const {
    QJsonObject o{
        {"id", messageId},
        {"text", text},
        {"is_mine", isMine},
        {"ts", timestamp},
        {"is_media", isMedia},
        {"is_file", isFile},
        {"is_video", isVideo},
        {"file_size", fileSize},
        {"chunked", chunked},
        {"media_id", opt(mediaId)},
        {"media_key", opt(mediaKeyBase64)},
        {"media_nonce", opt(mediaNonceBase64)},
        {"media_mac", opt(mediaMacBase64)},
        {"file_name", opt(fileName)},
        {"is_spoiler", isSpoiler},
        {"is_voice", isVoice},
        {"is_video_note", isVideoNote},
        {"duration_ms", opt(durationMs)},
        {"status", status},
        {"step", opt(processingStep)},
        {"local_preview", opt(localPreviewPath)},
        {"local_source", opt(localSourcePath)},
        {"group_id", opt(groupId)},
        {"is_call_log", isCallLog},
        {"call_direction", opt(callDirection)},
        {"call_outcome", opt(callOutcome)},
        {"call_duration", opt(callDurationSeconds)},
        {"undecryptable", isUndecryptable},
        {"reply_to_id", opt(replyToMessageId)},
        {"reply_to_preview", opt(replyToPreview)},
        {"edited", edited},
        {"my_reaction", opt(myReaction)},
        {"peer_reaction", opt(peerReaction)},
        {"read_receipt_sent", readReceiptSent},
    };
    if (stickerId) o.insert("sticker_id", *stickerId);
    return o;
}

StoredMessage StoredMessage::fromJson(const QJsonObject &j) {
    StoredMessage m;
    m.messageId = j.value("id").toString();
    m.text = j.value("text").toString();
    m.isMine = b(j, "is_mine");
    m.timestamp = optLong(j, "ts").value_or(0);
    m.isMedia = b(j, "is_media");
    m.isFile = b(j, "is_file");
    m.isVideo = b(j, "is_video");
    m.fileSize = optLong(j, "file_size").value_or(0);
    m.chunked = b(j, "chunked");
    m.mediaId = json::optString(j, "media_id");
    m.mediaKeyBase64 = json::optString(j, "media_key");
    m.mediaNonceBase64 = json::optString(j, "media_nonce");
    m.mediaMacBase64 = json::optString(j, "media_mac");
    m.fileName = json::optString(j, "file_name");
    m.isSpoiler = b(j, "is_spoiler");
    m.isVoice = b(j, "is_voice");
    m.isVideoNote = b(j, "is_video_note");
    m.durationMs = optLong(j, "duration_ms");
    m.stickerId = json::optString(j, "sticker_id");
    m.status = json::optString(j, "status").value_or(MessageStatus::Sent);
    m.processingStep = json::optString(j, "step");
    m.localPreviewPath = json::optString(j, "local_preview");
    m.localSourcePath = json::optString(j, "local_source");
    m.groupId = json::optString(j, "group_id");
    m.isCallLog = b(j, "is_call_log");
    m.callDirection = json::optString(j, "call_direction");
    m.callOutcome = json::optString(j, "call_outcome");
    m.callDurationSeconds = optLong(j, "call_duration");
    m.isUndecryptable = b(j, "undecryptable");
    m.replyToMessageId = json::optString(j, "reply_to_id");
    m.replyToPreview = json::optString(j, "reply_to_preview");
    m.edited = b(j, "edited");
    m.myReaction = json::optString(j, "my_reaction");
    m.peerReaction = json::optString(j, "peer_reaction");
    m.readReceiptSent = b(j, "read_receipt_sent");
    return m;
}

QJsonObject ChatSummary::toJson() const {
    return {
        {"login", peerLogin},
        {"account_id", opt(lastKnownAccountId)},
        {"device_id", opt(lastKnownDeviceId)},
        {"last_message", lastMessage},
        {"last_ts", lastTimestamp},
        {"is_deleted", isDeleted},
        {"unread", unreadCount},
        {"pinned_message_id", opt(pinnedMessageId)},
        {"chat_pinned_at", opt(chatPinnedAt)},
        {"muted", muted},
        {"blocked_by_me", blockedByMe},
        {"blocking_me", blockingMe},
        {"last_is_mine", lastMessageIsMine},
        {"last_is_read", lastMessageIsRead},
    };
}

ChatSummary ChatSummary::fromJson(const QJsonObject &j) {
    ChatSummary c;
    c.peerLogin = j.value("login").toString();
    c.lastMessage = j.value("last_message").toString();
    c.lastTimestamp = optLong(j, "last_ts").value_or(0);
    c.lastKnownAccountId = json::optString(j, "account_id");
    c.lastKnownDeviceId = json::optString(j, "device_id");
    c.isDeleted = b(j, "is_deleted");
    c.unreadCount = int(optLong(j, "unread").value_or(0));
    c.pinnedMessageId = json::optString(j, "pinned_message_id");
    c.chatPinnedAt = optLong(j, "chat_pinned_at");
    c.muted = b(j, "muted");
    c.blockedByMe = b(j, "blocked_by_me");
    c.blockingMe = b(j, "blocking_me");
    c.lastMessageIsMine = b(j, "last_is_mine");
    c.lastMessageIsRead = b(j, "last_is_read");
    return c;
}

bool ChatSummary::listOrder(const ChatSummary &a, const ChatSummary &b) {
    if (a.chatPinnedAt && b.chatPinnedAt) return *a.chatPinnedAt > *b.chatPinnedAt;
    if (a.chatPinnedAt) return true;
    if (b.chatPinnedAt) return false;
    return a.lastTimestamp > b.lastTimestamp;
}

} // namespace osh
