#include "service/MessageRouter.h"

#include "crypto/MessageCipher.h"
#include "protocol/PeerCipher.h"
#include "support/Json.h"
#include "support/Log.h"

#include <QDateTime>
#include <QSet>
#include <QUuid>

namespace osh {

namespace {
const QString SessionResetType = QStringLiteral("session_reset");
constexpr qint64 ResetFailureThreshold = 3;
constexpr qint64 ResetCooldownMs = 30000;
constexpr qint64 NoSessionGiveUpMs = 2 * 60000;
constexpr int MaxRememberedNonces = 500;

const QSet<QString> &silentTypes() {
    static const QSet<QString> s{MessageType::Reaction, MessageType::Pin, MessageType::Edit, MessageType::Delete,
                                 MessageType::ClearChat, MessageType::DeleteChat, MessageType::ReadReceipt};
    return s;
}

QString failureCountKey(const QString &d) { return "session_reset_failcount:" + d; }
QString lastResetKey(const QString &d) { return "session_reset_last_request:" + d; }
QString noSessionFirstSeenKey(const QString &d) { return "no_session_first_seen:" + d; }
QString decryptedNoncesKey(const QString &d) { return "decrypted_nonces:" + d; }

qint64 now() { return QDateTime::currentMSecsSinceEpoch(); }

std::optional<qint64> optLong(const QJsonObject &o, const char *n) {
    const QJsonValue v = o.value(QLatin1String(n));
    return v.isDouble() ? std::optional(v.toInteger()) : std::nullopt;
}

QStringList strings(const QJsonObject &o, const char *n) {
    QStringList out;
    for (const QJsonValue &v : o.value(QLatin1String(n)).toArray()) out << v.toString();
    return out;
}

QString what(const std::exception &e) { return QString::fromUtf8(e.what()); }
} // namespace

StoredMessage mediaMessageFromBody(const QString &messageId, const QJsonObject &b, qint64 sentAt, const std::optional<QString> &groupId) {
    StoredMessage m;
    m.messageId = messageId;
    m.timestamp = sentAt;
    m.isMedia = true;
    m.isFile = b.value("is_file").toBool();
    m.isVideo = b.value("is_video").toBool();
    m.fileSize = optLong(b, "file_size").value_or(0);
    m.chunked = b.value("chunked").toBool();
    m.isSpoiler = b.value("spoiler").toBool();
    m.mediaId = json::string(b, "media_id");
    m.mediaKeyBase64 = json::string(b, "key");
    m.mediaNonceBase64 = json::optString(b, "nonce");
    m.mediaMacBase64 = json::optString(b, "mac");
    m.fileName = json::optString(b, "file_name");
    m.groupId = groupId;
    return m;
}

MessageRouter::MessageRouter(WebSocketClient &ws, ApiClient &api, Session &session, KeyStore &keys, SessionStore &sessions,
                             PeerAccountStore &peerAccounts, PeerIdentityStore &peerIdentities, ChatStore &chats, Prefs &prefs,
                             SendQueueProcessor &queue, KeyedMutex &sendLock, RouterHost &host,
                             std::function<void(const QList<StoredMessage> &)> purgeMedia, QObject *parent)
    : QObject(parent), ws_(ws), api_(api), session_(session), keys_(keys), sessions_(sessions), peerAccounts_(peerAccounts),
      peerIdentities_(peerIdentities), chats_(chats), prefs_(prefs), queue_(queue), sendLock_(sendLock), host_(host),
      purgeMedia_(std::move(purgeMedia)) {}

void MessageRouter::start() {
    if (started_) return;
    started_ = true;
    connect(&ws_, &WebSocketClient::envelopeReceived, this,
            [this](const QJsonObject &envelope, const QString &deliveryId) { spawn(handleIncoming(envelope, deliveryId)); });
}

void MessageRouter::ack(const QString &deliveryId) {
    if (!deliveryId.isEmpty()) ws_.ackDelivery(deliveryId);
}

Task<void> MessageRouter::handleIncoming(QJsonObject envelope, QString deliveryId) {
    const auto sender = json::optString(envelope, "sender_device_id");
    if (!sender) co_return;
    auto guard = co_await sendLock_[*sender].lock();
    try {
        co_await process(*sender, envelope, deliveryId);
    } catch (const std::exception &e) {
        logError(QStringLiteral("Router FAILED from=%1 deliveryId=%2 error=%3").arg(*sender, deliveryId.isEmpty() ? "-" : deliveryId, what(e)));
    }
}

Task<void> MessageRouter::process(QString senderDeviceId, QJsonObject envelope, QString deliveryId) {
    if (envelope.value("type").toString() == SessionResetType) {
        log(QStringLiteral("Router session_reset received from=%1 — retiring local session to archive").arg(senderDeviceId));
        sessions_.retire(senderDeviceId);
        prefs_.remove(failureCountKey(senderDeviceId));
        ack(deliveryId);
        co_return;
    }
    const auto inner = co_await decrypt(senderDeviceId, envelope, deliveryId);
    if (!inner) co_return;
    const auto owner = co_await resolveOwner(senderDeviceId);
    if (!owner) {
        log(QStringLiteral("Router DROP from=%1 reason=resolve-owner-failed").arg(senderDeviceId));
        co_return;
    }
    const bool chatIsOpen = host_.openChatPeerLogin() == owner->login;
    apply(*inner, *owner, chatIsOpen);
    ack(deliveryId);
    if (!chatIsOpen && !silentTypes().contains(inner->type) && !chats_.isChatMuted(owner->login)) {
        host_.playMessageSound();
        if (!host_.isAppInForeground()) {
            const auto peer = chats_.peer(owner->login);
            host_.showMessageNotification(owner->login, peer ? peer->lastMessage : QString());
        }
    }
}

MessageRouter::Opened MessageRouter::opened(const QString &senderDeviceId, const QString &raw) {
    sessions_.clearPendingInit(senderDeviceId);
    prefs_.remove(failureCountKey(senderDeviceId));
    prefs_.remove(noSessionFirstSeenKey(senderDeviceId));
    return Opened{Opened::Ok, raw, std::nullopt, false};
}

MessageRouter::Opened MessageRouter::open(const QString &senderDeviceId, const QJsonObject &envelope) {
    std::optional<RatchetState> current = sessions_.get(senderDeviceId);
    if (current) {
        RatchetState attempt = *current;
        try {
            const QString raw = decryptMessage(attempt.nextReceivingKey(envelope), envelope);
            sessions_.save(senderDeviceId, attempt);
            return opened(senderDeviceId, raw);
        } catch (const AlreadyProcessedError &e) {
            log(QStringLiteral("Router IGNORING duplicate from=%1 %2").arg(senderDeviceId, what(e)));
            return Opened{Opened::Duplicate, {}, std::nullopt, false};
        } catch (const std::exception &e) {
            log(QStringLiteral("Router current session failed from=%1: %2").arg(senderDeviceId, what(e)));
            // как на Android: дальше смотрим на состояние после попытки (ratchet уже шагнул), на диск его не пишем
            current = attempt;
        }
    }
    const QList<RatchetState> archived = sessions_.archived(senderDeviceId);
    for (int index = 0; index < archived.size(); ++index) {
        RatchetState old = archived[index];
        try {
            const QString raw = decryptMessage(old.nextReceivingKey(envelope), envelope);
            log(QStringLiteral("Router decrypted with archived session #%1 from=%2 — it is current again").arg(index).arg(senderDeviceId));
            sessions_.promote(senderDeviceId, index, old);
            return opened(senderDeviceId, raw);
        } catch (const AlreadyProcessedError &e) {
            log(QStringLiteral("Router IGNORING duplicate (archived session #%1) from=%2 %3").arg(index).arg(senderDeviceId, what(e)));
            return Opened{Opened::Duplicate, {}, std::nullopt, false};
        } catch (const std::exception &) {
        }
    }
    std::optional<RatchetState> fresh = establishFreshIncoming(senderDeviceId, envelope);
    if (fresh) {
        try {
            const QString raw = decryptMessage(fresh->nextReceivingKey(envelope), envelope);
            log(QStringLiteral("Router new X3DH session from=%1 (previous one archived)").arg(senderDeviceId));
            sessions_.replace(senderDeviceId, *fresh);
            return opened(senderDeviceId, raw);
        } catch (const std::exception &e) {
            log(QStringLiteral("Router new X3DH session from=%1 failed: %2").arg(senderDeviceId, what(e)));
        }
    }
    return Opened{Opened::Failed, {}, current, fresh.has_value()};
}

Task<std::optional<InnerMessage>> MessageRouter::decrypt(QString senderDeviceId, QJsonObject envelope, QString deliveryId) {
    Opened result = open(senderDeviceId, envelope);
    if (result.kind == Opened::Ok) {
        rememberDecrypted(senderDeviceId, envelope);
        co_return InnerMessage::decode(result.raw);
    }
    if (result.kind == Opened::Duplicate) {
        ack(deliveryId);
        co_return std::nullopt;
    }
    if (!result.current && !result.triedFresh) {
        const bool gaveUp = giveUpIfNoSessionTooLong(senderDeviceId);
        log(QStringLiteral("Router DROP from=%1 reason=no-session-and-no-handshake%2").arg(senderDeviceId, gaveUp ? " (gave up)" : ""));
        if (gaveUp) {
            ack(deliveryId);
            co_await recordUndecryptable(senderDeviceId, envelope);
        }
        co_return std::nullopt;
    }
    logError(QStringLiteral("Router decrypt-FAILED from=%1 hadSession=%2 triedFresh=%3")
                 .arg(senderDeviceId)
                 .arg(result.current.has_value())
                 .arg(result.triedFresh));
    if (result.current && !result.triedFresh) {
        co_await handleUnrecoverable(senderDeviceId, envelope, deliveryId, *result.current);
    } else if (co_await onDecryptFailure(senderDeviceId, deliveryId)) {
        co_await recordUndecryptable(senderDeviceId, envelope);
    }
    co_return std::nullopt;
}

Task<void> MessageRouter::handleUnrecoverable(QString senderDeviceId, QJsonObject envelope, QString deliveryId, RatchetState state) {
    const auto incomingKey = json::optString(envelope, "ratchet_pubkey");
    const auto currentKey = state.receivingRatchetPublicKey ? std::optional(b64(*state.receivingRatchetPublicKey)) : std::nullopt;
    // конверт старой эпохи ratchet (ключей уже нет) — сессию не трогаем
    if (incomingKey && currentKey && *incomingKey != *currentKey) {
        log(QStringLiteral("Router giving up on stale-ratchet-key delivery from=%1 (session left untouched)").arg(senderDeviceId));
        ack(deliveryId);
        co_await recordUndecryptable(senderDeviceId, envelope, true);
        co_return;
    }
    if (co_await onDecryptFailure(senderDeviceId, deliveryId)) co_await recordUndecryptable(senderDeviceId, envelope);
}

std::optional<RatchetState> MessageRouter::establishFreshIncoming(const QString &senderDeviceId, const QJsonObject &envelope) {
    const auto me = keys_.loadIdentity();
    if (!me) return std::nullopt;
    auto incoming = PeerCipher::startIncomingSession(envelope, *me);
    if (!incoming) return std::nullopt;
    if (incoming->second.consumedOneTimePrekey) keys_.deleteOneTimePrekey(*incoming->second.consumedOneTimePrekey);
    if (incoming->second.missingOneTimePrekey) log("X3DH: sender claims a one-time prekey we no longer have — 3-DH only");
    const QString newIdentityDh = json::string(envelope, "sender_identity_dh_pubkey");
    const auto previous = peerIdentities_.get(senderDeviceId);
    if (previous && *previous != newIdentityDh) logError(QStringLiteral("Router SECURITY-WARNING identity_dh_pubkey CHANGED for from=%1").arg(senderDeviceId));
    peerIdentities_.save(senderDeviceId, newIdentityDh);
    return std::move(incoming->first);
}

Task<bool> MessageRouter::onDecryptFailure(QString senderDeviceId, QString deliveryId) {
    const qint64 count = prefs_.getLong(failureCountKey(senderDeviceId)).value_or(0) + 1;
    prefs_.setLong(failureCountKey(senderDeviceId), count);
    log(QStringLiteral("Router decrypt-failure-count from=%1 count=%2").arg(senderDeviceId).arg(count));
    if (count < ResetFailureThreshold) co_return false;
    ack(deliveryId);
    if (!sessions_.get(senderDeviceId) || sessions_.pendingInit(senderDeviceId)) {
        log(QStringLiteral("Router no auto session-reset for=%1: our session is not confirmed by the peer yet").arg(senderDeviceId));
        co_return true;
    }
    const auto last = prefs_.getLong(lastResetKey(senderDeviceId));
    if (!last || now() - *last >= ResetCooldownMs) {
        prefs_.setLong(lastResetKey(senderDeviceId), now());
        log(QStringLiteral("Router auto session-reset for=%1 after %2 consecutive decrypt failures").arg(senderDeviceId).arg(count));
        resetLocked(senderDeviceId, QStringLiteral("auto (%1 decrypt failures)").arg(count));
    }
    co_return true;
}

Task<std::optional<QJsonObject>> MessageRouter::openCallSignal(QString senderDeviceId, QJsonObject envelope) {
    auto guard = co_await sendLock_[senderDeviceId].lock();
    try {
        Opened result = open(senderDeviceId, envelope);
        if (result.kind == Opened::Ok) co_return json::parseObject(result.raw);
        if (result.kind == Opened::Duplicate) co_return std::nullopt;
        if (!result.current && !result.triedFresh) {
            log(QStringLiteral("Router call signal from=%1: no session and no handshake").arg(senderDeviceId));
        } else {
            logError(QStringLiteral("Router call signal decrypt-FAILED from=%1 hadSession=%2 triedFresh=%3")
                         .arg(senderDeviceId)
                         .arg(result.current.has_value())
                         .arg(result.triedFresh));
            co_await onDecryptFailure(senderDeviceId, {});
        }
    } catch (const std::exception &e) {
        logError(QStringLiteral("Router call signal FAILED from=%1 error=%2").arg(senderDeviceId, what(e)));
    }
    co_return std::nullopt;
}

Task<void> MessageRouter::resetSessionWith(QString deviceId, QString reason) {
    auto guard = co_await sendLock_[deviceId].lock();
    resetLocked(deviceId, reason);
}

void MessageRouter::resetLocked(const QString &deviceId, const QString &reason) {
    log(QStringLiteral("Router resetSessionWith device=%1 reason=%2").arg(deviceId, reason));
    sessions_.retire(deviceId);
    const auto myDeviceId = keys_.deviceId();
    if (!myDeviceId) return;
    const QJsonObject envelope{{"type", SessionResetType}, {"sender_device_id", *myDeviceId}};
    queue_.enqueue(deviceId, envelope, QUuid::createUuid().toString(QUuid::WithoutBraces), true);
}

bool MessageRouter::giveUpIfNoSessionTooLong(const QString &deviceId) {
    const auto firstSeen = prefs_.getLong(noSessionFirstSeenKey(deviceId));
    if (!firstSeen) {
        prefs_.setLong(noSessionFirstSeenKey(deviceId), now());
        return false;
    }
    return now() - *firstSeen > NoSessionGiveUpMs;
}

void MessageRouter::rememberDecrypted(const QString &deviceId, const QJsonObject &envelope) {
    const auto nonce = json::optString(envelope, "nonce");
    if (!nonce) return;
    QStringList list = prefs_.getStringList(decryptedNoncesKey(deviceId)).value_or(QStringList());
    if (list.contains(*nonce)) return;
    list << *nonce;
    if (list.size() > MaxRememberedNonces) list = list.mid(list.size() - MaxRememberedNonces);
    prefs_.setStringList(decryptedNoncesKey(deviceId), list);
}

Task<void> MessageRouter::recordUndecryptable(QString deviceId, QJsonObject envelope, bool requireKnownHistory) {
    const auto nonce = json::optString(envelope, "nonce");
    if (!nonce) co_return;
    const auto decrypted = prefs_.getStringList(decryptedNoncesKey(deviceId));
    if (decrypted && decrypted->contains(*nonce)) co_return;
    if (requireKnownHistory && !decrypted) co_return;
    const auto owner = co_await resolveOwner(deviceId);
    if (!owner) co_return;
    chats_.addUndecryptableNotice(owner->login, "undecryptable_" + *nonce, now(), owner->accountId, host_.openChatPeerLogin() != owner->login);
}

std::optional<DeviceOwnerRef> MessageRouter::knownOwner(const QString &deviceId) {
    if (const auto it = ownerCache_.find(deviceId); it != ownerCache_.end()) return *it;
    if (const auto accountId = peerAccounts_.get(deviceId)) {
        for (const auto &p : chats_.knownPeers()) {
            if (p.lastKnownAccountId == accountId) return *ownerCache_.insert(deviceId, DeviceOwnerRef{*accountId, p.peerLogin});
        }
    }
    return std::nullopt;
}

Task<std::optional<DeviceOwnerRef>> MessageRouter::resolveOwner(QString deviceId) {
    if (auto known = knownOwner(deviceId)) co_return known;
    const auto token = session_.token();
    if (!token) co_return std::nullopt;
    const auto info = co_await api_.getDeviceOwnerInfo(*token, deviceId);
    if (!info) co_return std::nullopt;
    peerAccounts_.save(deviceId, info->accountId);
    co_return *ownerCache_.insert(deviceId, DeviceOwnerRef{info->accountId, info->login});
}

void MessageRouter::apply(const InnerMessage &inner, const DeviceOwnerRef &owner, bool chatIsOpen) {
    const QString &login = owner.login;
    const bool unread = !chatIsOpen;
    const QString &type = inner.type;
    if (type == MessageType::Text) {
        StoredMessage m;
        m.messageId = inner.messageId;
        m.text = inner.body;
        m.timestamp = inner.sentAt;
        m.groupId = inner.groupId;
        m.replyToMessageId = inner.replyToMessageId;
        m.replyToPreview = inner.replyToPreview;
        chats_.addMessage(login, m, owner.accountId, unread);
    } else if (type == MessageType::Sticker) {
        const auto stickerId = json::optString(inner.bodyJson(), "sticker_id");
        if (!stickerId) return;
        StoredMessage m;
        m.messageId = inner.messageId;
        m.timestamp = inner.sentAt;
        m.stickerId = stickerId;
        m.replyToMessageId = inner.replyToMessageId;
        m.replyToPreview = inner.replyToPreview;
        chats_.addMessage(login, m, owner.accountId, unread);
    } else if (type == MessageType::Media) {
        StoredMessage m = mediaMessageFromBody(inner.messageId, inner.bodyJson(), inner.sentAt, inner.groupId);
        m.replyToMessageId = inner.replyToMessageId;
        m.replyToPreview = inner.replyToPreview;
        chats_.addMessage(login, m, owner.accountId, unread);
    } else if (type == MessageType::Voice || type == MessageType::VideoNote) {
        const QJsonObject b = inner.bodyJson();
        const bool videoNote = type == MessageType::VideoNote;
        StoredMessage m;
        m.messageId = inner.messageId;
        m.timestamp = inner.sentAt;
        m.isMedia = true;
        m.isVoice = !videoNote;
        m.isVideoNote = videoNote;
        m.fileSize = optLong(b, "file_size").value_or(0);
        m.chunked = b.value("chunked").toBool();
        m.durationMs = optLong(b, "duration_ms");
        m.mediaId = json::string(b, "media_id");
        m.mediaKeyBase64 = json::string(b, "key");
        m.mediaNonceBase64 = json::optString(b, "nonce");
        m.mediaMacBase64 = json::optString(b, "mac");
        m.groupId = inner.groupId;
        m.replyToMessageId = inner.replyToMessageId;
        m.replyToPreview = inner.replyToPreview;
        chats_.addMessage(login, m, owner.accountId, unread);
    } else if (type == MessageType::MediaGroup) {
        const QJsonObject b = inner.bodyJson();
        const auto caption = json::optString(b, "caption");
        const auto textMessageId = json::optString(b, "text_message_id");
        QList<StoredMessage> list;
        if (caption && !caption->isEmpty() && textMessageId) {
            StoredMessage t;
            t.messageId = *textMessageId;
            t.text = *caption;
            t.timestamp = inner.sentAt;
            t.groupId = inner.groupId;
            list << t;
        }
        for (const QJsonValue &f : b.value("files").toArray()) {
            const QJsonObject fo = f.toObject();
            list << mediaMessageFromBody(json::string(fo, "message_id"), fo, inner.sentAt, inner.groupId);
        }
        chats_.addMessages(login, list, owner.accountId, unread);
    } else if (type == MessageType::CallMissed) {
        const QJsonObject b = inner.bodyJson();
        chats_.addCallLog(login, "incoming", "missed", optLong(b, "called_at").value_or(inner.sentAt), std::nullopt, owner.accountId, unread,
                          json::optString(b, "call_id"));
    } else if (type == MessageType::Reaction) {
        const QJsonObject b = inner.bodyJson();
        const auto target = json::optString(b, "target_id");
        if (!target) return;
        const auto emoji = json::optString(b, "emoji");
        chats_.setReaction(login, *target, false, emoji);
        if (emoji) Q_EMIT incomingReaction(login, *target);
    } else if (type == MessageType::Pin) {
        const QJsonObject b = inner.bodyJson();
        chats_.setPinned(login, b.value("pinned").toBool() ? json::optString(b, "target_id") : std::nullopt);
    } else if (type == MessageType::Edit) {
        const QJsonObject b = inner.bodyJson();
        const auto target = json::optString(b, "target_id"), text = json::optString(b, "text");
        if (target && text) chats_.editMessageText(login, *target, *text);
    } else if (type == MessageType::Delete) {
        const QStringList targets = strings(inner.bodyJson(), "target_ids");
        if (!targets.isEmpty()) Q_EMIT incomingDelete(login, targets);
        QList<StoredMessage> toPurge;
        for (const auto &m : chats_.messages(login)) {
            if (targets.contains(m.messageId)) toPurge << m;
        }
        chats_.deleteMessages(login, targets);
        if (purgeMedia_) purgeMedia_(toPurge);
    } else if (type == MessageType::ClearChat) {
        const auto all = chats_.messages(login);
        chats_.clearHistory(login);
        if (purgeMedia_) purgeMedia_(all);
    } else if (type == MessageType::DeleteChat) {
        const auto all = chats_.messages(login);
        chats_.removeChat(login);
        if (purgeMedia_) purgeMedia_(all);
    } else if (type == MessageType::ReadReceipt) {
        chats_.markMessagesRead(login, strings(inner.bodyJson(), "target_ids"));
    } else {
        log(QStringLiteral("Router: unknown inner type=%1 — ignored").arg(type));
    }
}

} // namespace osh
