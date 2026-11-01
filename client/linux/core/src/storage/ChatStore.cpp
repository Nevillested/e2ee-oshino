#include "storage/ChatStore.h"

#include "crypto/Primitives.h"
#include "support/Json.h"
#include "support/Log.h"

#include <QDateTime>
#include <QSet>
#include <QSqlError>
#include <QSqlQuery>
#include <QUuid>
#include <algorithm>

namespace osh {

namespace {
constexpr int MaxTombstones = 500;
const QString LegacyNotesLogin = QStringLiteral("__notes__");
const QByteArray RowAad = QByteArrayLiteral("oshinobu-chat-row");

void exec(QSqlQuery &q) {
    if (!q.exec()) logError(QStringLiteral("ChatStore SQL: %1").arg(q.lastError().text()));
}
} // namespace

const QString ChatStore::PreviewMark = QString(QChar(0xE000));

ChatStore::ChatStore(const QString &path, QByteArray key, QObject *parent)
    : QObject(parent), connection_(QStringLiteral("chats-") + QUuid::createUuid().toString(QUuid::WithoutBraces)), key_(std::move(key)) {
    QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection_);
    db.setDatabaseName(path.isEmpty() ? QStringLiteral(":memory:") : path);
    if (!db.open()) logError(QStringLiteral("ChatStore: не открыть базу: %1").arg(db.lastError().text()));
    QSqlQuery q(db);
    for (const char *sql : {
             "PRAGMA journal_mode=WAL",
             "PRAGMA synchronous=NORMAL",
             "CREATE TABLE IF NOT EXISTS messages (peer TEXT NOT NULL, id TEXT NOT NULL, ts INTEGER NOT NULL, data BLOB NOT NULL, "
             "PRIMARY KEY (peer, id))",
             "CREATE TABLE IF NOT EXISTS tombstones (peer TEXT PRIMARY KEY, data BLOB NOT NULL)",
             "CREATE TABLE IF NOT EXISTS peers (login TEXT PRIMARY KEY, data BLOB NOT NULL)",
         }) {
        if (!q.exec(QString::fromLatin1(sql))) logError(QStringLiteral("ChatStore SQL: %1").arg(q.lastError().text()));
    }
}

ChatStore::~ChatStore() {
    { QSqlDatabase::database(connection_).close(); }
    QSqlDatabase::removeDatabase(connection_);
}

// ---------------- превью ----------------

QString ChatStore::previewMarker(const StoredMessage &m) {
    if (m.isCallLog) return PreviewMark + "call:" + m.callOutcome.value_or("no_answer");
    if (m.isUndecryptable) return PreviewMark + "undecryptable";
    if (m.isVoice) return PreviewMark + "voice";
    if (m.isVideoNote) return PreviewMark + "videoNote";
    if (m.isSticker()) return PreviewMark + "sticker";
    if (m.isMedia) {
        const QString caption = m.text.trimmed();
        bool oldFrozen = false;
        for (const char *e : {"📷", "🎬", "📎", "🎥", "🎤"}) oldFrozen = oldFrozen || caption.startsWith(QString::fromUtf8(e));
        if (!caption.isEmpty() && !oldFrozen) return caption;
        if (m.isFile) return m.fileName && !m.fileName->isEmpty() ? PreviewMark + "file:" + *m.fileName : PreviewMark + "file";
        if (m.isVideo) return PreviewMark + "video";
        return PreviewMark + "photo";
    }
    return m.text;
}

QString ChatStore::decodePreview(const QString &raw, const std::function<QString(const QString &)> &tr) {
    if (!raw.startsWith(PreviewMark)) return raw;
    const QString body = raw.mid(PreviewMark.size());
    const int colon = body.indexOf(u':');
    const QString type = colon < 0 ? body : body.left(colon);
    const QString arg = colon < 0 ? QString() : body.mid(colon + 1);
    if (type == "voice") return "🎤 " + tr("media.voiceNote");
    if (type == "videoNote") return "🎥 " + tr("media.videoNote");
    if (type == "photo") return "📷 " + tr("media.photo");
    if (type == "sticker") return tr("sticker.preview");
    if (type == "video") return "🎬 " + tr("media.video");
    if (type == "file") return arg.isEmpty() ? "📎 " + tr("media.file") : arg;
    if (type == "undecryptable") return "🔒 " + tr("chat.undecryptablePreview");
    if (type == "call") {
        return "📞 " + (arg == "answered" ? tr("call.answered") : arg == "missed" ? tr("call.missed") : tr("call.noAnswer"));
    }
    return raw;
}

