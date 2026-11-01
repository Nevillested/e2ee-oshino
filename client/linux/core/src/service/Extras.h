#pragma once

// Стикеры, аватары и обои чатов (как Stickers.kt, Avatars/PeerProfiles, Wallpapers.kt).
//
// Стикеры: установленные паки и «Недавние» (15) — в хранилище; файлы — из ZIP пака
// в кэше; удалённый пак — заглушка. Аватары: файл на диске по account_id,
// обновляется по profile_updated. Обои: версии с сервера, файлы на диске,
// сверка при подключении и по wallpaper_changed.

#include "net/ApiClient.h"
#include "service/Infra.h"
#include "storage/Stores.h"

#include <QHash>
#include <QObject>
#include <QSet>

namespace osh {

class Stickers : public QObject {
    Q_OBJECT
public:
    static constexpr int MaxRecent = 15;
    enum class FileState { Ready, PackDeleted, Unavailable };
    struct Resolved {
        FileState state;
        QString path;
        bool animated = false;
    };

    Stickers(ApiClient &api, Session &session, SecureStore &secure, AppDirs dirs, QObject *parent = nullptr);
    const QList<StickerPackInfo> &installed() const { return installed_; }
    const QList<StickerInfo> &recent() const { return recent_; }

    void load();
    Task<void> sync();
    void recordRecent(const StickerInfo &s);
    std::optional<StickerPackInfo> knownPackOf(const QString &stickerId) const;
    Task<std::optional<StickerPackInfo>> fetchPackOf(QString stickerId);
    /// Пак стикера, если уже известен (установленный или виденный) — без сети.
    std::optional<StickerPackInfo> cachedPackOf(const QString &stickerId) const;
    Task<void> install(StickerPackInfo pack);
    Task<void> uninstall(QString packId);
    Task<void> deleteForever(QString packId);
    Task<StickerPackInfo> upload(QString title, QString archive, ProgressFn onProgress, std::function<void(const StickerUploadEvent &)> onEvent);
    std::optional<QString> cachedFile(const QString &stickerId) const;
    Task<Resolved> resolve(QString stickerId);
    int clearCache();
    void reset();

Q_SIGNALS:
    void changed();

private:
    Task<bool> ensurePack(StickerPackInfo pack);
    void remember(const StickerPackInfo &pack);
    void setInstalled(const QList<StickerPackInfo> &packs);
    void setRecent(const QList<StickerInfo> &stickers);
    void dropRecentOf(const QString &packId);
    QString dir() const;

    ApiClient &api_;
    Session &session_;
    SecureStore &secure_;
    AppDirs dirs_;
    QList<StickerPackInfo> installed_;
    QList<StickerInfo> recent_;
    QHash<QString, StickerPackInfo> packOfSticker_;
    KeyedMutex packLocks_;
    bool loaded_ = false;
};

/// Фото профиля (своё и собеседников): файл на диске, загрузка один раз, сброс по profile_updated.
class Avatars : public QObject {
    Q_OBJECT
public:
    Avatars(ApiClient &api, Session &session, AppDirs dirs, QObject *parent = nullptr);
    /// Путь к файлу, если уже скачан; иначе запускает загрузку и вернёт пусто.
    QString pathFor(const QString &accountId);
    Task<void> refresh(QString accountId);
    void invalidate(const QString &accountId);
    Task<void> uploadMine(QByteArray jpeg);
    Task<void> deleteMine();
    void reset();

Q_SIGNALS:
    void changed(const QString &accountId);

private:
    QString fileOf(const QString &accountId) const;
    ApiClient &api_;
    Session &session_;
    AppDirs dirs_;
    QSet<QString> loading_, checked_;
};

class Wallpapers : public QObject {
    Q_OBJECT
public:
    Wallpapers(ApiClient &api, Session &session, AppDirs dirs, QObject *parent = nullptr);
    QString file(const QString &peerAccountId) const;
    bool has(const QString &peerAccountId) const;
    Task<void> sync();
    Task<void> set(QString peerAccountId, QByteArray jpeg, bool forPeer);
    Task<void> remove(QString peerAccountId);
    void reset();

Q_SIGNALS:
    void changed(const QString &peerAccountId);

private:
    Task<void> download(QString accountId, QString token);
    void saveVersions();
    ApiClient &api_;
    Session &session_;
    QString dir_;
    QHash<QString, qint64> versions_;
};

} // namespace osh
