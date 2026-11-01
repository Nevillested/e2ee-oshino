#pragma once

// Вложения (как MediaUploader.kt + MediaDownloadManager.kt).
//
// MediaUploader: файл ≤ 20 МБ — целиком одним AES-GCM и одним запросом; больше —
// потоково блоками 4 МБ и частями с докачкой (сессия загрузки сохраняется, после
// перезапуска сервер говорит, какие части уже есть). Каждый сетевой шаг — до 5
// попыток с паузой 2 → 30 с. Шифрование — в пуле потоков.
//
// MediaDownloadManager: две очереди по одному файлу — ручная (тап, просмотр) и
// авто (мелкие < 3 МБ, фоном). Недокачанный хвост докачивается по Range;
// после сбоя — 20 с без авто-повторов. Готовый файл — в кэше; серверу
// сообщаем, что файл забран.

#include "net/ApiClient.h"
#include "protocol/InnerMessage.h"
#include "storage/ChatStore.h"
#include "storage/Stores.h"

#include <QHash>
#include <QObject>
#include <deque>

namespace osh {

namespace UploadStep {
inline const QString Queued = QStringLiteral("chat.queued");
inline const QString Encrypting = QStringLiteral("chat.encrypting");
inline const QString Uploading = QStringLiteral("chat.uploading");
} // namespace UploadStep

class MediaUploader {
public:
    MediaUploader(ApiClient &api, ChatStore &chats, AppDirs dirs, ChunkedUploadSessionStore &sessions, MediaFiles &media);
    Task<MediaRef> upload(QString peerLogin, QString messageId, QString source, qint64 size, std::optional<QString> fileName, QString token,
                          QString recipientAccountId, ProgressFn onProgress = {});

private:
    Task<MediaRef> uploadWhole(QString peer, QString messageId, QString source, qint64 size, std::optional<QString> fileName, QString token,
                               QString recipient, ProgressFn onProgress);
    Task<MediaRef> uploadChunked(QString peer, QString messageId, QString source, qint64 size, std::optional<QString> fileName, QString token,
                                 QString recipient, ProgressFn onProgress);
    QString encryptedTempFile(const QString &messageId) const;

    ApiClient &api_;
    ChatStore &chats_;
    AppDirs dirs_;
    ChunkedUploadSessionStore &sessions_;
    MediaFiles &media_;
};

/// Что нужно для скачивания вложения (из StoredMessage).
struct DownloadSpec {
    QString mediaId;
    QString keyBase64;
    bool chunked = false;
    std::optional<QString> nonceBase64, macBase64;
    qint64 plaintextSize = 0;
    QString peerLogin;
    std::optional<QString> fileName;
    static std::optional<DownloadSpec> of(const StoredMessage &m, const QString &peerLogin);
};

class MediaDownloadManager : public QObject {
    Q_OBJECT
public:
    static constexpr qint64 AutoDownloadLimitBytes = 3 * 1024 * 1024;
    MediaDownloadManager(ApiClient &api, Session &session, MediaFiles &media, QObject *parent = nullptr);

    QString cachedPath(const DownloadSpec &spec) const;
    bool isCached(const DownloadSpec &spec) const;
    void requestUserDownload(const DownloadSpec &spec);
    void requestAutoDownload(const DownloadSpec &spec);
    void cancel(const QString &mediaId);
    /// Файл нужен экрану: есть — сразу, иначе — в ручную очередь и ждём.
    Task<QString> ensureDownloaded(DownloadSpec spec);
    std::optional<double> progress(const QString &mediaId) const;
    QList<DownloadSpec> manualQueue() const;
    QList<DownloadSpec> autoQueue() const;

Q_SIGNALS:
    void progressChanged(const QString &mediaId, double percent);
    void finished(const QString &mediaId, const QString &path);
    void failed(const QString &mediaId);
    void queuesChanged();

private:
    struct Lane {
        std::deque<QString> queue;
        std::optional<QString> active;
    };
    void kick(bool manual);
    Task<void> run(DownloadSpec spec, bool manual);
    Task<QString> downloadAndDecrypt(DownloadSpec spec);

    ApiClient &api_;
    Session &session_;
    MediaFiles &media_;
    Lane manual_, auto_;
    QHash<QString, DownloadSpec> specs_;
    QHash<QString, qint64> failedAt_;
    QHash<QString, double> progress_;
    QHash<QString, Deferred<QString>> waiters_;
    QSet<QString> cancelled_;
};

} // namespace osh
