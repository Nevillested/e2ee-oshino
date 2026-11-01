#include "protocol/InnerMessage.h"

#include "support/Json.h"

#include <QDateTime>
#include <QUuid>

namespace osh {

namespace {

QString newId() { return QUuid::createUuid().toString(QUuid::WithoutBraces); }
qint64 now() { return QDateTime::currentMSecsSinceEpoch(); }

QJsonObject mediaFields(const MediaRef &ref) {
    return {
        {"media_id", ref.mediaId},
        {"key", ref.keyBase64},
        {"nonce", json::nullable(ref.nonceBase64)},
        {"mac", json::nullable(ref.macBase64)},
        {"file_size", ref.fileSize},
        {"chunked", ref.chunked},
    };
}

InnerMessage make(QString id, const QString &type, QString body, std::optional<QString> replyTo = std::nullopt,
                  std::optional<QString> replyPreview = std::nullopt, std::optional<QString> groupId = std::nullopt) {
    return InnerMessage{std::move(id), type, now(), std::move(body), std::move(groupId), std::move(replyTo), std::move(replyPreview)};
}

InnerMessage recorded(const QString &type, const MediaRef &ref, qint64 durationMs, std::optional<QString> messageId,
                      std::optional<QString> replyTo, std::optional<QString> replyPreview) {
    QJsonObject body = mediaFields(ref);
    body.insert("duration_ms", durationMs);
    return make(messageId.value_or(newId()), type, json::compact(body), std::move(replyTo), std::move(replyPreview));
}

} // namespace

QString InnerMessage::encode() const {
    return json::compact(QJsonObject{
        {"message_id", messageId},
        {"type", type},
        {"sent_at", sentAt},
        {"body", body},
        {"group_id", json::nullable(groupId)},
        {"reply_to_id", json::nullable(replyToMessageId)},
        {"reply_to_preview", json::nullable(replyToPreview)},
    });
}

QJsonObject InnerMessage::bodyJson() const { return json::parseObject(body); }

InnerMessage InnerMessage::decode(const QString &raw) {
    const QJsonObject o = json::parseObject(raw);
    const QJsonValue sentAt = o.value(QLatin1String("sent_at"));
    if (!sentAt.isDouble()) throw std::runtime_error("в сообщении нет sent_at");
    return InnerMessage{
        json::string(o, "message_id"),
        json::string(o, "type"),
        sentAt.toInteger(),
        json::string(o, "body"),
        json::optString(o, "group_id"),
        json::optString(o, "reply_to_id"),
        json::optString(o, "reply_to_preview"),
    };
}

InnerMessage InnerMessage::text(const QString &body, std::optional<QString> replyTo, std::optional<QString> replyPreview) {
    return make(newId(), MessageType::Text, body, std::move(replyTo), std::move(replyPreview));
}

InnerMessage InnerMessage::media(const MediaRef &ref, const QString &fileName, bool isFile, bool isVideo, bool spoiler,
                                 std::optional<QString> messageId, std::optional<QString> replyTo, std::optional<QString> replyPreview) {
    QJsonObject body = mediaFields(ref);
    body.insert("file_name", fileName);
    body.insert("is_file", isFile);
    body.insert("is_video", isVideo);
    body.insert("spoiler", spoiler);
    return make(messageId.value_or(newId()), MessageType::Media, json::compact(body), std::move(replyTo), std::move(replyPreview));
}

InnerMessage InnerMessage::sticker(const QString &stickerId, std::optional<QString> messageId, std::optional<QString> replyTo,
                                   std::optional<QString> replyPreview) {
    return make(messageId.value_or(newId()), MessageType::Sticker, json::compact(QJsonObject{{"sticker_id", stickerId}}), std::move(replyTo),
                std::move(replyPreview));
}

InnerMessage InnerMessage::voice(const MediaRef &ref, qint64 durationMs, std::optional<QString> messageId, std::optional<QString> replyTo,
                                 std::optional<QString> replyPreview) {
    return recorded(MessageType::Voice, ref, durationMs, std::move(messageId), std::move(replyTo), std::move(replyPreview));
}

InnerMessage InnerMessage::videoNote(const MediaRef &ref, qint64 durationMs, std::optional<QString> messageId, std::optional<QString> replyTo,
                                     std::optional<QString> replyPreview) {
    return recorded(MessageType::VideoNote, ref, durationMs, std::move(messageId), std::move(replyTo), std::move(replyPreview));
}

InnerMessage InnerMessage::mediaGroup(const QString &groupId, const QJsonArray &files, std::optional<QString> caption,
                                      std::optional<QString> textMessageId, std::optional<QString> messageId) {
    const QJsonObject body{{"caption", json::nullable(caption)}, {"text_message_id", json::nullable(textMessageId)}, {"files", files}};
    return make(messageId.value_or(newId()), MessageType::MediaGroup, json::compact(body), std::nullopt, std::nullopt, groupId);
}

InnerMessage InnerMessage::missedCall(qint64 calledAt, std::optional<QString> callId) {
    return make(newId(), MessageType::CallMissed, json::compact(QJsonObject{{"called_at", calledAt}, {"call_id", json::nullable(callId)}}));
}

InnerMessage InnerMessage::reaction(const QString &targetMessageId, std::optional<QString> emoji) {
    return make(newId(), MessageType::Reaction, json::compact(QJsonObject{{"target_id", targetMessageId}, {"emoji", json::nullable(emoji)}}));
}

InnerMessage InnerMessage::pin(const QString &targetMessageId, bool pinned) {
    return make(newId(), MessageType::Pin, json::compact(QJsonObject{{"target_id", targetMessageId}, {"pinned", pinned}}));
}

InnerMessage InnerMessage::edit(const QString &targetMessageId, const QString &newText) {
    return make(newId(), MessageType::Edit, json::compact(QJsonObject{{"target_id", targetMessageId}, {"text", newText}}));
}

InnerMessage InnerMessage::remove(const QStringList &targetMessageIds) {
    return make(newId(), MessageType::Delete, json::compact(QJsonObject{{"target_ids", QJsonArray::fromStringList(targetMessageIds)}}));
}

InnerMessage InnerMessage::clearChat() { return make(newId(), MessageType::ClearChat, QStringLiteral("{}")); }

InnerMessage InnerMessage::deleteChat() { return make(newId(), MessageType::DeleteChat, QStringLiteral("{}")); }

InnerMessage InnerMessage::readReceipt(const QStringList &targetMessageIds) {
    return make(newId(), MessageType::ReadReceipt, json::compact(QJsonObject{{"target_ids", QJsonArray::fromStringList(targetMessageIds)}}));
}

} // namespace osh
