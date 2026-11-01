#include "Models.h"

#include "AppModel.h"

#include <QDateTime>
#include <QFile>
#include <QTimer>
#include <QUrl>

using namespace osh;

// ---------------- ChatListModel ----------------

ChatListModel::ChatListModel(Core &core, AppModel &app, QObject *parent) : QAbstractListModel(parent), core_(core), app_(app) {}

int ChatListModel::rowCount(const QModelIndex &parent) const { return parent.isValid() ? 0 : int(items_.size()); }

QHash<int, QByteArray> ChatListModel::roleNames() const {
    return {{LoginRole, "login"},     {AccountIdRole, "accountId"}, {PreviewRole, "preview"}, {TimeRole, "time"},
            {UnreadRole, "unread"},   {MutedRole, "muted"},         {PinnedRole, "pinned"},   {IsMineRole, "isMine"},
            {IsReadRole, "isRead"},   {AvatarRole, "avatar"},       {DeletedRole, "deleted"}, {BlockedRole, "blocked"}};
}

QVariant ChatListModel::data(const QModelIndex &index, int role) const {
    if (!index.isValid() || index.row() >= items_.size()) return {};
    const ChatSummary &c = items_[index.row()];
    switch (role) {
    case LoginRole: return c.peerLogin;
    case AccountIdRole: return c.lastKnownAccountId.value_or(QString());
    case PreviewRole: return app_.decodePreview(c.lastMessage);
    case TimeRole: return c.lastTimestamp > 0 ? app_.formatDay(c.lastTimestamp) : QString();
    case UnreadRole: return c.unreadCount;
    case MutedRole: return c.muted;
    case PinnedRole: return c.chatPinnedAt.has_value();
    case IsMineRole: return c.lastMessageIsMine;
    case IsReadRole: return c.lastMessageIsRead;
    case AvatarRole: return c.lastKnownAccountId ? const_cast<AppModel &>(app_).avatarFor(*c.lastKnownAccountId) : QString();
    case DeletedRole: return c.isDeleted;
    case BlockedRole: return c.blockedByMe || c.blockingMe;
    }
    return {};
}

void ChatListModel::setFilter(const QString &f) {
    if (f == filter_) return;
    filter_ = f;
    reload();
    Q_EMIT filterChanged();
}

void ChatListModel::reload() {
    QList<ChatSummary> next;
    for (const auto &c : core_.chats.knownPeers()) {
        if (filter_.isEmpty() || c.peerLogin.contains(filter_, Qt::CaseInsensitive)) next << c;
    }
    beginResetModel();
    items_ = next;
    endResetModel();
}

int ChatListModel::totalUnread() const {
    int n = 0;
    for (const auto &c : core_.chats.knownPeers()) n += c.muted ? 0 : c.unreadCount;
    return n;
}

// ---------------- MessageModel ----------------

MessageModel::MessageModel(Core &core, AppModel &app, QObject *parent) : QAbstractListModel(parent), core_(core), app_(app) {}

int MessageModel::rowCount(const QModelIndex &parent) const { return parent.isValid() ? 0 : int(items_.size()); }

QHash<int, QByteArray> MessageModel::roleNames() const {
    return {{IdRole, "messageId"},       {TextRole, "text"},           {MineRole, "mine"},
            {TimeRole, "time"},          {DateRole, "day"},            {StatusRole, "status"},
            {KindRole, "kind"},          {FileNameRole, "fileName"},   {FileSizeRole, "fileSize"},
            {MediaPathRole, "mediaPath"}, {VideoPathRole, "videoPath"}, {ProgressRole, "progress"},  {StepRole, "step"},
            {StickerIdRole, "stickerId"}, {StickerPathRole, "stickerPath"}, {StickerAnimatedRole, "stickerAnimated"}, {ReplyToIdRole, "replyToId"},
            {ReplyPreviewRole, "replyPreview"}, {EditedRole, "edited"}, {MyReactionRole, "myReaction"},
            {PeerReactionRole, "peerReaction"}, {DurationRole, "duration"}, {CallTextRole, "callText"},
            {GroupRole, "groupId"}};
}

namespace {
QString kindOf(const StoredMessage &m) {
    if (m.isCallLog) return "call";
    if (m.isUndecryptable) return "undecryptable";
    if (m.isSticker()) return "sticker";
    if (m.isVoice) return "voice";
    if (m.isVideoNote) return "videoNote";
    if (m.isMedia) return m.isFile ? "file" : m.isVideo ? "video" : "photo";
    return "text";
}
} // namespace

