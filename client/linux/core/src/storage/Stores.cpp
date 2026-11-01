#include "storage/Stores.h"

#include "support/Json.h"
#include "support/Log.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QSaveFile>
#include <QStandardPaths>

#include <libsecret/secret.h>

namespace osh {

// ---------------- SecureStore ----------------

std::optional<QString> InMemorySecureStore::read(const QString &key) const {
    const auto it = map_.find(key);
    return it == map_.end() ? std::nullopt : std::optional(*it);
}

namespace {

const SecretSchema *masterKeySchema() {
    static const SecretSchema schema = {
        "space.oshino.Oshinobu.MasterKey",
        SECRET_SCHEMA_NONE,
        {{"purpose", SECRET_SCHEMA_ATTRIBUTE_STRING}, {nullptr, SecretSchemaAttributeType(0)}},
        0, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr,
    };
    return &schema;
}

/// Мастер-ключ из связки ключей; нет Secret Service — nullopt.
std::optional<QByteArray> keyringLookup() {
    GError *error = nullptr;
    gchar *secret = secret_password_lookup_sync(masterKeySchema(), nullptr, &error, "purpose", "secure-store", nullptr);
    if (error) {
        log(QStringLiteral("SecureStore: связка ключей недоступна: %1").arg(QString::fromUtf8(error->message)));
        g_error_free(error);
        return std::nullopt;
    }
    if (!secret) return QByteArray();
    QByteArray key;
    try {
        key = unb64(QString::fromLatin1(secret));
    } catch (const std::exception &) {
    }
    secret_password_free(secret);
    return key;
}

bool keyringStore(const QByteArray &key) {
    GError *error = nullptr;
    const QByteArray value = b64(key).toLatin1();
    const gboolean ok = secret_password_store_sync(masterKeySchema(), SECRET_COLLECTION_DEFAULT, "Oshinobu — ключ хранилища", value.constData(),
                                                   nullptr, &error, "purpose", "secure-store", nullptr);
    if (error) {
        log(QStringLiteral("SecureStore: не сохранить ключ в связку: %1").arg(QString::fromUtf8(error->message)));
        g_error_free(error);
        return false;
    }
    return ok;
}

} // namespace

EncryptedFileSecureStore::EncryptedFileSecureStore(QString dataDir)
    : path_(dataDir + "/secure.bin"), keyFallbackPath_(dataDir + "/secure.key") {
    QDir().mkpath(dataDir);
    key_ = masterKey();
    QFile f(path_);
    if (!f.open(QIODevice::ReadOnly)) return;
    const QByteArray raw = f.readAll();
    if (raw.size() < AesGcm::NonceBytes + AesGcm::TagBytes) return;
    try {
        const SealedBox box{raw.left(AesGcm::NonceBytes), raw.mid(AesGcm::NonceBytes, raw.size() - AesGcm::NonceBytes - AesGcm::TagBytes),
                            raw.right(AesGcm::TagBytes)};
        const QJsonObject o = json::parseObject(AesGcm::decrypt(key_, box, QByteArrayLiteral("oshinobu-secure-store")));
        for (auto it = o.begin(); it != o.end(); ++it) map_[it.key()] = it.value().toString();
    } catch (const std::exception &e) {
        // ключ потерян (переустановка системы) — хранилище не прочитать: начинаем с чистого
        logError(QStringLiteral("SecureStore: не расшифровать хранилище: %1").arg(QString::fromUtf8(e.what())));
    }
}

QByteArray EncryptedFileSecureStore::masterKey() {
    if (const auto fromKeyring = keyringLookup()) {
        if (fromKeyring->size() == 32) return *fromKeyring;
        // в связке ещё нет — может, лежит в запасном файле (была без Secret Service)
        QFile old(keyFallbackPath_);
        QByteArray key = old.open(QIODevice::ReadOnly) ? old.readAll() : QByteArray();
        if (key.size() != 32) key = randomBytes(32);
        if (keyringStore(key)) {
            QFile::remove(keyFallbackPath_);
            return key;
        }
    }
    // нет Secret Service — ключ рядом, только для владельца
    QFile f(keyFallbackPath_);
    if (f.open(QIODevice::ReadOnly)) {
        const QByteArray key = f.readAll();
        if (key.size() == 32) return key;
        f.close();
    }
    log("SecureStore: связки ключей нет — ключ хранилища в файле с правами 600");
    const QByteArray key = randomBytes(32);
    QSaveFile out(keyFallbackPath_);
    if (out.open(QIODevice::WriteOnly)) {
        out.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        out.write(key);
        out.commit();
    }
    return key;
}

void EncryptedFileSecureStore::persist() {
    QJsonObject o;
    for (auto it = map_.begin(); it != map_.end(); ++it) o.insert(it.key(), it.value());
    const SealedBox box = AesGcm::encrypt(key_, QJsonDocument(o).toJson(QJsonDocument::Compact), QByteArrayLiteral("oshinobu-secure-store"));
    QSaveFile f(path_);
    if (!f.open(QIODevice::WriteOnly)) {
        logError("SecureStore: не открыть файл хранилища на запись");
        return;
    }
    f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    f.write(box.nonce + box.ciphertext + box.mac);
    if (!f.commit()) logError("SecureStore: не записать файл хранилища");
}

void EncryptedFileSecureStore::write(const QString &key, const QString &value) {
    if (read(key) == value) return;
    map_[key] = value;
    persist();
}

void EncryptedFileSecureStore::remove(const QString &key) {
    if (map_.remove(key)) persist();
}

void EncryptedFileSecureStore::removeAll() {
    map_.clear();
    persist();
}

// ---------------- Prefs / AppDirs ----------------

Prefs::Prefs(std::unique_ptr<QSettings> settings) : s_(std::move(settings)) {}

std::optional<QString> Prefs::getString(const QString &key) const {
    return s_->contains(key) ? std::optional(s_->value(key).toString()) : std::nullopt;
}
std::optional<qint64> Prefs::getLong(const QString &key) const {
    return s_->contains(key) ? std::optional(s_->value(key).toLongLong()) : std::nullopt;
}
std::optional<double> Prefs::getDouble(const QString &key) const {
    return s_->contains(key) ? std::optional(s_->value(key).toDouble()) : std::nullopt;
}
std::optional<bool> Prefs::getBool(const QString &key) const { return s_->contains(key) ? std::optional(s_->value(key).toBool()) : std::nullopt; }
std::optional<QStringList> Prefs::getStringList(const QString &key) const {
    return s_->contains(key) ? std::optional(s_->value(key).toStringList()) : std::nullopt;
}
void Prefs::setString(const QString &key, const QString &v) { s_->setValue(key, v); }
void Prefs::setLong(const QString &key, qint64 v) { s_->setValue(key, v); }
void Prefs::setDouble(const QString &key, double v) { s_->setValue(key, v); }
void Prefs::setBool(const QString &key, bool v) { s_->setValue(key, v); }
void Prefs::setStringList(const QString &key, const QStringList &v) { s_->setValue(key, v); }
void Prefs::remove(const QString &key) { s_->remove(key); }
void Prefs::clear() { s_->clear(); }

AppDirs AppDirs::standard() {
    AppDirs d;
    d.data = QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation);
    d.cache = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
    d.temp = d.cache + "/tmp";
    for (const QString &p : {d.data, d.cache, d.temp}) QDir().mkpath(p);
    return d;
}

