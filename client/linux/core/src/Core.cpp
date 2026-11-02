#include "Core.h"

#include "crypto/FileCiphers.h"
#include "support/Json.h"
#include "support/Log.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSysInfo>
#include <QUuid>

namespace osh {

namespace {
QString newId() { return QUuid::createUuid().toString(QUuid::WithoutBraces); }
qint64 nowMs() { return QDateTime::currentMSecsSinceEpoch(); }
QString what(const std::exception &e) { return QString::fromUtf8(e.what()); }

/// Ключ шифрования базы чатов — из мастер-ключа хранилища (своя запись в нём).
QByteArray chatDbKey(SecureStore &secure) {
    auto stored = secure.read("chat_db_key");
    if (!stored) {
        stored = b64(randomBytes(32));
        secure.write("chat_db_key", *stored);
    }
    return unb64(*stored);
}
} // namespace

Core::Core(AppDirs d, std::unique_ptr<SecureStore> s, std::unique_ptr<Prefs> p, RouterHost &host, std::unique_ptr<RtcEngine> engine, QString baseUrl,
           QObject *parent)
    : QObject(parent), dirs(std::move(d)), secure(std::move(s)), prefs(std::move(p)), api(std::move(baseUrl)), ws(api, this), session(*prefs),
      keys(*secure), sessions(*secure), peerAccounts(*secure), peerIdentities(*secure), sendQueueStore(*secure), chunkedSessions(*secure),
      media(dirs), appLock(*secure), chats(dirs.data + "/chats.db", chatDbKey(*secure), this), acks(ws, this),
      sendQueue(sendQueueStore, ws, acks, chats, this), messenger(api, session, keys, sessions, peerAccounts, peerIdentities, chats, sendQueue, sendLock),
      router(ws, api, session, keys, sessions, peerAccounts, peerIdentities, chats, *prefs, sendQueue, sendLock, host,
             [this](const QList<StoredMessage> &ms) { purgeMedia(ms); }, this),
      deviceSetup(api, keys), uploader(api, chats, dirs, chunkedSessions, media), downloads(api, session, media, this),
      stickers(api, session, *secure, dirs, this), avatars(api, session, dirs, this), wallpapers(api, session, dirs, this),
      rtcEngine(engine ? std::move(engine) : std::make_unique<NullRtcEngine>()),
      calls(ws, messenger, router, api, session, chats, *rtcEngine, this) {
    setLogFile(dirs.data + "/log.txt");
    connect(&ws, &WebSocketClient::sessionInvalidated, this, [this] {
        log("Session invalidated by server — signing out");
        signOutLocally();
    });
    // проблема звонка — отчёт в feedback с журналом (как на Android)
    connect(&calls, &CallManager::problem, this, [this](const QString &text) { reportProblem("call_problem", text); });
}

Core::~Core() = default;

// ---------------- вход и сессия ----------------

Task<QString> Core::registerAccount(QString login, QString password, QString inviteCode) {
    co_return co_await api.registerAccount(login, password, inviteCode);
}

Task<void> Core::login(QString login, QString password, QString totpCode) {
    const LoginResult result = co_await api.login(login, password, totpCode);
    session.setToken(result.token);
    session.setLogin(login);
    prefs->setString("ui_locale_server", result.language);
    const auto me = co_await api.getMyAccountInfo(result.token);
    if (me) {
        session.setAccountId(me->accountId);
        myAccount_ = me;
        Q_EMIT myAccountChanged();
    }
    co_await startSession();
}

Task<bool> Core::resumeSession() {
    const auto token = session.token();
    if (!token || !keys.deviceId()) co_return false;
    if ((co_await api.checkSession(*token)) == std::optional(false)) {
        signOutLocally();
        co_return false;
    }
    try {
        co_await startSession();
    } catch (const std::exception &e) {
        logError(QStringLiteral("startSession failed: %1").arg(what(e)));
    }
    co_return true;
}

Task<void> Core::startSession() {
    const auto token = session.token();
    if (!token) co_return;
    co_await deviceSetup.ensureDeviceRegistered(*token);
    const auto deviceId = keys.deviceId();
    if (!deviceId) co_return;
    failOrphanedSending();
    router.start();
    calls.start();
    sendQueue.start();
    media.pruneStalePartials();
    stickers.load();
    ws.connectTo(*token, *deviceId);
    sessionActive_ = true;
    Q_EMIT sessionActiveChanged(true);
    spawn(deviceSetup.ensurePrekeysTopped(*token, *deviceId));
    spawn(syncFromServer(*token));
}

Task<void> Core::syncFromServer(QString token) {
    if (!serverSyncWired_) {
        serverSyncWired_ = true;
        connect(&ws, &WebSocketClient::statusChanged, this, [this](ConnectionStatus s) {
            if (s == ConnectionStatus::Connected) spawn(wallpapers.sync());
        });
        connect(&ws, &WebSocketClient::blockStatusChanged, this, [this] {
            if (const auto t = session.token()) spawn(syncBlocked(*t));
        });
        connect(&ws, &WebSocketClient::wallpaperChanged, this, [this](const QString &) { spawn(wallpapers.sync()); });
        connect(&ws, &WebSocketClient::profileChanged, this, [this](const QString &accountId, const QString &field) {
            log(QStringLiteral("Profile changed account=%1 field=%2 — refreshing").arg(accountId, field));
            avatars.invalidate(accountId);
        });
    }
    const QStringList muted = co_await api.getMutedChats(token);
    chats.syncMutedFromServer(QSet<QString>(muted.begin(), muted.end()));
    co_await syncBlocked(token);
    co_await reloadMyAccount();
    co_await stickers.sync();
    co_await wallpapers.sync();
}

Task<void> Core::syncBlocked(QString token) {
    const auto blocked = co_await api.getBlockedContacts(token);
    if (!blocked) co_return;
    chats.syncBlockedFromServer(QSet<QString>(blocked->blockedByMe.begin(), blocked->blockedByMe.end()),
                                QSet<QString>(blocked->blockingMe.begin(), blocked->blockingMe.end()));
}

Task<void> Core::reloadMyAccount() {
    const auto token = session.token();
    if (!token) co_return;
    if (const auto me = co_await api.getMyAccountInfo(*token)) {
        myAccount_ = me;
        session.setAccountId(me->accountId);
        Q_EMIT myAccountChanged();
    }
}

Task<void> Core::logout() {
    const auto token = session.token();
    const auto deviceId = keys.deviceId();
    if (token && deviceId) co_await api.unregisterPushToken(*token, *deviceId);
    signOutLocally();
}

void Core::signOutLocally() {
    sessionActive_ = false;
    ws.disconnectFromServer();
    session.setToken(std::nullopt);
    session.setLogin(std::nullopt);
    session.setAccountId(std::nullopt);
    // как на Android: ключи, сессии и переписка стираются — следующий вход станет новым устройством
    chats.wipeAll();
    keys.clearAll();
    chatDbKey(*secure);
    stickers.reset();
    wallpapers.reset();
    avatars.reset();
    media.clearCache();
    myAccount_.reset();
    Q_EMIT sessionActiveChanged(false);
    Q_EMIT signedOut();
}

Task<bool> Core::deleteAccount() {
    const auto token = session.token();
    if (!token) co_return false;
    bool ok = false;
    try {
        ok = co_await api.deleteAccount(*token);
    } catch (const std::exception &) {
    }
    if (ok) signOutLocally();
    co_return ok;
}

// ---------------- чаты ----------------

ChatPeer Core::peerOf(const ChatSummary &chat) const {
    return ChatPeer{chat.peerLogin, chat.lastKnownAccountId.value_or(QString()), chat.lastKnownDeviceId.value_or(QString())};
}

Task<ChatSummary> Core::openChat(QString login) {
    const auto token = session.token();
    if (!token) throw ApiError("error.notSignedIn");
    const AccountDevices devices = co_await api.getDevicesByLogin(*token, login);
    if (devices.devices.isEmpty()) throw ApiError("error.userHasNoDevices");
    const QString deviceId = devices.devices.first().value("device_id").toString();
    chats.ensurePeer(login, devices.accountId, deviceId);
    chats.setLastKnownDeviceId(login, deviceId);
    if (auto p = chats.peer(login)) co_return *p;
    ChatSummary fallback;
    fallback.peerLogin = login;
    fallback.lastKnownAccountId = devices.accountId;
    fallback.lastKnownDeviceId = deviceId;
    co_return fallback;
}

Task<void> Core::refreshPeer(QString peerLogin) {
    const auto token = session.token();
    if (!token) co_return;
    try {
        const AccountDevices devices = co_await api.getDevicesByLogin(*token, peerLogin);
        if (!devices.devices.isEmpty()) {
            chats.setLastKnownDeviceId(peerLogin, devices.devices.first().value("device_id").toString());
            chats.setLastKnownAccountId(peerLogin, devices.accountId);
            chats.setPeerDeletedStatus(peerLogin, false);
        }
    } catch (const ApiError &e) {
        if (e.key == "error.userNotFound") chats.setPeerDeletedStatus(peerLogin, true);
    } catch (const std::exception &) {
    }
}

Task<void> Core::sendNetwork(ChatPeer peer, InnerMessage inner) {
    try {
        co_await messenger.send(peer.deviceId, inner, peer.login);
    } catch (const std::exception &e) {
        logError(QStringLiteral("ChatService send FAILED (%1 %2) to=%3: %4").arg(inner.type, inner.messageId, peer.deviceId, what(e)));
        chats.updateMessageStatus(peer.login, inner.messageId, MessageStatus::Failed);
    }
}

Task<void> Core::sendText(ChatPeer peer, QString text, std::optional<StoredMessage> replyTo) {
    const InnerMessage inner = InnerMessage::text(text, replyTo ? std::optional(replyTo->messageId) : std::nullopt,
                                                  replyTo ? std::optional(replyTo->text.left(120)) : std::nullopt);
    StoredMessage m;
    m.messageId = inner.messageId;
    m.text = text;
    m.isMine = true;
    m.timestamp = inner.sentAt;
    m.status = MessageStatus::Sending;
    m.replyToMessageId = inner.replyToMessageId;
    m.replyToPreview = inner.replyToPreview;
    chats.addMessage(peer.login, m, peer.accountId);
    co_await sendNetwork(peer, inner);
}

Task<void> Core::sendSticker(ChatPeer peer, StickerInfo sticker, std::optional<StoredMessage> replyTo) {
    stickers.recordRecent(sticker);
    co_await sendStickerMessage(peer, sticker.id, replyTo);
}

Task<void> Core::sendStickerMessage(ChatPeer peer, QString stickerId, std::optional<StoredMessage> replyTo) {
    const InnerMessage inner = InnerMessage::sticker(stickerId, std::nullopt, replyTo ? std::optional(replyTo->messageId) : std::nullopt,
                                                     replyTo ? std::optional(replyTo->text.left(120)) : std::nullopt);
    StoredMessage m;
    m.messageId = inner.messageId;
    m.isMine = true;
    m.timestamp = inner.sentAt;
    m.stickerId = stickerId;
    m.status = MessageStatus::Sending;
    m.replyToMessageId = inner.replyToMessageId;
    m.replyToPreview = inner.replyToPreview;
    chats.addMessage(peer.login, m, peer.accountId);
    co_await sendNetwork(peer, inner);
}

Task<bool> Core::forward(ChatPeer target, QString sourcePeerLogin, QList<StoredMessage> source) {
    bool ok = true;
    qsizetype i = 0;
    while (i < source.size()) {
        // альбом (общий groupId) — одним куском, остальное — по одному
        QList<StoredMessage> group;
        const std::optional<QString> gid = source[i].groupId;
        if (!gid) {
            group << source[i++];
        } else {
            while (i < source.size() && source[i].groupId == gid) group << source[i++];
        }
        QList<StoredMessage> media;
        QString caption;
        for (const StoredMessage &m : group) {
            if (m.isMedia) media << m;
            else if (caption.isEmpty() && !m.text.isEmpty()) caption = m.text;
        }
        if (!media.isEmpty()) {
            try {
                co_await forwardMedia(target, sourcePeerLogin, media, caption);
            } catch (const std::exception &e) {
                logError(QStringLiteral("forward media FAILED: %1").arg(what(e)));
                ok = false;
            }
            continue;
        }
        for (const StoredMessage &m : group) {
            if (m.isCallLog || m.isUndecryptable) continue;
            if (m.stickerId) co_await sendStickerMessage(target, *m.stickerId, std::nullopt);
            else if (!m.text.isEmpty()) co_await sendText(target, m.text);
        }
    }
    co_return ok;
}

Task<void> Core::forwardMedia(ChatPeer target, QString sourcePeerLogin, QList<StoredMessage> media, QString caption) {
    if (media.size() == 1 && (media.first().isVoice || media.first().isVideoNote)) {
        const StoredMessage &m = media.first();
        const QString file = co_await localFileOf(sourcePeerLogin, m);
        // sendRecorded забирает запись себе (переносит) — отдаём копию
        const QString copy = dirs.temp + "/fwd_" + newId() + (m.isVideoNote ? ".mp4" : ".m4a");
        QDir().mkpath(dirs.temp);
        if (!QFile::copy(file, copy)) throw std::runtime_error("не скопировать вложение для пересылки");
        co_await sendRecorded(target, copy, m.durationMs.value_or(0), m.isVideoNote);
        co_return;
    }
    QList<OutgoingFile> files;
    for (const StoredMessage &m : media) {
        const QString file = co_await localFileOf(sourcePeerLogin, m);
        const QString name = m.fileName.value_or(m.isVideo ? QStringLiteral("video.mp4") : QStringLiteral("photo.jpg"));
        files << OutgoingFile{file, m.isFile, m.isVideo, name}; // sendMedia копирует сам
    }
    const QList<OutgoingFile> rejected = co_await sendMedia(target, files, caption);
    if (!rejected.isEmpty()) throw std::runtime_error("вложение больше 500 МБ");
}

Task<QString> Core::localFileOf(QString sourcePeerLogin, StoredMessage m) {
    if (m.localSourcePath && QFile::exists(*m.localSourcePath)) co_return *m.localSourcePath;
    const auto spec = DownloadSpec::of(m, sourcePeerLogin);
    if (!spec) throw std::runtime_error("у вложения нет ключа — не переслать");
    co_return co_await downloads.ensureDownloaded(*spec);
}

Task<QList<OutgoingFile>> Core::sendMedia(ChatPeer peer, QList<OutgoingFile> files, QString caption) {
    QList<OutgoingFile> accepted, rejected;
    for (const auto &f : files) (QFileInfo(f.path).size() <= MaxAttachmentBytes ? accepted : rejected) << f;
    if (accepted.isEmpty()) co_return rejected;
    const bool hasCaption = !caption.trimmed().isEmpty();
    // один файл без подписи — 'media'; иначе альбом 'media_group' (подпись — отдельное сообщение группы)
    const std::optional<QString> groupId = accepted.size() + (hasCaption ? 1 : 0) > 1 ? std::optional("grp_" + newId()) : std::nullopt;
    std::optional<QString> textMessageId;
    const qint64 ts = nowMs();
    if (hasCaption) {
        StoredMessage t;
        t.messageId = newId();
        t.text = caption;
        t.isMine = true;
        t.timestamp = ts;
        t.status = MessageStatus::Sending;
        t.groupId = groupId;
        textMessageId = t.messageId;
        chats.addMessage(peer.login, t, peer.accountId);
    }
    QList<std::pair<OutgoingFile, QString>> items;
    for (const auto &f : accepted) {
        // исходник — в своё хранилище: повтор отправки после перезапуска
        const QString id = newId();
        const QString dir = dirs.data + "/outgoing";
        QDir().mkpath(dir);
        const QString suffix = QFileInfo(f.name).suffix();
        const QString kept = dir + "/" + id + (suffix.isEmpty() ? QString() : "." + suffix);
        QFile::copy(f.path, kept);
        const qint64 size = QFileInfo(kept).size();
        StoredMessage m;
        m.messageId = id;
        m.isMine = true;
        m.timestamp = ts;
        m.isMedia = true;
        m.isFile = f.isFile;
        m.isVideo = f.isVideo;
        m.fileSize = size;
        m.chunked = size > StreamingFileCipher::StreamingThresholdBytes;
        m.fileName = f.name;
        m.status = MessageStatus::Sending;
        m.processingStep = UploadStep::Queued;
        m.localPreviewPath = (f.isFile || f.isVideo) ? std::nullopt : std::optional(kept);
        m.localSourcePath = kept;
        m.groupId = groupId;
        chats.addMessage(peer.login, m, peer.accountId);
        OutgoingFile copy = f;
        copy.path = kept;
        items << std::pair{copy, id};
    }
    spawn(uploadAndSend(peer, items, groupId, hasCaption ? std::optional(caption) : std::nullopt, textMessageId));
    co_return rejected;
}

Task<void> Core::uploadAndSend(ChatPeer peer, QList<std::pair<OutgoingFile, QString>> items, std::optional<QString> groupId,
                               std::optional<QString> caption, std::optional<QString> textMessageId) {
    QStringList ids;
    if (textMessageId) ids << *textMessageId;
    for (const auto &[f, id] : items) ids << id;
    for (const QString &id : ids) uploading_.insert(id);
    auto fail = [&] {
        for (const QString &id : ids) chats.updateMessageStatus(peer.login, id, MessageStatus::Failed);
    };
    try {
        const auto token = session.token();
        if (!token || peer.deviceId.isEmpty() || peer.accountId.isEmpty()) throw ApiError("error.notSignedIn");
        QList<std::tuple<OutgoingFile, QString, MediaRef>> refs;
        for (const auto &[f, id] : items) {
            if (cancelledUploads_.contains(id)) throw ApiError("error.cancelledByUser");
            const QString mid = id;
            const ProgressFn progress = [this, mid](double pct) { setUploadProgress(mid, pct); };
            const MediaRef ref = co_await uploader.upload(peer.login, id, f.path, QFileInfo(f.path).size(), f.name, *token, peer.accountId, progress);
            refs << std::tuple{f, id, ref};
        }
        if (groupId) {
            QJsonArray files;
            for (const auto &[f, id, ref] : refs) {
                QJsonObject body = InnerMessage::media(ref, f.name, f.isFile, f.isVideo, false, id).bodyJson();
                body.insert("message_id", id);
                files.append(body);
            }
            const InnerMessage group = InnerMessage::mediaGroup(*groupId, files, caption, textMessageId);
            const QString login = peer.login;
            // GCC 11: временные объекты внутри co_await разрушаются раньше времени — колбэк заранее
            SendQueueProcessor::OnAcked onAcked = [this, login, ids] {
                for (const QString &id : ids) chats.updateMessageStatus(login, id, MessageStatus::Sent);
            };
            co_await messenger.send(peer.deviceId, group, peer.login, false, false, onAcked);
        } else if (!refs.isEmpty()) {
            const auto &[f, id, ref] = refs.first();
            co_await messenger.send(peer.deviceId, InnerMessage::media(ref, f.name, f.isFile, f.isVideo, false, id), peer.login);
        }
    } catch (const std::exception &e) {
        logError(QStringLiteral("sendMedia FAILED to=%1: %2").arg(peer.deviceId, what(e)));
        fail();
    }
    for (const QString &id : ids) {
        uploading_.remove(id);
        cancelledUploads_.remove(id);
        setUploadProgress(id, std::nullopt);
    }
}

Task<void> Core::sendRecorded(ChatPeer peer, QString recording, qint64 durationMs, bool videoNote, QString preview) {
    const QString id = newId();
    const QString dir = dirs.data + "/outgoing";
    QDir().mkpath(dir);
    const QString kept = dir + "/" + id + (videoNote ? ".mp4" : ".m4a");
    QFile::rename(recording, kept);
    const qint64 size = QFileInfo(kept).size();
    StoredMessage m;
    m.messageId = id;
    m.isMine = true;
    m.timestamp = nowMs();
    m.isMedia = true;
    m.isVoice = !videoNote;
    m.isVideoNote = videoNote;
    m.fileSize = size;
    m.chunked = size > StreamingFileCipher::StreamingThresholdBytes;
    m.durationMs = durationMs;
    m.status = MessageStatus::Sending;
    m.processingStep = UploadStep::Queued;
    m.localSourcePath = kept;
    if (!preview.isEmpty()) m.localPreviewPath = preview;
    chats.addMessage(peer.login, m, peer.accountId);
    co_await uploadRecorded(peer, id, kept, size, durationMs, videoNote);
}

Task<void> Core::uploadRecorded(ChatPeer peer, QString messageId, QString path, qint64 size, qint64 durationMs, bool videoNote) {
    uploading_.insert(messageId);
    try {
        const auto token = session.token();
        if (!token || peer.deviceId.isEmpty() || peer.accountId.isEmpty()) throw ApiError("error.notSignedIn");
        const ProgressFn progress = [this, messageId](double pct) { setUploadProgress(messageId, pct); };
        const QString name = videoNote ? QStringLiteral("video_note.mp4") : QStringLiteral("voice.m4a");
        const MediaRef ref = co_await uploader.upload(peer.login, messageId, path, size, name, *token, peer.accountId, progress);
        const InnerMessage inner = videoNote ? InnerMessage::videoNote(ref, durationMs, messageId) : InnerMessage::voice(ref, durationMs, messageId);
        co_await messenger.send(peer.deviceId, inner, peer.login);
    } catch (const std::exception &e) {
        logError(QStringLiteral("sendRecorded FAILED %1: %2").arg(messageId, what(e)));
        chats.updateMessageStatus(peer.login, messageId, MessageStatus::Failed);
    }
    uploading_.remove(messageId);
    setUploadProgress(messageId, std::nullopt);
}

Task<void> Core::retry(ChatPeer peer, StoredMessage m) {
    if (!m.isMine) co_return;
    chats.updateMessageStatus(peer.login, m.messageId, MessageStatus::Sending);
    if (m.isSticker()) {
        InnerMessage inner{m.messageId, MessageType::Sticker, m.timestamp, json::compact(QJsonObject{{"sticker_id", *m.stickerId}}),
                           std::nullopt, m.replyToMessageId, m.replyToPreview};
        co_await sendNetwork(peer, inner);
    } else if (!m.isMedia) {
        // тот же message_id — получатель погасит дубль
        const InnerMessage inner{m.messageId, MessageType::Text, m.timestamp, m.text, m.groupId, m.replyToMessageId, m.replyToPreview};
        co_await sendNetwork(peer, inner);
    } else if (m.localSourcePath && QFile::exists(*m.localSourcePath)) {
        if (m.isVoice || m.isVideoNote) {
            co_await uploadRecorded(peer, m.messageId, *m.localSourcePath, QFileInfo(*m.localSourcePath).size(), m.durationMs.value_or(0), m.isVideoNote);
        } else {
            const OutgoingFile f{*m.localSourcePath, m.isFile, m.isVideo, m.fileName.value_or(QStringLiteral("file"))};
            QList<std::pair<OutgoingFile, QString>> one;
            one << std::pair{f, m.messageId};
            co_await uploadAndSend(peer, one, std::nullopt, std::nullopt, std::nullopt);
        }
    } else {
        chats.updateMessageStatus(peer.login, m.messageId, MessageStatus::Failed);
    }
}

void Core::cancelOutgoing(const QString &peerLogin, const QStringList &messageIds) {
    for (const QString &id : messageIds) cancelledUploads_.insert(id);
    sendQueue.drop(QSet<QString>(messageIds.begin(), messageIds.end()));
    QList<StoredMessage> toPurge;
    for (const auto &m : chats.messages(peerLogin)) {
        if (messageIds.contains(m.messageId)) toPurge << m;
    }
    chats.deleteMessages(peerLogin, messageIds);
    purgeMedia(toPurge);
}

Task<void> Core::editText(ChatPeer peer, QString messageId, QString text) {
    chats.editMessageText(peer.login, messageId, text);
    co_await messenger.sendControl(peer.deviceId, InnerMessage::edit(messageId, text));
}

Task<void> Core::react(ChatPeer peer, QString messageId, std::optional<QString> emoji) {
    chats.setReaction(peer.login, messageId, true, emoji);
    co_await messenger.sendControl(peer.deviceId, InnerMessage::reaction(messageId, emoji));
}

Task<void> Core::setPinned(ChatPeer peer, QString messageId, bool pinned) {
    chats.setPinned(peer.login, pinned ? std::optional(messageId) : std::nullopt);
    co_await messenger.sendControl(peer.deviceId, InnerMessage::pin(messageId, pinned));
}

Task<void> Core::deleteMessages(ChatPeer peer, QStringList ids, bool forPeer) {
    if (ids.isEmpty()) co_return;
    const auto chat = chats.peer(peer.login);
    const std::optional<QString> pinnedId = chat ? chat->pinnedMessageId : std::nullopt;
    const bool deletingPinned = pinnedId && ids.contains(*pinnedId);
    if (forPeer) {
        co_await messenger.sendControl(peer.deviceId, InnerMessage::remove(ids));
        if (deletingPinned) co_await messenger.sendControl(peer.deviceId, InnerMessage::pin(*pinnedId, false));
    }
    if (deletingPinned) chats.setPinned(peer.login, std::nullopt);
    QList<StoredMessage> toPurge;
    for (const auto &m : chats.messages(peer.login)) {
        if (ids.contains(m.messageId)) toPurge << m;
    }
    chats.deleteMessages(peer.login, ids);
    purgeMedia(toPurge);
}

Task<void> Core::sendReadReceipts(ChatPeer peer) {
    QStringList ids;
    for (const auto &m : chats.messages(peer.login)) {
        if (!m.isMine && !m.readReceiptSent && !m.isCallLog && !m.isUndecryptable && !receiptsInFlight_.contains(m.messageId)) ids << m.messageId;
    }
    chats.clearUnread(peer.login);
    if (ids.isEmpty() || peer.deviceId.isEmpty()) co_return;
    for (const QString &id : ids) receiptsInFlight_.insert(id);
    const QString login = peer.login;
    try {
        SendQueueProcessor::OnAcked onAcked = [this, login, ids] {
            chats.markReadReceiptsSent(login, ids);
            for (const QString &id : ids) receiptsInFlight_.remove(id);
        };
        const InnerMessage receipt = InnerMessage::readReceipt(ids);
        co_await messenger.send(peer.deviceId, receipt, std::nullopt, true, std::nullopt, onAcked);
    } catch (const std::exception &e) {
        for (const QString &id : ids) receiptsInFlight_.remove(id);
        log(QStringLiteral("ChatService read receipts not queued: %1").arg(what(e)));
    }
}

Task<void> Core::clearOrDelete(ChatSummary chat, bool deleteChat, bool forPeer) {
    if (forPeer) {
        const QString deviceId = co_await messenger.resolvePeerDeviceId(chat.peerLogin, chat.lastKnownDeviceId.value_or(QString()));
        if (!deviceId.isEmpty()) {
            // условия — заранее: «?:» внутри co_await GCC 11 собирает с ошибками (см. README)
            const QString reason = deleteChat ? QStringLiteral("delete chat (both sides)") : QStringLiteral("clear history (both sides)");
            const InnerMessage control = deleteChat ? InnerMessage::deleteChat() : InnerMessage::clearChat();
            co_await router.resetSessionWith(deviceId, reason);
            co_await messenger.sendControl(deviceId, control);
        }
    }
    const auto all = chats.messages(chat.peerLogin);
    if (deleteChat) chats.removeChat(chat.peerLogin);
    else chats.clearHistory(chat.peerLogin);
    purgeMedia(all);
}

Task<void> Core::setMuted(ChatSummary chat, bool muted) {
    chats.setChatMuted(chat.peerLogin, muted);
    const auto token = session.token();
    if (!chat.lastKnownAccountId || !token) co_return;
    try {
        if (muted) co_await api.muteChat(*token, *chat.lastKnownAccountId);
        else co_await api.unmuteChat(*token, *chat.lastKnownAccountId);
    } catch (const std::exception &) {
    }
}

Task<void> Core::setBlocked(ChatSummary chat, bool blocked) {
    chats.setChatBlockedByMe(chat.peerLogin, blocked);
    try {
        const auto token = session.token();
        if (!chat.lastKnownAccountId || !token) throw ApiError("error.blockFailed");
        if (blocked) co_await api.blockContact(*token, *chat.lastKnownAccountId);
        else co_await api.unblockContact(*token, *chat.lastKnownAccountId);
        co_await syncBlocked(*token);
    } catch (const std::exception &) {
        chats.setChatBlockedByMe(chat.peerLogin, !blocked);
        throw ApiError("error.blockFailed");
    }
}

Task<void> Core::resetSession(ChatPeer peer) { co_await router.resetSessionWith(peer.deviceId, "manual (chat menu)"); }

void Core::purgeMedia(const QList<StoredMessage> &messages) {
    for (const auto &m : messages) {
        if (m.mediaId) QFile::remove(media.cacheFile(*m.mediaId));
        if (m.localSourcePath && m.localSourcePath->startsWith(dirs.data)) QFile::remove(*m.localSourcePath);
        if (chunkedSessions.get(m.messageId)) {
            chunkedSessions.clear(m.messageId);
            QFile::remove(dirs.data + "/chunked_uploads/enc_" + m.messageId + ".bin");
        }
        for (const auto &key : {std::optional(m.messageId), m.groupId}) {
            if (!key) continue;
            sendQueueStore.remove(*key);
            acks.cancel(*key);
        }
    }
}

/// Свои сообщения, застрявшие в «отправляется» без конверта в очереди (процесс
/// закрыли посреди шифрования/загрузки), — «не отправлено»: их можно повторить.
void Core::failOrphanedSending() {
    const QSet<QString> queued = sendQueue.pendingIds();
    for (const auto &[login, m] : chats.sendingMessages()) {
        if (queued.contains(m.messageId) || (m.groupId && queued.contains(*m.groupId))) continue;
        log(QStringLiteral("Orphaned sending message %1 — marked failed").arg(m.messageId));
        chats.updateMessageStatus(login, m.messageId, MessageStatus::Failed);
    }
}

QSet<QString> Core::activeUploads() const { return uploading_; }

std::optional<double> Core::uploadProgress(const QString &messageId) const {
    const auto it = uploadProgress_.find(messageId);
    return it == uploadProgress_.end() ? std::nullopt : std::optional(*it);
}

void Core::setUploadProgress(const QString &messageId, std::optional<double> pct) {
    if (pct) {
        const double v = std::floor(*pct);
        if (uploadProgress_.value(messageId, -1) == v) return;
        uploadProgress_[messageId] = v;
        Q_EMIT uploadProgressChanged(messageId, v);
    } else if (uploadProgress_.remove(messageId)) {
        Q_EMIT uploadProgressChanged(messageId, -1);
    }
}

// ---------------- отчёты ----------------

void Core::reportProblem(const QString &kind, const QString &summary) {
    const auto token = session.token();
    if (!token) return;
    const QString text = QStringLiteral("=== %1 %2 ===\n%3\ndevice=Linux %4 (%5) qt=%6\n=== журнал ===\n%7")
                             .arg(kind.toUpper(), QDateTime::currentDateTime().toString(Qt::ISODateWithMs), summary, QSysInfo::prettyProductName(),
                                  QSysInfo::currentCpuArchitecture(), QString::fromLatin1(qVersion()), logTail(48 * 1024));
    spawn([](ApiClient &api, QString t, QString body, QString k) -> Task<void> {
        try {
            co_await api.reportCrashLog(t, body, k);
        } catch (const std::exception &e) {
            log(QStringLiteral("report %1 not sent: %2").arg(k, QString::fromUtf8(e.what())));
        }
    }(api, *token, text, kind));
}

} // namespace osh
