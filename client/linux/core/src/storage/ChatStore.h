#pragma once

// История переписки и список чатов (как ChatStore.kt): те же операции и правила —
// дубли по message_id отбрасываются, удалённые помнятся «надгробиями» (опоздавшая
// копия не воскресает), превью в списке — маркер типа (…) или текст.
//
// На Linux — SQLite, содержимое каждой записи зашифровано AES-256-GCM ключом,
// выведенным из мастер-ключа хранилища. Чат целиком держится в памяти после
// первого обращения; запись — сразу в базу.

#include "storage/StoredMessage.h"

#include <QHash>
#include <QList>
#include <QObject>
#include <QSqlDatabase>
#include <QStringList>
#include <functional>
#include <optional>

namespace osh {

class ChatStore : public QObject {
    Q_OBJECT

public:
    /// [key] — 32 байта для шифрования записей; [path] пустой — база в памяти (тесты).
    ChatStore(const QString &path, QByteArray key, QObject *parent = nullptr);
    ~ChatStore() override;

    static const QString PreviewMark;
    static QString previewMarker(const StoredMessage &m);
    /// Маркер превью → текст; [tr] переводит ключ ("media.photo" → «Фото»).
    static QString decodePreview(const QString &raw, const std::function<QString(const QString &)> &tr);

    QList<StoredMessage> messages(const QString &peerLogin);
    std::optional<StoredMessage> message(const QString &peerLogin, const QString &messageId);
    void addMessage(const QString &peerLogin, const StoredMessage &m, const std::optional<QString> &accountId = std::nullopt,
                    bool incrementUnread = false);
    void addMessages(const QString &peerLogin, const QList<StoredMessage> &ms, const std::optional<QString> &accountId = std::nullopt,
                     bool incrementUnread = false);
    void addCallLog(const QString &peerLogin, const QString &direction, const QString &outcome, qint64 timestamp,
                    std::optional<qint64> durationSeconds = std::nullopt, const std::optional<QString> &accountId = std::nullopt,
                    bool incrementUnread = false, const std::optional<QString> &callId = std::nullopt);
    void addUndecryptableNotice(const QString &peerLogin, const QString &id, qint64 timestamp, const std::optional<QString> &accountId = std::nullopt,
                                bool incrementUnread = false);

    void updateMessageStatus(const QString &peerLogin, const QString &messageId, const QString &status);
    void markRetrying(const QString &peerLogin, const QString &messageId, const QString &step);
    void updateProcessingStep(const QString &peerLogin, const QString &messageId, const QString &step);
    void updateMediaInfo(const QString &peerLogin, const QString &messageId, const QString &mediaId, const QString &key,
                         const std::optional<QString> &nonce, const std::optional<QString> &mac);
    /// Произвольное изменение одного сообщения (true — нашлось).
    bool update(const QString &peerLogin, const QString &messageId, const std::function<void(StoredMessage &)> &fn);
    void setReaction(const QString &peerLogin, const QString &messageId, bool isMine, const std::optional<QString> &emoji);
    void editMessageText(const QString &peerLogin, const QString &messageId, const QString &text);
    void markMessagesRead(const QString &peerLogin, const QStringList &ids);
    void markReadReceiptsSent(const QString &peerLogin, const QStringList &ids);
    void deleteMessages(const QString &peerLogin, const QStringList &ids);
    void clearHistory(const QString &peerLogin);
    void removeChat(const QString &peerLogin);

    QList<ChatSummary> knownPeers();
    std::optional<ChatSummary> peer(const QString &peerLogin);
    /// Чат без сообщений (открыли по логину) — появляется в списке.
    void ensurePeer(const QString &peerLogin, const std::optional<QString> &accountId, const std::optional<QString> &deviceId);
    void setPinned(const QString &peerLogin, const std::optional<QString> &messageId);
    void setChatPinned(const QString &peerLogin, bool pinned);
    bool isChatMuted(const QString &peerLogin);
    void setChatMuted(const QString &peerLogin, bool muted);
    void syncMutedFromServer(const QSet<QString> &mutedAccountIds);
    void setChatBlockedByMe(const QString &peerLogin, bool blocked);
    void syncBlockedFromServer(const QSet<QString> &blockedByMe, const QSet<QString> &blockingMe);
    void clearUnread(const QString &peerLogin);
    void setPeerDeletedStatus(const QString &peerLogin, bool isDeleted);
    void setLastKnownDeviceId(const QString &peerLogin, const QString &deviceId);
    void setLastKnownAccountId(const QString &peerLogin, const QString &accountId);

    /// Свои сообщения «отправляется» во всех чатах (для «Передач» и повторов).
    QList<std::pair<QString, StoredMessage>> sendingMessages();
    void wipeAll();

Q_SIGNALS:
    /// Что-то поменялось (список чатов или переписка [peerLogin]).
    void changed(const QString &peerLogin);

private:
    QList<StoredMessage> &loaded(const QString &peerLogin);
    void writeMessage(const QString &peerLogin, const StoredMessage &m);
    void eraseMessages(const QString &peerLogin, const QStringList &ids);
    QStringList tombstones(const QString &peerLogin);
    void writeTombstones(const QString &peerLogin, const QStringList &ids);
    QList<ChatSummary> &peers();
    void writePeer(const ChatSummary &p);
    void erasePeer(const QString &peerLogin);
    bool updatePeer(const QString &peerLogin, const std::function<bool(ChatSummary &)> &fn);
    void touchPeer(const QString &peerLogin, const QString &preview, qint64 ts, const std::optional<QString> &accountId, bool incrementUnread,
                   bool isMine, bool isRead);
    void refreshLast(const QString &peerLogin);

    QByteArray seal(const QJsonObject &o) const;
    QJsonObject open(const QByteArray &blob) const;

    QString connection_;
    QByteArray key_;
    QHash<QString, QList<StoredMessage>> cache_;
    std::optional<QList<ChatSummary>> peers_;
};

} // namespace osh