AppDirs AppDirs::under(const QString &root) {
    AppDirs d{root + "/data", root + "/cache", root + "/cache/tmp"};
    for (const QString &p : {d.data, d.cache, d.temp}) QDir().mkpath(p);
    return d;
}

// ---------------- KeyStore ----------------

std::optional<StoredIdentity> KeyStore::loadIdentity() const { return StoredIdentity::fromStore(s_.readAll()); }

DeviceIdentity KeyStore::getOrCreateIdentity() {
    const auto idPriv = s_.read(StoredIdentity::IdentityPrivate), idPub = s_.read(StoredIdentity::IdentityPublic);
    std::optional<Ed25519KeyPair> identity;
    if (idPriv && idPub) {
        identity.emplace(unb64(*idPriv), unb64(*idPub));
    } else {
        identity.emplace(Ed25519KeyPair::generate());
        s_.write(StoredIdentity::IdentityPrivate, b64(identity->seed));
        s_.write(StoredIdentity::IdentityPublic, b64(identity->publicKey));
    }
    const auto dhPriv = s_.read(StoredIdentity::IdentityDhPrivate), dhPub = s_.read(StoredIdentity::IdentityDhPublic),
               dhSig = s_.read(StoredIdentity::IdentityDhSignature);
    if (dhPriv && dhPub && dhSig) return DeviceIdentity{*identity, X25519KeyPair(unb64(*dhPriv), unb64(*dhPub)), unb64(*dhSig)};
    const X25519KeyPair dh = X25519KeyPair::generate();
    const QByteArray sig = identity->sign(dh.publicKey);
    s_.write(StoredIdentity::IdentityDhPrivate, b64(dh.privateKey));
    s_.write(StoredIdentity::IdentityDhPublic, b64(dh.publicKey));
    s_.write(StoredIdentity::IdentityDhSignature, b64(sig));
    return DeviceIdentity{*identity, dh, sig};
}

std::pair<QByteArray, QByteArray> KeyStore::createSignedPrekey(const Ed25519KeyPair &identity) {
    const X25519KeyPair kp = X25519KeyPair::generate();
    s_.write(StoredIdentity::SignedPrekeyPrivate, b64(kp.privateKey));
    s_.write(StoredIdentity::SignedPrekeyPublic, b64(kp.publicKey));
    return {kp.publicKey, identity.sign(kp.publicKey)};
}

