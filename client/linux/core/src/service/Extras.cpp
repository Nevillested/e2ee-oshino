#include "service/Extras.h"

#include "support/Json.h"
#include "support/Log.h"
#include "support/Zip.h"

#include <QDir>
#include <QFile>
#include <QSaveFile>

namespace osh {

namespace {
const char *KeyInstalled = "sticker_packs_installed";
const char *KeyRecent = "sticker_recent";
constexpr qint64 MaxStickerBytes = 512 * 1024;

QString what(const std::exception &e) { return QString::fromUtf8(e.what()); }

QJsonObject stickerToJson(const StickerInfo &s) { return {{"id", s.id}, {"format", s.format}, {"pack_id", s.packId}}; }
StickerInfo stickerFromJson(const QJsonObject &j) { return {j.value("id").toString(), j.value("format").toString(), j.value("pack_id").toString()}; }

QJsonObject packToJson(const StickerPackInfo &p) {
    QJsonArray st;
    for (const auto &s : p.stickers) st.append(stickerToJson(s));
    return {{"id", p.id}, {"title", p.title}, {"is_owner", p.isOwner}, {"installed", p.installed}, {"deleted", p.deleted}, {"stickers", st}};
}

StickerPackInfo packFromJson(const QJsonObject &j) {
    StickerPackInfo p = ApiClient::parseStickerPack(j);
    return p;
}

bool writeFile(const QString &path, const QByteArray &data) {
    QSaveFile f(path);
    return f.open(QIODevice::WriteOnly) && f.write(data) == data.size() && f.commit();
}
} // namespace

// ---------------- Stickers ----------------

Stickers::Stickers(ApiClient &api, Session &session, SecureStore &secure, AppDirs dirs, QObject *parent)
    : QObject(parent), api_(api), session_(session), secure_(secure), dirs_(std::move(dirs)) {}

QString Stickers::dir() const {
    const QString d = dirs_.cache + "/stickers";
    QDir().mkpath(d);
    return d;
}

void Stickers::remember(const StickerPackInfo &pack) {
    for (const auto &s : pack.stickers) packOfSticker_[s.id] = pack;
}

void Stickers::load() {
    if (loaded_) return;
    loaded_ = true;
    try {
        if (const auto raw = secure_.read(KeyInstalled)) {
            for (const QJsonValue &v : QJsonDocument::fromJson(raw->toUtf8()).array()) installed_ << packFromJson(v.toObject());
        }
        if (const auto raw = secure_.read(KeyRecent)) {
            for (const QJsonValue &v : QJsonDocument::fromJson(raw->toUtf8()).array()) recent_ << stickerFromJson(v.toObject());
        }
    } catch (const std::exception &e) {
        logError(QStringLiteral("Stickers load failed: %1").arg(what(e)));
    }
    for (const auto &p : installed_) remember(p);
}

Task<void> Stickers::sync() {
    load();
    const auto token = session_.token();
    if (!token) co_return;
    QList<StickerPackInfo> packs;
    try {
        packs = co_await api_.getMyStickerPacks(*token);
    } catch (const std::exception &e) {
        logError(QStringLiteral("Stickers sync failed: %1").arg(what(e)));
        co_return;
    }
    for (const auto &p : packs) remember(p);
    setInstalled(packs);
}

void Stickers::setInstalled(const QList<StickerPackInfo> &packs) {
    installed_ = packs;
    QJsonArray arr;
    for (const auto &p : packs) arr.append(packToJson(p));
    secure_.write(KeyInstalled, json::compact(arr));
    Q_EMIT changed();
}

void Stickers::setRecent(const QList<StickerInfo> &stickers) {
    recent_ = stickers;
    QJsonArray arr;
    for (const auto &s : stickers) arr.append(stickerToJson(s));
    secure_.write(KeyRecent, json::compact(arr));
    Q_EMIT changed();
}

void Stickers::recordRecent(const StickerInfo &s) {
    QList<StickerInfo> list{s};
    for (const auto &r : recent_) {
        if (r.id != s.id && list.size() < MaxRecent) list << r;
    }
    setRecent(list);
}

void Stickers::dropRecentOf(const QString &packId) {
    QList<StickerInfo> list;
    for (const auto &r : recent_) {
        if (r.packId != packId) list << r;
    }
    if (list.size() != recent_.size()) setRecent(list);
}

std::optional<StickerPackInfo> Stickers::knownPackOf(const QString &stickerId) const {
    for (const auto &p : installed_) {
        for (const auto &s : p.stickers) {
            if (s.id == stickerId) {
                StickerPackInfo copy = p;
                copy.installed = true;
                return copy;
            }
        }
    }
    const auto it = packOfSticker_.find(stickerId);
    if (it == packOfSticker_.end()) return std::nullopt;
    StickerPackInfo copy = *it;
    copy.installed = std::any_of(installed_.begin(), installed_.end(), [&](const StickerPackInfo &p) { return p.id == copy.id; });
    return copy;
}

Task<std::optional<StickerPackInfo>> Stickers::fetchPackOf(QString stickerId) {
    const auto token = session_.token();
    if (!token) co_return std::nullopt;
    auto pack = co_await api_.getStickerPackBySticker(*token, stickerId);
    if (pack) remember(*pack);
    co_return pack;
}

std::optional<StickerPackInfo> Stickers::cachedPackOf(const QString &stickerId) const {
    if (const auto it = packOfSticker_.find(stickerId); it != packOfSticker_.end()) return *it;
    for (const auto &p : installed_) {
        if (std::any_of(p.stickers.begin(), p.stickers.end(), [&](const StickerInfo &s) { return s.id == stickerId; })) return p;
    }
    return std::nullopt;
}

Task<void> Stickers::install(StickerPackInfo pack) {
    co_await api_.installStickerPack(session_.token().value_or(QString()), pack.id);
    remember(pack);
    pack.installed = true;
    QList<StickerPackInfo> list{pack};
    for (const auto &p : installed_) {
        if (p.id != pack.id) list << p;
    }
    setInstalled(list);
}

Task<void> Stickers::uninstall(QString packId) {
    co_await api_.uninstallStickerPack(session_.token().value_or(QString()), packId);
    QList<StickerPackInfo> list;
    for (const auto &p : installed_) {
        if (p.id != packId) list << p;
    }
    setInstalled(list);
}

Task<void> Stickers::deleteForever(QString packId) {
    co_await api_.deleteStickerPack(session_.token().value_or(QString()), packId);
    QList<StickerPackInfo> list;
    for (const auto &p : installed_) {
        if (p.id != packId) list << p;
    }
    setInstalled(list);
    dropRecentOf(packId);
}

Task<StickerPackInfo> Stickers::upload(QString title, QString archive, ProgressFn onProgress, std::function<void(const StickerUploadEvent &)> onEvent) {
    const StickerPackInfo pack = co_await api_.uploadStickerPack(session_.token().value_or(QString()), title, archive, onProgress, onEvent);
    remember(pack);
    QList<StickerPackInfo> list{pack};
    for (const auto &p : installed_) {
        if (p.id != pack.id) list << p;
    }
    setInstalled(list);
    co_return pack;
}

std::optional<QString> Stickers::cachedFile(const QString &stickerId) const {
    for (const char *fmt : {"webp", "png", "tgs"}) {
        const QString p = dir() + "/" + stickerId + "." + QLatin1String(fmt);
        if (QFile::exists(p)) return p;
    }
    return std::nullopt;
}

Task<Stickers::Resolved> Stickers::resolve(QString stickerId) {
    if (const auto f = cachedFile(stickerId)) co_return Resolved{FileState::Ready, *f, f->endsWith(".tgs")};
    std::optional<StickerPackInfo> pack;
    try {
        if (const auto it = packOfSticker_.find(stickerId); it != packOfSticker_.end()) pack = *it;
        else pack = co_await fetchPackOf(stickerId);
    } catch (const std::exception &e) {
        logError(QStringLiteral("Stickers pack lookup failed sticker=%1: %2").arg(stickerId, what(e)));
        co_return Resolved{FileState::Unavailable, {}};
    }
    if (!pack || pack->deleted) co_return Resolved{FileState::PackDeleted, {}};
    bool ok = false;
    try {
        ok = co_await ensurePack(*pack);
    } catch (const std::exception &e) {
        logError(QStringLiteral("Stickers pack download failed pack=%1: %2").arg(pack->id, what(e)));
        co_return Resolved{FileState::Unavailable, {}};
    }
    if (!ok) co_return Resolved{FileState::PackDeleted, {}};
    if (const auto f = cachedFile(stickerId)) co_return Resolved{FileState::Ready, *f, f->endsWith(".tgs")};
    co_return Resolved{FileState::Unavailable, {}};
}

Task<bool> Stickers::ensurePack(StickerPackInfo pack) {
    auto guard = co_await packLocks_[pack.id].lock();
    const QString d = dir();
    if (std::all_of(pack.stickers.begin(), pack.stickers.end(), [&](const StickerInfo &s) { return QFile::exists(d + "/" + s.id + "." + s.format); })) {
        co_return true;
    }
    const QString zip = d + "/.pack-" + pack.id + ".zip";
    bool ok = false;
    try {
        ok = co_await api_.downloadStickerPack(session_.token().value_or(QString()), pack.id, zip);
    } catch (...) {
        QFile::remove(zip);
        throw;
    }
    if (!ok) {
        QFile::remove(zip);
        packOfSticker_.removeIf([&](const auto &it) { return it.value().id == pack.id; });
        dropRecentOf(pack.id);
        co_return false;
    }
    QSet<QString> wanted;
    for (const auto &s : pack.stickers) wanted.insert(s.id + "." + s.format);
    auto extract = [zip, d, wanted] {
        forEachZipEntry(zip, MaxStickerBytes, [&](const QString &name, const QByteArray &data) {
            if (wanted.contains(name)) writeFile(d + "/" + name, data);
        });
    };
    co_await runInThread(extract);
    QFile::remove(zip);
    Q_EMIT changed();
    co_return true;
}

int Stickers::clearCache() {
    int n = 0;
    for (const QFileInfo &f : QDir(dir()).entryInfoList(QDir::Files | QDir::Hidden)) n += QFile::remove(f.filePath()) ? 1 : 0;
    Q_EMIT changed();
    return n;
}

void Stickers::reset() {
    loaded_ = false;
    installed_.clear();
    recent_.clear();
    packOfSticker_.clear();
    Q_EMIT changed();
}

// ---------------- Avatars ----------------

Avatars::Avatars(ApiClient &api, Session &session, AppDirs dirs, QObject *parent)
    : QObject(parent), api_(api), session_(session), dirs_(std::move(dirs)) {}

QString Avatars::fileOf(const QString &accountId) const {
    const QString d = dirs_.cache + "/avatars";
    QDir().mkpath(d);
    return d + "/" + accountId + ".jpg";
}

QString Avatars::pathFor(const QString &accountId) {
    if (accountId.isEmpty()) return {};
    const QString f = fileOf(accountId);
    if (!checked_.contains(accountId) && !loading_.contains(accountId)) spawn(refresh(accountId));
    return QFile::exists(f) ? f : QString();
}

Task<void> Avatars::refresh(QString accountId) {
    const auto token = session_.token();
    if (!token || loading_.contains(accountId)) co_return;
    loading_.insert(accountId);
    try {
        const bool mine = session_.accountId() == accountId;
        std::optional<QByteArray> bytes;
        if (mine) bytes = co_await api_.getMyAvatar(*token);
        else bytes = co_await api_.getAvatar(*token, accountId);
        checked_.insert(accountId);
        const QString f = fileOf(accountId);
        const bool had = QFile::exists(f);
        if (bytes) {
            QFile old(f);
            const bool same = had && old.open(QIODevice::ReadOnly) && old.readAll() == *bytes;
            if (!same && writeFile(f, *bytes)) Q_EMIT changed(accountId);
        } else if (had) {
            QFile::remove(f);
            Q_EMIT changed(accountId);
        }
    } catch (const std::exception &) {
        // нет связи — попробуем при следующем показе
    }
    loading_.remove(accountId);
}

void Avatars::invalidate(const QString &accountId) {
    checked_.remove(accountId);
    spawn(refresh(accountId));
}

Task<void> Avatars::uploadMine(QByteArray jpeg) {
    co_await api_.uploadAvatar(session_.token().value_or(QString()), jpeg);
    if (const auto me = session_.accountId()) {
        writeFile(fileOf(*me), jpeg);
        Q_EMIT changed(*me);
    }
}

Task<void> Avatars::deleteMine() {
    co_await api_.deleteAvatar(session_.token().value_or(QString()));
    if (const auto me = session_.accountId()) {
        QFile::remove(fileOf(*me));
        Q_EMIT changed(*me);
    }
}

void Avatars::reset() {
    checked_.clear();
    QDir(dirs_.cache + "/avatars").removeRecursively();
}

// ---------------- Wallpapers ----------------

Wallpapers::Wallpapers(ApiClient &api, Session &session, AppDirs dirs, QObject *parent)
    : QObject(parent), api_(api), session_(session), dir_(dirs.data + "/wallpapers") {
    QDir().mkpath(dir_);
    QFile f(dir_ + "/versions.json");
    if (f.open(QIODevice::ReadOnly)) {
        const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
        for (auto it = o.begin(); it != o.end(); ++it) versions_[it.key()] = it.value().toInteger();
    }
}

QString Wallpapers::file(const QString &peerAccountId) const { return dir_ + "/" + peerAccountId + ".jpg"; }
bool Wallpapers::has(const QString &peerAccountId) const { return QFile::exists(file(peerAccountId)); }

void Wallpapers::saveVersions() {
    QJsonObject o;
    for (auto it = versions_.begin(); it != versions_.end(); ++it) o.insert(it.key(), it.value());
    writeFile(dir_ + "/versions.json", QJsonDocument(o).toJson(QJsonDocument::Compact));
}

Task<void> Wallpapers::sync() {
    const auto token = session_.token();
    if (!token) co_return;
    const auto server = co_await api_.getChatWallpapers(*token);
    if (!server) co_return;
    for (auto it = server->begin(); it != server->end(); ++it) {
        if (versions_.value(it.key(), -1) != it.value() || !has(it.key())) {
            co_await download(it.key(), *token);
            versions_[it.key()] = it.value();
        }
    }
    for (const QString &gone : versions_.keys()) {
        if (!server->contains(gone)) {
            QFile::remove(file(gone));
            versions_.remove(gone);
            Q_EMIT changed(gone);
        }
    }
    saveVersions();
}

Task<void> Wallpapers::download(QString accountId, QString token) {
    try {
        const auto jpeg = co_await api_.getChatWallpaper(token, accountId);
        if (jpeg) writeFile(file(accountId), *jpeg);
        else QFile::remove(file(accountId));
        Q_EMIT changed(accountId);
    } catch (const std::exception &) {
        // NAS/сеть — остаются прежние обои
    }
}

Task<void> Wallpapers::set(QString peerAccountId, QByteArray jpeg, bool forPeer) {
    const qint64 version = co_await api_.setChatWallpaper(session_.token().value_or(QString()), peerAccountId, jpeg, forPeer);
    writeFile(file(peerAccountId), jpeg);
    versions_[peerAccountId] = version;
    saveVersions();
    Q_EMIT changed(peerAccountId);
}

Task<void> Wallpapers::remove(QString peerAccountId) {
    co_await api_.deleteChatWallpaper(session_.token().value_or(QString()), peerAccountId);
    QFile::remove(file(peerAccountId));
    versions_.remove(peerAccountId);
    saveVersions();
    Q_EMIT changed(peerAccountId);
}

void Wallpapers::reset() {
    versions_.clear();
    QDir(dir_).removeRecursively();
    QDir().mkpath(dir_);
}

} // namespace osh