// ---------------- шифрование записей ----------------

QByteArray ChatStore::seal(const QJsonObject &o) const {
    const SealedBox box = AesGcm::encrypt(key_, QJsonDocument(o).toJson(QJsonDocument::Compact), RowAad);
    return box.nonce + box.ciphertext + box.mac;
}

QJsonObject ChatStore::open(const QByteArray &blob) const {
    if (blob.size() < AesGcm::NonceBytes + AesGcm::TagBytes) return {};
    const SealedBox box{blob.left(AesGcm::NonceBytes), blob.mid(AesGcm::NonceBytes, blob.size() - AesGcm::NonceBytes - AesGcm::TagBytes),
                        blob.right(AesGcm::TagBytes)};
    try {
        return json::parseObject(AesGcm::decrypt(key_, box, RowAad));
    } catch (const std::exception &e) {
        logError(QStringLiteral("ChatStore: запись не расшифровывается: %1").arg(QString::fromUtf8(e.what())));
        return {};
    }
}

// ---------------- сообщения ----------------

QList<StoredMessage> &ChatStore::loaded(const QString &peerLogin) {
    auto it = cache_.find(peerLogin);
    if (it != cache_.end()) return *it;
    QList<StoredMessage> list;
    QSqlQuery q(QSqlDatabase::database(connection_));
    q.prepare("SELECT data FROM messages WHERE peer = ? ORDER BY ts, rowid");
    q.addBindValue(peerLogin);
    exec(q);
    while (q.next()) {
        const QJsonObject o = open(q.value(0).toByteArray());
        if (!o.isEmpty()) list << StoredMessage::fromJson(o);
    }
    return *cache_.insert(peerLogin, list);
}

void ChatStore::writeMessage(const QString &peerLogin, const StoredMessage &m) {
    QSqlQuery q(QSqlDatabase::database(connection_));
    q.prepare("INSERT OR REPLACE INTO messages (peer, id, ts, data) VALUES (?, ?, ?, ?)");
    q.addBindValue(peerLogin);
    q.addBindValue(m.messageId);
    q.addBindValue(m.timestamp);
    q.addBindValue(seal(m.toJson()));
    exec(q);
}

void ChatStore::eraseMessages(const QString &peerLogin, const QStringList &ids) {
    QSqlDatabase db = QSqlDatabase::database(connection_);
    db.transaction();
    QSqlQuery q(db);
    q.prepare("DELETE FROM messages WHERE peer = ? AND id = ?");
    for (const QString &id : ids) {
        q.addBindValue(peerLogin);
        q.addBindValue(id);
        exec(q);
    }
    db.commit();
}

QList<StoredMessage> ChatStore::messages(const QString &peerLogin) { return loaded(peerLogin); }

std::optional<StoredMessage> ChatStore::message(const QString &peerLogin, const QString &messageId) {
    for (const auto &m : loaded(peerLogin)) {
        if (m.messageId == messageId) return m;
    }
    return std::nullopt;
}

QStringList ChatStore::tombstones(const QString &peerLogin) {
    QSqlQuery q(QSqlDatabase::database(connection_));
    q.prepare("SELECT data FROM tombstones WHERE peer = ?");
    q.addBindValue(peerLogin);
    exec(q);
    if (!q.next()) return {};
    QStringList out;
    for (const QJsonValue &v : open(q.value(0).toByteArray()).value("ids").toArray()) out << v.toString();
    return out;
}

void ChatStore::writeTombstones(const QString &peerLogin, const QStringList &ids) {
    QSqlQuery q(QSqlDatabase::database(connection_));
    if (ids.isEmpty()) {
        q.prepare("DELETE FROM tombstones WHERE peer = ?");
        q.addBindValue(peerLogin);
    } else {
        q.prepare("INSERT OR REPLACE INTO tombstones (peer, data) VALUES (?, ?)");
        q.addBindValue(peerLogin);
        q.addBindValue(seal(QJsonObject{{"ids", QJsonArray::fromStringList(ids.mid(std::max<qsizetype>(0, ids.size() - MaxTombstones)))}}));
    }
    exec(q);
}