namespace {
QJsonArray parseArray(const std::optional<QString> &raw) { return raw ? QJsonDocument::fromJson(raw->toUtf8()).array() : QJsonArray(); }
} // namespace

QList<QByteArray> KeyStore::createOneTimePrekeys(int count) {
    QJsonArray list = parseArray(s_.read(StoredIdentity::OneTimePrekeys));
    QList<QByteArray> fresh;
    for (int i = 0; i < count; ++i) {
        const X25519KeyPair kp = X25519KeyPair::generate();
        list.append(QJsonObject{{"public", b64(kp.publicKey)}, {"private", b64(kp.privateKey)}});
        fresh << kp.publicKey;
    }
    s_.write(StoredIdentity::OneTimePrekeys, json::compact(list));
    return fresh;
}

void KeyStore::deleteOneTimePrekey(const QString &publicKeyB64) {
    const QJsonArray list = parseArray(s_.read(StoredIdentity::OneTimePrekeys));
    QJsonArray kept;
    for (const QJsonValue &v : list) {
        if (v.toObject().value("public").toString() != publicKeyB64) kept.append(v);
    }
    if (kept.size() != list.size()) s_.write(StoredIdentity::OneTimePrekeys, json::compact(kept));
}

// ---------------- SessionStore ----------------

namespace {
constexpr int MaxArchived = 3;
QString ratchetKey(const QString &d) { return "ratchet:" + d; }
QString archiveKey(const QString &d) { return "ratchet_archive:" + d; }
QString initKey(const QString &d) { return "x3dh_init:" + d; }
} // namespace

std::optional<RatchetState> SessionStore::get(const QString &deviceId) const {
    const auto raw = s_.read(ratchetKey(deviceId));
    if (!raw) return std::nullopt;
    return RatchetState::fromJson(json::parseObject(*raw));
}

void SessionStore::save(const QString &deviceId, const RatchetState &state) { s_.write(ratchetKey(deviceId), json::compact(state.toJson())); }

void SessionStore::clear(const QString &deviceId) {
    s_.remove(ratchetKey(deviceId));
    clearPendingInit(deviceId);
}

QList<RatchetState> SessionStore::archived(const QString &deviceId) const {
    QList<RatchetState> out;
    for (const QJsonValue &v : parseArray(s_.read(archiveKey(deviceId)))) out << RatchetState::fromJson(v.toObject());
    return out;
}

void SessionStore::saveArchive(const QString &deviceId, const QList<RatchetState> &states) {
    if (states.isEmpty()) {
        s_.remove(archiveKey(deviceId));
        return;
    }
    QJsonArray arr;
    for (int i = 0; i < states.size() && i < MaxArchived; ++i) arr.append(states[i].toJson());
    s_.write(archiveKey(deviceId), json::compact(arr));
}

void SessionStore::retire(const QString &deviceId) {
    if (const auto current = get(deviceId)) {
        QList<RatchetState> all{*current};
        all += archived(deviceId);
        saveArchive(deviceId, all);
    }
    clear(deviceId);
}

void SessionStore::replace(const QString &deviceId, const RatchetState &state) {
    retire(deviceId);
    save(deviceId, state);
}

void SessionStore::promote(const QString &deviceId, int index, const RatchetState &state) {
    const QList<RatchetState> old = archived(deviceId);
    QList<RatchetState> rest;
    if (const auto current = get(deviceId)) rest << *current;
    for (int i = 0; i < old.size(); ++i) {
        if (i != index) rest << old[i];
    }
    saveArchive(deviceId, rest);
    clearPendingInit(deviceId);
    save(deviceId, state);
}

std::optional<QJsonObject> SessionStore::pendingInit(const QString &deviceId) const {
    const auto raw = s_.read(initKey(deviceId));
    if (!raw) return std::nullopt;
    return json::parseObject(*raw);
}

void SessionStore::savePendingInit(const QString &deviceId, const QJsonObject &header) { s_.write(initKey(deviceId), json::compact(header)); }
void SessionStore::clearPendingInit(const QString &deviceId) { s_.remove(initKey(deviceId)); }

// ---------------- очереди ----------------

QList<QJsonObject> JsonQueueStore::getAll() const {
    QList<QJsonObject> out;
    for (const QJsonValue &v : parseArray(s_.read(key_))) out << v.toObject();
    return out;
}

void JsonQueueStore::writeAll(const QList<QJsonObject> &items) {
    QJsonArray arr;
    for (const auto &o : items) arr.append(o);
    s_.write(key_, json::compact(arr));
}

