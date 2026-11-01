#include "service/Media.h"

#include "crypto/FileCiphers.h"
#include "support/Log.h"

#include <QDateTime>
#include <QDir>
#include <QFile>

namespace osh {

namespace {
constexpr int StepAttempts = 5;
constexpr qint64 FailCooldownMs = 20000;

QString what(const std::exception &e) { return QString::fromUtf8(e.what()); }

/// Один сетевой шаг: до [StepAttempts] попыток с нарастающей паузой 2 → 30 с.
template <typename F>
auto retryStep(QString label, F step) -> decltype(step()) {
    int delayMs = 2000;
    for (int attempt = 1;; ++attempt) {
        try {
            co_return co_await step();
        } catch (const std::exception &e) {
            if (attempt >= StepAttempts) {
                logError(QStringLiteral("MediaUploader[%1] failed after %2 attempts: %3").arg(label).arg(attempt).arg(what(e)));
                throw;
            }
            log(QStringLiteral("MediaUploader[%1] attempt %2/%3 failed: %4 — retry").arg(label).arg(attempt).arg(StepAttempts).arg(what(e)));
        }
        co_await delay{delayMs};
        delayMs = std::min(delayMs * 2, 30000);
    }
}
} // namespace

// ---------------- MediaUploader ----------------

MediaUploader::MediaUploader(ApiClient &api, ChatStore &chats, AppDirs dirs, ChunkedUploadSessionStore &sessions, MediaFiles &media)
    : api_(api), chats_(chats), dirs_(std::move(dirs)), sessions_(sessions), media_(media) {}

QString MediaUploader::encryptedTempFile(const QString &messageId) const {
    const QString d = dirs_.data + "/chunked_uploads";
    QDir().mkpath(d);
    return d + "/enc_" + messageId + ".bin";
}

Task<MediaRef> MediaUploader::upload(QString peerLogin, QString messageId, QString source, qint64 size, std::optional<QString> fileName, QString token,
                                     QString recipientAccountId, ProgressFn onProgress) {
    chats_.updateProcessingStep(peerLogin, messageId, UploadStep::Encrypting);
    // не «x = cond ? co_await a : co_await b»: такое GCC 11 собирает с двойным освобождением
    // (временный объект невыбранной ветки) — порча кучи и вылет после каждой загрузки
    MediaRef ref;
    if (size > StreamingFileCipher::StreamingThresholdBytes) {
        ref = co_await uploadChunked(peerLogin, messageId, source, size, fileName, token, recipientAccountId, onProgress);
    } else {
        ref = co_await uploadWhole(peerLogin, messageId, source, size, fileName, token, recipientAccountId, onProgress);
    }
    chats_.updateMediaInfo(peerLogin, messageId, ref.mediaId, ref.keyBase64, ref.nonceBase64, ref.macBase64);
    chats_.update(peerLogin, messageId, [&](StoredMessage &m) {
        m.fileSize = ref.fileSize;
        m.chunked = ref.chunked;
    });
    co_return ref;
}

Task<MediaRef> MediaUploader::uploadWhole(QString peer, QString messageId, QString source, qint64 size, std::optional<QString> fileName,
                                          QString token, QString recipient, ProgressFn onProgress) {
    Q_UNUSED(fileName)
    const QString temp = dirs_.temp + "/enc_" + messageId + ".bin";
    struct Sealed {
        EncryptedFile enc;
        QByteArray plain;
    };
    auto seal = [source, temp]() -> Sealed {
        QFile in(source);
        if (!in.open(QIODevice::ReadOnly)) throw std::runtime_error("не прочитать файл для отправки");
        Sealed s{{}, in.readAll()};
        s.enc = MediaCipher::encrypt(s.plain);
        QFile out(temp);
        if (!out.open(QIODevice::WriteOnly | QIODevice::Truncate) || out.write(s.enc.ciphertext) != s.enc.ciphertext.size()) {
            throw std::runtime_error("не записать зашифрованный файл");
        }
        return s;
    };
    const Sealed sealed = co_await runInThread(seal);
    chats_.updateProcessingStep(peer, messageId, UploadStep::Uploading);
    QString mediaId;
    try {
        // сбой сети (в т.ч. оборванный при смене сети запрос) — повтор с начала файла
        auto step = [&]() { return api_.uploadEncryptedMediaFile(token, temp, recipient, onProgress); };
        mediaId = co_await retryStep("whole", step);
    } catch (...) {
        QFile::remove(temp);
        throw;
    }
    QFile::remove(temp);
    // свой файл не придётся скачивать обратно
    QFile cache(media_.cacheFile(mediaId));
    if (cache.open(QIODevice::WriteOnly | QIODevice::Truncate)) cache.write(sealed.plain);
    co_return MediaRef{mediaId, b64(sealed.enc.key), b64(sealed.enc.nonce), b64(sealed.enc.mac), size, false};
}

Task<MediaRef> MediaUploader::uploadChunked(QString peer, QString messageId, QString source, qint64 size, std::optional<QString> fileName,
                                            QString token, QString recipient, ProgressFn onProgress) {
    Q_UNUSED(fileName)
    const QString encFile = encryptedTempFile(messageId);
    std::optional<ChunkedUploadSessionStore::Entry> session = sessions_.get(messageId);
    QSet<int> confirmed;
    if (session && QFile::exists(encFile)) {
        try {
            auto step = [&]() { return api_.listChunkedParts(token, session->mediaId, session->uploadId); };
            confirmed = co_await retryStep("list-parts", step);
        } catch (const std::exception &e) {
            // сессия на сервере протухла — начинаем с нуля
            log(QStringLiteral("MediaUploader: resume of %1 failed (%2) — starting over").arg(messageId, what(e)));
            sessions_.clear(messageId);
            session.reset();
        }
    } else if (session) {
        sessions_.clear(messageId);
        session.reset();
    }
    if (!session) {
        auto encrypt = [source, encFile] { return StreamingFileCipher::encryptFile(source, encFile); };
        const QByteArray key = co_await runInThread(encrypt);
        const qint64 encSize = QFile(encFile).size();
        auto step = [&]() { return api_.initChunkedUpload(token, encSize); };
        const ChunkedUploadInit init = co_await retryStep("init", step);
        session = ChunkedUploadSessionStore::Entry{init.mediaId, init.uploadId, init.partSize, b64(key)};
        sessions_.save(messageId, *session);
    }
    chats_.updateProcessingStep(peer, messageId, UploadStep::Uploading);

    const qint64 total = QFile(encFile).size();
    const qint64 partSize = session->partSize;
    const int partCount = int((total + partSize - 1) / partSize);
    auto partLen = [&](int pn) { return int(std::min(partSize, total - qint64(pn - 1) * partSize)); };
    qint64 confirmedBytes = 0;
    for (int pn : confirmed) {
        if (pn >= 1 && pn <= partCount) confirmedBytes += partLen(pn);
    }
    if (onProgress && total > 0) onProgress(confirmedBytes * 100.0 / total);
    QFile in(encFile);
    if (!in.open(QIODevice::ReadOnly)) throw ApiError("error.uploadFailed");
    for (int pn = 1; pn <= std::max(partCount, 1); ++pn) {
        if (confirmed.contains(pn)) continue;
        in.seek(qint64(pn - 1) * partSize);
        const QByteArray chunk = in.read(partLen(pn));
        const qint64 before = confirmedBytes;
        ProgressFn partProgress;
        if (onProgress) {
            partProgress = [onProgress, before, total, n = chunk.size()](double pct) { onProgress((before + pct / 100 * n) * 100.0 / total); };
        }
        auto upload = [&]() { return api_.uploadChunkedPart(token, session->mediaId, session->uploadId, pn, chunk, partProgress); };
        co_await retryStep(QStringLiteral("part %1").arg(pn), upload);
        confirmedBytes += chunk.size();
        if (onProgress && total > 0) onProgress(confirmedBytes * 100.0 / total);
    }
    in.close();
    auto complete = [&]() { return api_.completeChunkedUpload(token, session->mediaId, session->uploadId, recipient); };
    co_await retryStep("complete", complete);
    sessions_.clear(messageId);
    QFile::remove(encFile);
    QFile::remove(media_.cacheFile(session->mediaId));
    QFile::copy(source, media_.cacheFile(session->mediaId));
    co_return MediaRef{session->mediaId, session->keyBase64, std::nullopt, std::nullopt, size, true};
}

// ---------------- MediaDownloadManager ----------------

std::optional<DownloadSpec> DownloadSpec::of(const StoredMessage &m, const QString &peerLogin) {
    if (!m.mediaId || !m.mediaKeyBase64) return std::nullopt;
    return DownloadSpec{*m.mediaId, *m.mediaKeyBase64, m.chunked, m.mediaNonceBase64, m.mediaMacBase64, m.fileSize, peerLogin, m.fileName};
}

MediaDownloadManager::MediaDownloadManager(ApiClient &api, Session &session, MediaFiles &media, QObject *parent)
    : QObject(parent), api_(api), session_(session), media_(media) {}

QString MediaDownloadManager::cachedPath(const DownloadSpec &spec) const { return media_.cacheFile(spec.mediaId); }
bool MediaDownloadManager::isCached(const DownloadSpec &spec) const { return QFile::exists(cachedPath(spec)); }

std::optional<double> MediaDownloadManager::progress(const QString &mediaId) const {
    const auto it = progress_.find(mediaId);
    return it == progress_.end() ? std::nullopt : std::optional(*it);
}

QList<DownloadSpec> MediaDownloadManager::manualQueue() const {
    QList<DownloadSpec> out;
    for (const auto &id : manual_.queue) out << specs_.value(id);
    return out;
}

QList<DownloadSpec> MediaDownloadManager::autoQueue() const {
    QList<DownloadSpec> out;
    for (const auto &id : auto_.queue) out << specs_.value(id);
    return out;
}

void MediaDownloadManager::requestUserDownload(const DownloadSpec &spec) {
    specs_[spec.mediaId] = spec;
    failedAt_.remove(spec.mediaId);
    cancelled_.remove(spec.mediaId);
    auto &aq = auto_.queue;
    if (auto_.active != spec.mediaId) aq.erase(std::remove(aq.begin(), aq.end(), spec.mediaId), aq.end());
    if (std::find(manual_.queue.begin(), manual_.queue.end(), spec.mediaId) == manual_.queue.end() && auto_.active != spec.mediaId) {
        manual_.queue.push_back(spec.mediaId);
    }
    Q_EMIT queuesChanged();
    kick(true);
}

void MediaDownloadManager::requestAutoDownload(const DownloadSpec &spec) {
    if (spec.plaintextSize >= AutoDownloadLimitBytes || isCached(spec)) return;
    const auto inQueue = [&](const Lane &l) {
        return l.active == spec.mediaId || std::find(l.queue.begin(), l.queue.end(), spec.mediaId) != l.queue.end();
    };
    if (inQueue(manual_) || inQueue(auto_)) return;
    if (const auto t = failedAt_.find(spec.mediaId); t != failedAt_.end() && QDateTime::currentMSecsSinceEpoch() - *t < FailCooldownMs) return;
    specs_[spec.mediaId] = spec;
    auto_.queue.push_back(spec.mediaId);
    Q_EMIT queuesChanged();
    kick(false);
}

void MediaDownloadManager::cancel(const QString &mediaId) {
    for (Lane *l : {&manual_, &auto_}) {
        l->queue.erase(std::remove(l->queue.begin(), l->queue.end(), mediaId), l->queue.end());
        if (l->active == mediaId) cancelled_.insert(mediaId);
    }
    if (auto w = waiters_.take(mediaId); true) w.fail(std::make_exception_ptr(ApiError("error.cancelledByUser")));
    Q_EMIT queuesChanged();
}

Task<QString> MediaDownloadManager::ensureDownloaded(DownloadSpec spec) {
    if (isCached(spec)) co_return cachedPath(spec);
    auto it = waiters_.find(spec.mediaId);
    if (it == waiters_.end()) it = waiters_.insert(spec.mediaId, Deferred<QString>());
    const Deferred<QString> waiter = *it;
    requestUserDownload(spec);
    co_return *(co_await waiter.wait());
}

void MediaDownloadManager::kick(bool manual) {
    Lane &lane = manual ? manual_ : auto_;
    if (lane.active || lane.queue.empty()) return;
    const QString next = lane.queue.front();
    lane.queue.pop_front();
    lane.active = next;
    Q_EMIT queuesChanged();
    spawn(run(specs_.value(next), manual));
}

Task<void> MediaDownloadManager::run(DownloadSpec spec, bool manual) {
    const QString id = spec.mediaId;
    try {
        const QString file = co_await downloadAndDecrypt(spec);
        if (auto w = waiters_.take(id); true) w.resolve(file);
        Q_EMIT finished(id, file);
    } catch (const std::exception &e) {
        if (cancelled_.remove(id)) {
            log(QStringLiteral("Download %1 cancelled").arg(id));
        } else {
            logError(QStringLiteral("Download %1 failed: %2").arg(id, what(e)));
            failedAt_[id] = QDateTime::currentMSecsSinceEpoch();
            if (auto w = waiters_.take(id); true) w.fail(std::current_exception());
            Q_EMIT failed(id);
        }
    }
    progress_.remove(id);
    (manual ? manual_ : auto_).active.reset();
    Q_EMIT queuesChanged();
    kick(manual);
}

Task<QString> MediaDownloadManager::downloadAndDecrypt(DownloadSpec spec) {
    const auto token = session_.token();
    if (!token) throw ApiError("error.notSignedIn");
    const QString part = media_.partialFile(spec.mediaId);
    const QString id = spec.mediaId;
    auto onProgress = [this, id](double pct) {
        if (cancelled_.contains(id)) return;
        progress_[id] = pct * 0.95;
        Q_EMIT progressChanged(id, pct * 0.95);
    };
    int delayMs = 1000;
    for (int attempt = 1;; ++attempt) {
        bool done = false;
        try {
            co_await api_.downloadEncryptedMediaResumable(*token, id, part, std::nullopt, onProgress);
            done = true;
        } catch (const std::exception &) {
            if (attempt >= 3 || cancelled_.contains(id)) throw;
        }
        if (done) break;
        co_await delay{delayMs};
        delayMs *= 2;
    }
    if (cancelled_.contains(id)) throw ApiError("error.cancelledByUser");
    const QString out = media_.cacheFile(id);
    try {
        auto decrypt = [spec, part, out] {
            const QByteArray key = unb64(spec.keyBase64);
            if (spec.chunked) {
                StreamingFileCipher::decryptFile(part, out, key);
            } else {
                if (!spec.nonceBase64 || !spec.macBase64) throw std::runtime_error("нет nonce/mac у нечанкового файла");
                QFile in(part);
                if (!in.open(QIODevice::ReadOnly)) throw std::runtime_error("не прочитать скачанный файл");
                const QByteArray plain = MediaCipher::decrypt(key, unb64(*spec.nonceBase64), unb64(*spec.macBase64), in.readAll());
                QFile f(out);
                if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate) || f.write(plain) != plain.size()) throw std::runtime_error("не записать файл");
            }
        };
        co_await runInThread(decrypt);
    } catch (...) {
        // испорченный хвост не докачивать снова — в следующий раз с нуля
        QFile::remove(part);
        throw;
    }
    QFile::remove(part);
    progress_[id] = 100;
    Q_EMIT progressChanged(id, 100);
    co_await api_.confirmMediaReceived(*token, id);
    co_return out;
}

} // namespace osh