void ChatStore::addMessage(const QString &peerLogin, const StoredMessage &m, const std::optional<QString> &accountId, bool incrementUnread) {
    addMessages(peerLogin, {m}, accountId, incrementUnread);
}

void ChatStore::addMessages(const QString &peerLogin, const QList<StoredMessage> &ms, const std::optional<QString> &accountId,
                            bool incrementUnread) {
    if (ms.isEmpty()) return;
    QList<StoredMessage> &list = loaded(peerLogin);
    QSet<QString> existing;
    for (const auto &m : list) existing.insert(m.messageId);
    QStringList tomb = tombstones(peerLogin);
    bool tombChanged = false;
    QList<StoredMessage> added;
    for (const auto &m : ms) {
        if (existing.contains(m.messageId)) continue;
        // удалённое (у себя или собеседником) — опоздавшая копия не воскресает
        if (tomb.removeOne(m.messageId)) {
            tombChanged = true;
            continue;
        }
        existing.insert(m.messageId);
        added << m;
    }
    if (tombChanged) writeTombstones(peerLogin, tomb);
    if (added.isEmpty()) return;
    QSqlDatabase db = QSqlDatabase::database(connection_);
    db.transaction();
    for (const auto &m : added) {
        list << m;
        writeMessage(peerLogin, m);
    }
    db.commit();
    std::stable_sort(list.begin(), list.end(), [](const StoredMessage &a, const StoredMessage &b) { return a.timestamp < b.timestamp; });
    const auto last = std::max_element(added.begin(), added.end(), [](const auto &a, const auto &b) { return a.timestamp < b.timestamp; });
    touchPeer(peerLogin, previewMarker(*last), last->timestamp, accountId, incrementUnread, last->isMine, last->status == MessageStatus::Read);
}

void ChatStore::addCallLog(const QString &peerLogin, const QString &direction, const QString &outcome, qint64 timestamp,
                           std::optional<qint64> durationSeconds, const std::optional<QString> &accountId, bool incrementUnread,
                           const std::optional<QString> &callId) {
    const bool answered = outcome == "answered";
    StoredMessage m;
    m.messageId = callId ? "call_" + *callId : QStringLiteral("call_%1_%2").arg(timestamp).arg(direction);
    m.isMine = direction == "outgoing";
    m.timestamp = timestamp;
    m.isCallLog = true;
    m.callDirection = direction;
    m.callOutcome = outcome;
    m.callDurationSeconds = durationSeconds;
    m.status = answered ? MessageStatus::Read : MessageStatus::Sent;
    m.readReceiptSent = answered;
    addMessage(peerLogin, m, accountId, incrementUnread);
}

void ChatStore::addUndecryptableNotice(const QString &peerLogin, const QString &id, qint64 timestamp, const std::optional<QString> &accountId,
                                       bool incrementUnread) {
    StoredMessage m;
    m.messageId = id;
    m.timestamp = timestamp;
    m.isUndecryptable = true;
    m.readReceiptSent = true;
    addMessage(peerLogin, m, accountId, incrementUnread);
}

bool ChatStore::update(const QString &peerLogin, const QString &messageId, const std::function<void(StoredMessage &)> &fn) {
    for (auto &m : loaded(peerLogin)) {
        if (m.messageId != messageId) continue;
        fn(m);
        writeMessage(peerLogin, m);
        Q_EMIT changed(peerLogin);
        return true;
    }
    return false;
}

void ChatStore::updateMessageStatus(const QString &peerLogin, const QString &messageId, const QString &status) {
    update(peerLogin, messageId, [&](StoredMessage &m) {
        m.status = status;
        if (status == MessageStatus::Sent || status == MessageStatus::Failed || status == MessageStatus::Queued) m.processingStep.reset();
    });
}

void ChatStore::markRetrying(const QString &peerLogin, const QString &messageId, const QString &step) {
    update(peerLogin, messageId, [&](StoredMessage &m) {
        m.status = MessageStatus::Sending;
        m.processingStep = step;
    });
}

void ChatStore::updateProcessingStep(const QString &peerLogin, const QString &messageId, const QString &step) {
    update(peerLogin, messageId, [&](StoredMessage &m) { m.processingStep = step; });
}

