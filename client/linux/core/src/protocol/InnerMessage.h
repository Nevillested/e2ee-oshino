#pragma once

// Открытый текст внутри зашифрованного конверта (как InnerMessage.kt). [body] —
// строка (для 'text' — сам текст, для остальных типов — JSON-строка с полями
// типа). Это формат на проводе: его читают все установленные версии клиентов.

#include <QJsonArray>
#include <QJsonObject>
#include <QString>
#include <QStringList>
#include <optional>

namespace osh {

namespace MessageType {
inline const QString Text = QStringLiteral("text");
inline const QString Media = QStringLiteral("media");
inline const QString Voice = QStringLiteral("voice");
inline const QString VideoNote = QStringLiteral("video_note");
inline const QString Sticker = QStringLiteral("sticker");
inline const QString MediaGroup = QStringLiteral("media_group");
inline const QString CallMissed = QStringLiteral("call_missed");
inline const QString Reaction = QStringLiteral("reaction");
inline const QString Pin = QStringLiteral("pin");
inline const QString Edit = QStringLiteral("edit");
inline const QString Delete = QStringLiteral("delete");
inline const QString ClearChat = QStringLiteral("clear_chat");
inline const QString DeleteChat = QStringLiteral("delete_chat");
inline const QString ReadReceipt = QStringLiteral("read_receipt");
} // namespace MessageType

/// Ключ и параметры зашифрованного вложения (общая часть media/voice/video_note).
struct MediaRef {
    QString mediaId;
    QString keyBase64;
    /// nonce/mac — только у НЕчанковых файлов (целиком одним AES-GCM).
    std::optional<QString> nonceBase64;
    std::optional<QString> macBase64;
    qint64 fileSize = 0;
    bool chunked = false;
};

struct InnerMessage {
    QString messageId;
    QString type;
    qint64 sentAt = 0;
    QString body;
    std::optional<QString> groupId;
    std::optional<QString> replyToMessageId;
    std::optional<QString> replyToPreview;

    bool operator==(const InnerMessage &) const = default;

    QString encode() const;
    /// body как JSON-объект — для всех типов, кроме 'text'.
    QJsonObject bodyJson() const;
    /// Неверный JSON или нет обязательных полей — std::runtime_error.
    static InnerMessage decode(const QString &raw);

    static InnerMessage text(const QString &body, std::optional<QString> replyTo = std::nullopt, std::optional<QString> replyPreview = std::nullopt);
    static InnerMessage media(const MediaRef &ref, const QString &fileName, bool isFile = false, bool isVideo = false, bool spoiler = false,
                              std::optional<QString> messageId = std::nullopt, std::optional<QString> replyTo = std::nullopt,
                              std::optional<QString> replyPreview = std::nullopt);
    /// Стикер — только его id; файл получатель берёт из пака на сервере.
    static InnerMessage sticker(const QString &stickerId, std::optional<QString> messageId = std::nullopt,
                                std::optional<QString> replyTo = std::nullopt, std::optional<QString> replyPreview = std::nullopt);
    static InnerMessage voice(const MediaRef &ref, qint64 durationMs, std::optional<QString> messageId = std::nullopt,
                              std::optional<QString> replyTo = std::nullopt, std::optional<QString> replyPreview = std::nullopt);
    static InnerMessage videoNote(const MediaRef &ref, qint64 durationMs, std::optional<QString> messageId = std::nullopt,
                                  std::optional<QString> replyTo = std::nullopt, std::optional<QString> replyPreview = std::nullopt);
    /// [files] — по объекту на файл, в том же виде, что body у 'media'.
    static InnerMessage mediaGroup(const QString &groupId, const QJsonArray &files, std::optional<QString> caption = std::nullopt,
                                   std::optional<QString> textMessageId = std::nullopt, std::optional<QString> messageId = std::nullopt);
    static InnerMessage missedCall(qint64 calledAt, std::optional<QString> callId);
    /// emoji = nullopt — снять реакцию.
    static InnerMessage reaction(const QString &targetMessageId, std::optional<QString> emoji);
    static InnerMessage pin(const QString &targetMessageId, bool pinned);
    static InnerMessage edit(const QString &targetMessageId, const QString &newText);
    static InnerMessage remove(const QStringList &targetMessageIds);
    static InnerMessage clearChat();
    static InnerMessage deleteChat();
    static InnerMessage readReceipt(const QStringList &targetMessageIds);
};

} // namespace osh