void JsonQueueStore::put(const QJsonObject &job) {
    const QString id = job.value("id").toString();
    QList<QJsonObject> items;
    for (const auto &o : getAll()) {
        if (o.value("id").toString() != id) items << o;
    }
    items << job;
    writeAll(items);
}

void JsonQueueStore::remove(const QString &id) {
    QList<QJsonObject> items;
    for (const auto &o : getAll()) {
        if (o.value("id").toString() != id) items << o;
    }
    writeAll(items);
}

void SendQueueStore::add(const QString &id, const QString &toDeviceId, const QJsonObject &envelope, bool silent,
                         const std::optional<QString> &messageId, const std::optional<QString> &peerLogin) {
    QJsonObject job{{"id", id}, {"to_device_id", toDeviceId}, {"envelope", envelope}, {"silent", silent}};
    if (messageId) job.insert("message_id", *messageId);
    if (peerLogin) job.insert("peer_login", *peerLogin);
    put(job);
}

std::optional<ChunkedUploadSessionStore::Entry> ChunkedUploadSessionStore::get(const QString &messageId) const {
    const auto raw = s_.read("chunked_upload_session_" + messageId);
    if (!raw) return std::nullopt;
    const QJsonObject j = json::parseObject(*raw);
    return Entry{json::string(j, "media_id"), json::string(j, "upload_id"), int(j.value("part_size").toInteger()), json::string(j, "key_base64")};
}

void ChunkedUploadSessionStore::save(const QString &messageId, const Entry &e) {
    s_.write("chunked_upload_session_" + messageId,
             json::compact(QJsonObject{{"media_id", e.mediaId}, {"upload_id", e.uploadId}, {"part_size", e.partSize}, {"key_base64", e.keyBase64}}));
}

// ---------------- MediaFiles ----------------

QString MediaFiles::cacheFile(const QString &mediaId) const { return dirs_.cache + "/media_cache_" + mediaId; }

QString MediaFiles::partialFile(const QString &mediaId) const {
    const QString dir = dirs_.data + "/partial_downloads";
    QDir().mkpath(dir);
    return dir + "/" + mediaId + ".part";
}

int MediaFiles::clearCache() const {
    int n = 0;
    for (const QFileInfo &f : QDir(dirs_.cache).entryInfoList({"media_cache_*"}, QDir::Files)) n += QFile::remove(f.filePath()) ? 1 : 0;
    return n;
}

qint64 MediaFiles::cacheSize() const {
    qint64 total = 0;
    for (const QFileInfo &f : QDir(dirs_.cache).entryInfoList({"media_cache_*"}, QDir::Files)) total += f.size();
    return total;
}

void MediaFiles::pruneStalePartials(qint64 maxAgeMs) const {
    const QDateTime cutoff = QDateTime::currentDateTime().addMSecs(-maxAgeMs);
    for (const QFileInfo &f : QDir(dirs_.data + "/partial_downloads").entryInfoList(QDir::Files)) {
        if (f.lastModified() < cutoff) QFile::remove(f.filePath());
    }
}

// ---------------- AppLockStore ----------------

namespace {
QString pinHash(const QString &pin, const QString &saltHex) {
    return QString::fromLatin1(QCryptographicHash::hash(pin.toUtf8() + QByteArray::fromHex(saltHex.toLatin1()), QCryptographicHash::Sha256).toHex());
}
} // namespace

AppLockSettings AppLockStore::load() const {
    return AppLockSettings{s_.read("app_lock_enabled") == QStringLiteral("true"), s_.read("app_lock_timeout_seconds").value_or("60").toInt(),
                           s_.read("app_lock_pin_hash").has_value(), s_.read("app_lock_pin_length").value_or("4").toInt()};
}

void AppLockStore::setPin(const QString &pin) {
    const QString salt = QString::fromLatin1(randomBytes(16).toHex());
    s_.write("app_lock_pin_salt", salt);
    s_.write("app_lock_pin_hash", pinHash(pin, salt));
    s_.write("app_lock_pin_length", QString::number(pin.size()));
}

bool AppLockStore::verifyPin(const QString &pin) const {
    const auto salt = s_.read("app_lock_pin_salt"), stored = s_.read("app_lock_pin_hash");
    if (!salt || !stored) return false;
    return constantTimeEquals(pinHash(pin, *salt).toLatin1(), stored->toLatin1());
}

void AppLockStore::removePin() {
    s_.remove("app_lock_pin_hash");
    s_.remove("app_lock_pin_salt");
    s_.remove("app_lock_pin_length");
    s_.write("app_lock_enabled", "false");
}

void AppLockStore::setEnabled(bool v) {
    if (v && !s_.read("app_lock_pin_hash")) return;
    s_.write("app_lock_enabled", v ? "true" : "false");
}

void AppLockStore::setTimeoutSeconds(int seconds) { s_.write("app_lock_timeout_seconds", QString::number(seconds)); }

} // namespace osh