void ChatStore::updateMediaInfo(const QString &peerLogin, const QString &messageId, const QString &mediaId, const QString &key,
                                const std::optional<QString> &nonce, const std::optional<QString> &mac) {
    update(peerLogin, messageId, [&](StoredMessage &m) {
        m.mediaId = mediaId;
        m.mediaKeyBase64 = key;
        if (nonce) m.mediaNonceBase64 = nonce;
        if (mac) m.mediaMacBase64 = mac;
    });
}

void ChatStore::setReaction(const QString &peerLogin, const QString &messageId, bool isMine, const std::optional<QString> &emoji) {
    update(peerLogin, messageId, [&](StoredMessage &m) { (isMine ? m.myReaction : m.peerReaction) = emoji; });
}

void ChatStore::editMessageText(const QString &peerLogin, const QString &messageId, const QString &text) {
    update(peerLogin, messageId, [&](StoredMessage &m) {
        m.text = text;
        m.edited = true;
    });
    const QList<StoredMessage> &list = loaded(peerLogin);
    if (!list.isEmpty() && list.last().messageId == messageId) refreshLast(peerLogin);
}

void ChatStore::markMessagesRead(const QString &peerLogin, const QStringList &ids) {
    if (ids.isEmpty()) return;
    const QSet<QString> set(ids.begin(), ids.end());
    bool any = false;
    for (auto &m : loaded(peerLogin)) {
        if (set.contains(m.messageId) && m.status != MessageStatus::Read) {
            m.status = MessageStatus::Read;
            writeMessage(peerLogin, m);
            any = true;
        }
    }
    if (any) refreshLast(peerLogin);
    Q_EMIT changed(peerLogin);
}

void ChatStore::markReadReceiptsSent(const QString &peerLogin, const QStringList &ids) {
    const QSet<QString> set(ids.begin(), ids.end());
    for (auto &m : loaded(peerLogin)) {
        if (set.contains(m.messageId) && !m.readReceiptSent) {
            m.readReceiptSent = true;
            writeMessage(peerLogin, m);
        }
    }
}

void ChatStore::deleteMessages(const QString &peerLogin, const QStringList &ids) {
    if (ids.isEmpty()) return;
    const QSet<QString> set(ids.begin(), ids.end());
    QList<StoredMessage> &list = loaded(peerLogin);
    list.erase(std::remove_if(list.begin(), list.end(), [&](const StoredMessage &m) { return set.contains(m.messageId); }), list.end());
    eraseMessages(peerLogin, ids);
    QStringList tomb = tombstones(peerLogin);
    for (const QString &id : ids) {
        if (!tomb.contains(id)) tomb << id;
    }
    writeTombstones(peerLogin, tomb);
    updatePeer(peerLogin, [&](ChatSummary &p) {
        if (p.pinnedMessageId && set.contains(*p.pinnedMessageId)) p.pinnedMessageId.reset();
        return true;
    });
    refreshLast(peerLogin);
    Q_EMIT changed(peerLogin);
}

void ChatStore::clearHistory(const QString &peerLogin) {
    QSqlQuery q(QSqlDatabase::database(connection_));
    q.prepare("DELETE FROM messages WHERE peer = ?");
    q.addBindValue(peerLogin);
    exec(q);
    writeTombstones(peerLogin, {});
    cache_[peerLogin].clear();
    updatePeer(peerLogin, [](ChatSummary &p) {
        p.lastMessage.clear();
        p.lastTimestamp = 0;
        p.pinnedMessageId.reset();
        return true;
    });
    Q_EMIT changed(peerLogin);
}

void ChatStore::removeChat(const QString &peerLogin) {
    QSqlQuery q(QSqlDatabase::database(connection_));
    q.prepare("DELETE FROM messages WHERE peer = ?");
    q.addBindValue(peerLogin);
    exec(q);
    writeTombstones(peerLogin, {});
    cache_.remove(peerLogin);
    erasePeer(peerLogin);
    Q_EMIT changed(peerLogin);
}