QVariant MessageModel::data(const QModelIndex &index, int role) const {
    if (!index.isValid() || index.row() >= items_.size()) return {};
    const StoredMessage &m = items_[index.row()];
    switch (role) {
    case IdRole: return m.messageId;
    case TextRole: return m.text;
    case MineRole: return m.isMine;
    case TimeRole: return app_.formatTime(m.timestamp);
    case DateRole: return app_.formatDay(m.timestamp);
    case StatusRole: return m.status;
    case KindRole: return kindOf(m);
    case FileNameRole: return m.fileName.value_or(QString());
    case FileSizeRole: return app_.formatSize(m.fileSize);
    case MediaPathRole: {
        if (m.localPreviewPath && QFile::exists(*m.localPreviewPath)) return QUrl::fromLocalFile(*m.localPreviewPath).toString();
        if (const auto spec = DownloadSpec::of(m, peer_); spec && core_.downloads.isCached(*spec)) {
            return QUrl::fromLocalFile(core_.downloads.cachedPath(*spec)).toString();
        }
        return QString();
    }
    // сам файл кружка (mediaPath у него — превью): своя запись или скачанный файл
    case VideoPathRole: {
        if (!m.isVideoNote) return QString();
        if (m.localSourcePath && QFile::exists(*m.localSourcePath)) return QUrl::fromLocalFile(*m.localSourcePath).toString();
        if (const auto spec = DownloadSpec::of(m, peer_); spec && core_.downloads.isCached(*spec)) {
            return QUrl::fromLocalFile(core_.downloads.cachedPath(*spec)).toString();
        }
        return QString();
    }
    case ProgressRole: {
        if (const auto p = core_.uploadProgress(m.messageId)) return *p;
        if (m.mediaId) {
            if (const auto p = core_.downloads.progress(*m.mediaId)) return *p;
        }
        return -1;
    }
    case StepRole: return m.processingStep ? app_.t(QString(*m.processingStep).replace('.', '_')) : QString();
    case StickerIdRole: return m.stickerId.value_or(QString());
    case StickerPathRole: {
        if (!m.stickerId) return QString();
        const auto it = stickerFiles_.find(*m.stickerId);
        if (it != stickerFiles_.end()) return it->first.isEmpty() ? QString() : QUrl::fromLocalFile(it->first).toString();
        if (const auto f = core_.stickers.cachedFile(*m.stickerId)) return QUrl::fromLocalFile(*f).toString();
        // не из data(): пак может оказаться в кэше, и dataChanged посреди вычисления привязки QML
        // даёт петлю — стикер так и остаётся пустым
        QTimer::singleShot(0, const_cast<MessageModel *>(this), [self = const_cast<MessageModel *>(this), id = *m.stickerId] { self->requestSticker(id); });
        return QString();
    }
    case StickerAnimatedRole: {
        if (!m.stickerId) return false;
        const auto it = stickerFiles_.find(*m.stickerId);
        if (it != stickerFiles_.end()) return it->second;
        const auto f = core_.stickers.cachedFile(*m.stickerId);
        return f && f->endsWith(".tgs");
    }
    case ReplyToIdRole: return m.replyToMessageId.value_or(QString());
    case ReplyPreviewRole: return m.replyToPreview.value_or(QString());
    case EditedRole: return m.edited;
    case MyReactionRole: return m.myReaction.value_or(QString());
    case PeerReactionRole: return m.peerReaction.value_or(QString());
    case DurationRole: {
        const qint64 s = m.durationMs.value_or(0) / 1000;
        return QStringLiteral("%1:%2").arg(s / 60).arg(s % 60, 2, 10, QLatin1Char('0'));
    }
    case CallTextRole: {
        if (!m.isCallLog) return QString();
        QString t = m.callOutcome == "answered" ? app_.t("call_answered") : m.callOutcome == "missed" ? app_.t("call_missed") : app_.t("call_noAnswer");
        if (m.callDurationSeconds && *m.callDurationSeconds > 0) {
            t += QStringLiteral(" · %1:%2").arg(*m.callDurationSeconds / 60).arg(*m.callDurationSeconds % 60, 2, 10, QLatin1Char('0'));
        }
        return t;
    }
    case GroupRole: return m.groupId.value_or(QString());
    }
    return {};
}

