#pragma once

// Фасад ядра (как OshinobuCore.kt + ChatService/ChatActions): все хранилища и
// сервисы, вход/регистрация, сессия, отправка и действия с чатами. Приложение
// (Qt Quick) работает только через него.

#include "net/ApiClient.h"
#include "net/WebSocketClient.h"
#include "service/Calls.h"
#include "service/Extras.h"
#include "service/Infra.h"
#include "service/Media.h"
#include "service/MessageRouter.h"
#include "service/Messaging.h"
#include "storage/ChatStore.h"
#include "storage/Stores.h"

#include <QObject>
#include <memory>

namespace osh {

/// Собеседник для отправки.
struct ChatPeer {
    QString login;
    QString accountId;
    QString deviceId;
};

struct OutgoingFile {
    QString path;
    bool isFile = false;
    bool isVideo = false;
    QString name;
};

class Core : public QObject {
    Q_OBJECT
public:
    static constexpr qint64 MaxAttachmentBytes = 500LL * 1024 * 1024;

    /// [rtcEngine] — медиа звонков (нет — звонки недоступны).
    Core(AppDirs dirs, std::unique_ptr<SecureStore> secure, std::unique_ptr<Prefs> prefs, RouterHost &host,
         std::unique_ptr<RtcEngine> rtcEngine = nullptr, QString baseUrl = QStringLiteral("https://ee2e.oshino.space"), QObject *parent = nullptr);
    ~Core() override;

    AppDirs dirs;
    std::unique_ptr<SecureStore> secure;
    std::unique_ptr<Prefs> prefs;
    ApiClient api;
    WebSocketClient ws;
    Session session;
    KeyStore keys;
    SessionStore sessions;
    PeerAccountStore peerAccounts;
    PeerIdentityStore peerIdentities;
    SendQueueStore sendQueueStore;
    ChunkedUploadSessionStore chunkedSessions;
    MediaFiles media;
    AppLockStore appLock;
    ChatStore chats;
    KeyedMutex sendLock;
    AckRegistry acks;
    SendQueueProcessor sendQueue;
    PeerMessenger messenger;
    MessageRouter router;
    DeviceSetup deviceSetup;
    MediaUploader uploader;
    MediaDownloadManager downloads;
    Stickers stickers;
    Avatars avatars;
    Wallpapers wallpapers;
    std::unique_ptr<RtcEngine> rtcEngine;
    CallManager calls;

    bool sessionActive() const { return sessionActive_; }
    std::optional<MyAccountInfo> myAccount() const { return myAccount_; }

    // вход и сессия
    /// Регистрация: возвращает otpauth://-ссылку для аутентификатора.
    Task<QString> registerAccount(QString login, QString password, QString inviteCode);
    Task<void> login(QString login, QString password, QString totpCode);
    /// Поднять сохранённую сессию; false — входа нет или сервер его не признаёт.
    Task<bool> resumeSession();
    Task<void> startSession();
    Task<void> logout();
    void signOutLocally();
    Task<bool> deleteAccount();
    Task<void> reloadMyAccount();

    // чаты
    ChatPeer peerOf(const ChatSummary &chat) const;
    /// Открыть чат по логину (поиск): устройство собеседника и запись в списке.
    Task<ChatSummary> openChat(QString login);
    Task<void> refreshPeer(QString peerLogin);
    Task<void> sendText(ChatPeer peer, QString text, std::optional<StoredMessage> replyTo = std::nullopt);
    Task<void> sendSticker(ChatPeer peer, StickerInfo sticker, std::optional<StoredMessage> replyTo = std::nullopt);
    /// Файлы больше 500 МБ не отправляются — возвращаются.
    Task<QList<OutgoingFile>> sendMedia(ChatPeer peer, QList<OutgoingFile> files, QString caption);
    /// Голосовое или видео-кружок (как sendRecorded на Android): запись — в постоянную папку,
    /// пузырь — сразу; [preview] — миниатюра своего кружка (JPEG), у голосового пусто.
    Task<void> sendRecorded(ChatPeer peer, QString recording, qint64 durationMs, bool videoNote, QString preview = {});
    Task<void> retry(ChatPeer peer, StoredMessage m);
    void cancelOutgoing(const QString &peerLogin, const QStringList &messageIds);
    Task<void> editText(ChatPeer peer, QString messageId, QString text);
    Task<void> react(ChatPeer peer, QString messageId, std::optional<QString> emoji);
    Task<void> setPinned(ChatPeer peer, QString messageId, bool pinned);
    Task<void> deleteMessages(ChatPeer peer, QStringList ids, bool forPeer);
    Task<void> forwardText(ChatPeer peer, QString text);
    Task<void> sendReadReceipts(ChatPeer peer);
    Task<void> clearOrDelete(ChatSummary chat, bool deleteChat, bool forPeer);
    Task<void> setMuted(ChatSummary chat, bool muted);
    Task<void> setBlocked(ChatSummary chat, bool blocked);
    Task<void> resetSession(ChatPeer peer);
    void purgeMedia(const QList<StoredMessage> &messages);
    /// Свои вложения, которые грузятся сейчас (message_id).
    QSet<QString> activeUploads() const;
    std::optional<double> uploadProgress(const QString &messageId) const;

    // отчёты в feedback
    void reportProblem(const QString &kind, const QString &summary);

Q_SIGNALS:
    void sessionActiveChanged(bool active);
    void myAccountChanged();
    void signedOut();
    void uploadProgressChanged(const QString &messageId, double percent);

private:
    Task<void> sendNetwork(ChatPeer peer, InnerMessage inner);
    Task<void> uploadAndSend(ChatPeer peer, QList<std::pair<OutgoingFile, QString>> items, std::optional<QString> groupId,
                             std::optional<QString> caption, std::optional<QString> textMessageId);
    Task<void> uploadRecorded(ChatPeer peer, QString messageId, QString path, qint64 size, qint64 durationMs, bool videoNote);
    Task<void> syncFromServer(QString token);
    Task<void> syncBlocked(QString token);
    void failOrphanedSending();
    void setUploadProgress(const QString &messageId, std::optional<double> pct);

    bool sessionActive_ = false;
    bool serverSyncWired_ = false;
    std::optional<MyAccountInfo> myAccount_;
    QSet<QString> uploading_;
    QHash<QString, double> uploadProgress_;
    QSet<QString> receiptsInFlight_;
    QSet<QString> cancelledUploads_;
};

} // namespace osh