QList<std::pair<QString, StoredMessage>> ChatStore::sendingMessages() {
    QList<std::pair<QString, StoredMessage>> out;
    for (const auto &p : knownPeers()) {
        for (const auto &m : loaded(p.peerLogin)) {
            if (m.isMine && (m.status == MessageStatus::Sending || m.status == MessageStatus::Queued)) out << std::pair{p.peerLogin, m};
        }
    }
    return out;
}

// ---------------- список чатов ----------------

QList<ChatSummary> &ChatStore::peers() {
    if (!peers_) {
        QList<ChatSummary> list;
        QSqlQuery q(QSqlDatabase::database(connection_));
        q.prepare("SELECT data FROM peers");
        exec(q);
        while (q.next()) {
            const QJsonObject o = open(q.value(0).toByteArray());
            if (!o.isEmpty()) list << ChatSummary::fromJson(o);
        }
        peers_ = list;
    }
    return *peers_;
}

void ChatStore::writePeer(const ChatSummary &p) {
    QSqlQuery q(QSqlDatabase::database(connection_));
    q.prepare("INSERT OR REPLACE INTO peers (login, data) VALUES (?, ?)");
    q.addBindValue(p.peerLogin);
    q.addBindValue(seal(p.toJson()));
    exec(q);
}

void ChatStore::erasePeer(const QString &peerLogin) {
    auto &list = peers();
    list.erase(std::remove_if(list.begin(), list.end(), [&](const ChatSummary &p) { return p.peerLogin == peerLogin; }), list.end());
    QSqlQuery q(QSqlDatabase::database(connection_));
    q.prepare("DELETE FROM peers WHERE login = ?");
    q.addBindValue(peerLogin);
    exec(q);
}

bool ChatStore::updatePeer(const QString &peerLogin, const std::function<bool(ChatSummary &)> &fn) {
    for (auto &p : peers()) {
        if (p.peerLogin != peerLogin) continue;
        if (fn(p)) {
            writePeer(p);
            Q_EMIT changed(peerLogin);
        }
        return true;
    }
    return false;
}

void ChatStore::touchPeer(const QString &peerLogin, const QString &preview, qint64 ts, const std::optional<QString> &accountId, bool incrementUnread,
                          bool isMine, bool isRead) {
    const bool found = updatePeer(peerLogin, [&](ChatSummary &p) {
        p.lastMessage = preview;
        p.lastTimestamp = ts;
        p.lastMessageIsMine = isMine;
        p.lastMessageIsRead = isMine && isRead;
        if (accountId) p.lastKnownAccountId = accountId;
        if (incrementUnread) ++p.unreadCount;
        return true;
    });
    if (found) return;
    ChatSummary p;
    p.peerLogin = peerLogin;
    p.lastMessage = preview;
    p.lastTimestamp = ts;
    p.lastKnownAccountId = accountId;
    p.unreadCount = incrementUnread ? 1 : 0;
    p.lastMessageIsMine = isMine;
    p.lastMessageIsRead = isMine && isRead;
    peers() << p;
    writePeer(p);
    Q_EMIT changed(peerLogin);
}

void ChatStore::refreshLast(const QString &peerLogin) {
    const QList<StoredMessage> &list = loaded(peerLogin);
    updatePeer(peerLogin, [&](ChatSummary &p) {
        if (list.isEmpty()) {
            p.lastMessage.clear();
            p.lastTimestamp = 0;
            p.lastMessageIsMine = false;
            p.lastMessageIsRead = false;
        } else {
            const StoredMessage &last = list.last();
            p.lastMessage = previewMarker(last);
            p.lastTimestamp = last.timestamp;
            p.lastMessageIsMine = last.isMine;
            p.lastMessageIsRead = last.isMine && last.status == MessageStatus::Read;
        }
        return true;
    });
}

QList<ChatSummary> ChatStore::knownPeers() {
    QList<ChatSummary> out;
    for (const auto &p : peers()) {
        if (p.peerLogin != LegacyNotesLogin) out << p;
    }
    std::stable_sort(out.begin(), out.end(), ChatSummary::listOrder);
    return out;
}

std::optional<ChatSummary> ChatStore::peer(const QString &peerLogin) {
    for (const auto &p : peers()) {
        if (p.peerLogin == peerLogin) return p;
    }
    return std::nullopt;
}