void MessageModel::requestSticker(const QString &stickerId) {
    if (stickerLoading_.contains(stickerId)) return;
    stickerLoading_.insert(stickerId);
    spawn([](MessageModel *self, Core &core, QString id) -> Task<void> {
        const Stickers::Resolved r = co_await core.stickers.resolve(id);
        self->stickerLoading_.remove(id);
        // нет сети — не запоминаем: следующий показ попробует снова
        if (r.state == Stickers::FileState::Unavailable) co_return;
        self->stickerFiles_.insert(id, {r.state == Stickers::FileState::Ready ? r.path : QString(), r.animated});
        for (int i = 0; i < self->items_.size(); ++i) {
            if (self->items_[i].stickerId == id) Q_EMIT self->dataChanged(self->index(i), self->index(i), {StickerPathRole, StickerAnimatedRole});
        }
    }(this, core_, stickerId));
}

void MessageModel::setPeer(const QString &login) {
    // другой чат — всегда полный сброс: вставка/удаление строк с анимацией показывали бы
    // на мгновение сообщения прошлого чата (переход в пустой чат = «удалить всё по одному»)
    peer_ = login;
    stickerFiles_.clear();
    beginResetModel();
    items_ = peer_.isEmpty() ? QList<StoredMessage>() : core_.chats.messages(peer_);
    endResetModel();
}

void MessageModel::reload() {
    QList<StoredMessage> next = peer_.isEmpty() ? QList<StoredMessage>() : core_.chats.messages(peer_);
    // тот же список, сообщения только поменялись — без сброса прокрутки
    if (next.size() == items_.size()) {
        bool sameIds = true;
        for (int i = 0; i < next.size() && sameIds; ++i) sameIds = next[i].messageId == items_[i].messageId;
        if (sameIds) {
            items_ = next;
            if (!items_.isEmpty()) Q_EMIT dataChanged(index(0), index(int(items_.size()) - 1));
            return;
        }
    }
    // добавились в конец — вставка, а не сброс
    if (next.size() > items_.size() && !items_.isEmpty() && next[items_.size() - 1].messageId == items_.last().messageId) {
        beginInsertRows({}, int(items_.size()), int(next.size()) - 1);
        items_ = next;
        endInsertRows();
        return;
    }
    // часть сообщений удалили, порядок остальных тот же — убираем строки по одной (с анимацией)
    if (next.size() < items_.size()) {
        QSet<QString> keep;
        for (const auto &m : next) keep.insert(m.messageId);
        QList<StoredMessage> rest;
        for (const auto &m : items_) {
            if (keep.contains(m.messageId)) rest << m;
        }
        bool sameOrder = rest.size() == next.size();
        for (int i = 0; i < rest.size() && sameOrder; ++i) sameOrder = rest[i].messageId == next[i].messageId;
        if (sameOrder) {
            for (int i = int(items_.size()) - 1; i >= 0; --i) {
                if (keep.contains(items_[i].messageId)) continue;
                beginRemoveRows({}, i, i);
                items_.removeAt(i);
                endRemoveRows();
            }
            items_ = next;
            if (!items_.isEmpty()) Q_EMIT dataChanged(index(0), index(int(items_.size()) - 1));
            return;
        }
    }
    beginResetModel();
    items_ = next;
    endResetModel();
}

std::optional<StoredMessage> MessageModel::find(const QString &id) const {
    for (const auto &m : items_) {
        if (m.messageId == id) return m;
    }
    return std::nullopt;
}

int MessageModel::indexOf(const QString &id) const {
    for (int i = 0; i < items_.size(); ++i) {
        if (items_[i].messageId == id) return i;
    }
    return -1;
}

void MessageModel::refreshMedia(const QString &mediaId) {
    for (int i = 0; i < items_.size(); ++i) {
        if (items_[i].mediaId == mediaId) Q_EMIT dataChanged(index(i), index(i), {MediaPathRole, VideoPathRole, ProgressRole});
    }
}

void MessageModel::refreshMessage(const QString &messageId) {
    const int i = indexOf(messageId);
    if (i >= 0) Q_EMIT dataChanged(index(i), index(i), {ProgressRole, StepRole, StatusRole});
}
