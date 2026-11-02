#pragma once

// Модели списков для QML: чаты и переписка открытого чата. Обновляются по
// сигналу ChatStore::changed.

#include "Core.h"

#include <QAbstractListModel>

class AppModel;

class ChatListModel : public QAbstractListModel {
    Q_OBJECT
    Q_PROPERTY(QString filter READ filter WRITE setFilter NOTIFY filterChanged)
public:
    enum Role {
        LoginRole = Qt::UserRole + 1,
        AccountIdRole,
        PreviewRole,
        TimeRole,
        UnreadRole,
        MutedRole,
        PinnedRole,
        IsMineRole,
        IsReadRole,
        AvatarRole,
        DeletedRole,
        BlockedRole,
        BlockedByMeRole,
    };
    ChatListModel(osh::Core &core, AppModel &app, QObject *parent = nullptr);
    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;
    QString filter() const { return filter_; }
    void setFilter(const QString &f);
    void reload();
    int totalUnread() const;

Q_SIGNALS:
    void filterChanged();

private:
    osh::Core &core_;
    AppModel &app_;
    QList<osh::ChatSummary> items_;
    QString filter_;
};

class MessageModel : public QAbstractListModel {
    Q_OBJECT
public:
    enum Role {
        IdRole = Qt::UserRole + 1,
        TextRole,
        MineRole,
        TimeRole,
        DateRole,
        StatusRole,
        KindRole,
        FileNameRole,
        FileSizeRole,
        MediaPathRole,
        VideoPathRole,
        ProgressRole,
        StepRole,
        StickerIdRole,
        StickerPathRole,
        StickerAnimatedRole,
        ReplyToIdRole,
        ReplyPreviewRole,
        EditedRole,
        MyReactionRole,
        PeerReactionRole,
        DurationRole,
        CallTextRole,
        GroupRole,
    };
    MessageModel(osh::Core &core, AppModel &app, QObject *parent = nullptr);
    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;
    void setPeer(const QString &login);
    QString peer() const { return peer_; }
    void reload();
    std::optional<osh::StoredMessage> find(const QString &id) const;
    void refreshMedia(const QString &mediaId);
    void refreshMessage(const QString &messageId);
    Q_INVOKABLE int indexOf(const QString &id) const;
    Q_INVOKABLE QString idAt(int row) const;
    /// Для режима выбора: {kind, mine, text, fileName} сообщения.
    Q_INVOKABLE QVariantMap brief(const QString &id) const;
    /// Поиск по переписке: id сообщений с текстом, содержащим [query] (без учёта регистра), по порядку.
    Q_INVOKABLE QStringList search(const QString &query) const;

private:
    void requestSticker(const QString &stickerId);
    osh::Core &core_;
    AppModel &app_;
    QString peer_;
    QList<osh::StoredMessage> items_;
    QHash<QString, std::pair<QString, bool>> stickerFiles_;
    QSet<QString> stickerLoading_;
};