void ChatStore::ensurePeer(const QString &peerLogin, const std::optional<QString> &accountId, const std::optional<QString> &deviceId) {
    const bool found = updatePeer(peerLogin, [&](ChatSummary &p) {
        bool changed = false;
        if (accountId && p.lastKnownAccountId != accountId) p.lastKnownAccountId = accountId, changed = true;
        if (deviceId && p.lastKnownDeviceId != deviceId) p.lastKnownDeviceId = deviceId, changed = true;
        return changed;
    });
    if (found) return;
    ChatSummary p;
    p.peerLogin = peerLogin;
    p.lastKnownAccountId = accountId;
    p.lastKnownDeviceId = deviceId;
    p.lastTimestamp = QDateTime::currentMSecsSinceEpoch();
    peers() << p;
    writePeer(p);
    Q_EMIT changed(peerLogin);
}

void ChatStore::setPinned(const QString &peerLogin, const std::optional<QString> &messageId) {
    if (!updatePeer(peerLogin, [&](ChatSummary &p) {
            p.pinnedMessageId = messageId;
            return true;
        }) &&
        messageId) {
        ensurePeer(peerLogin, std::nullopt, std::nullopt);
        setPinned(peerLogin, messageId);
    }
}

void ChatStore::setChatPinned(const QString &peerLogin, bool pinned) {
    updatePeer(peerLogin, [&](ChatSummary &p) {
        p.chatPinnedAt = pinned ? std::optional(QDateTime::currentMSecsSinceEpoch()) : std::nullopt;
        return true;
    });
}

bool ChatStore::isChatMuted(const QString &peerLogin) {
    const auto p = peer(peerLogin);
    return p && p->muted;
}

void ChatStore::setChatMuted(const QString &peerLogin, bool muted) {
    updatePeer(peerLogin, [&](ChatSummary &p) { return std::exchange(p.muted, muted) != muted; });
}

void ChatStore::syncMutedFromServer(const QSet<QString> &mutedAccountIds) {
    for (auto &p : peers()) {
        const bool should = p.lastKnownAccountId && mutedAccountIds.contains(*p.lastKnownAccountId);
        if (p.muted != should) {
            p.muted = should;
            writePeer(p);
            Q_EMIT changed(p.peerLogin);
        }
    }
}

void ChatStore::setChatBlockedByMe(const QString &peerLogin, bool blocked) {
    updatePeer(peerLogin, [&](ChatSummary &p) { return std::exchange(p.blockedByMe, blocked) != blocked; });
}

void ChatStore::syncBlockedFromServer(const QSet<QString> &blockedByMe, const QSet<QString> &blockingMe) {
    for (auto &p : peers()) {
        const bool byMe = p.lastKnownAccountId && blockedByMe.contains(*p.lastKnownAccountId);
        const bool me = p.lastKnownAccountId && blockingMe.contains(*p.lastKnownAccountId);
        if (p.blockedByMe != byMe || p.blockingMe != me) {
            p.blockedByMe = byMe;
            p.blockingMe = me;
            writePeer(p);
            Q_EMIT changed(p.peerLogin);
        }
    }
}

void ChatStore::clearUnread(const QString &peerLogin) {
    updatePeer(peerLogin, [](ChatSummary &p) { return std::exchange(p.unreadCount, 0) != 0; });
}

void ChatStore::setPeerDeletedStatus(const QString &peerLogin, bool isDeleted) {
    updatePeer(peerLogin, [&](ChatSummary &p) { return std::exchange(p.isDeleted, isDeleted) != isDeleted; });
}

void ChatStore::setLastKnownDeviceId(const QString &peerLogin, const QString &deviceId) {
    updatePeer(peerLogin, [&](ChatSummary &p) { return std::exchange(p.lastKnownDeviceId, deviceId) != deviceId; });
}

void ChatStore::setLastKnownAccountId(const QString &peerLogin, const QString &accountId) {
    updatePeer(peerLogin, [&](ChatSummary &p) { return std::exchange(p.lastKnownAccountId, accountId) != accountId; });
}

void ChatStore::wipeAll() {
    QSqlQuery q(QSqlDatabase::database(connection_));
    for (const char *sql : {"DELETE FROM messages", "DELETE FROM tombstones", "DELETE FROM peers"}) q.exec(QString::fromLatin1(sql));
    cache_.clear();
    peers_.reset();
    Q_EMIT changed(QString());
}

} // namespace osh
