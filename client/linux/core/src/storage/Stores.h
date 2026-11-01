#pragma once

// Хранилища (как Stores.kt + AccountStores.kt на Android). Имена записей — те же.
//
// SecureStore — ключи устройства, сессии ratchet, очереди. На Linux: один файл
// <data>/secure.bin, зашифрованный AES-256-GCM мастер-ключом из связки ключей
// GNOME (libsecret); нет Secret Service — мастер-ключ в файле с правами 600.
// Всё держится в памяти, запись — сразу на диск (атомарно).

#include "crypto/RatchetState.h"
#include "crypto/StoredIdentity.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QMap>
#include <QSettings>
#include <QString>
#include <QStringList>
#include <memory>
#include <optional>

namespace osh {

class SecureStore {
public:
    virtual ~SecureStore() = default;
    virtual std::optional<QString> read(const QString &key) const = 0;
    virtual void write(const QString &key, const QString &value) = 0;
    virtual void remove(const QString &key) = 0;
    virtual QMap<QString, QString> readAll() const = 0;
    virtual void removeAll() = 0;
};

class InMemorySecureStore : public SecureStore {
public:
    std::optional<QString> read(const QString &key) const override;
    void write(const QString &key, const QString &value) override { map_[key] = value; }
    void remove(const QString &key) override { map_.remove(key); }
    QMap<QString, QString> readAll() const override { return map_; }
    void removeAll() override { map_.clear(); }

protected:
    QMap<QString, QString> map_;
};

/// Зашифрованный файл + мастер-ключ в связке ключей.
class EncryptedFileSecureStore : public InMemorySecureStore {
public:
    explicit EncryptedFileSecureStore(QString dataDir);
    void write(const QString &key, const QString &value) override;
    void remove(const QString &key) override;
    void removeAll() override;

private:
    void persist();
    QByteArray masterKey();
    QString path_, keyFallbackPath_;
    QByteArray key_;
};

/// Обычные настройки (не секреты) — QSettings.
class Prefs {
public:
    explicit Prefs(std::unique_ptr<QSettings> settings);
    std::optional<QString> getString(const QString &key) const;
    std::optional<qint64> getLong(const QString &key) const;
    std::optional<double> getDouble(const QString &key) const;
    std::optional<bool> getBool(const QString &key) const;
    std::optional<QStringList> getStringList(const QString &key) const;
    void setString(const QString &key, const QString &v);
    void setLong(const QString &key, qint64 v);
    void setDouble(const QString &key, double v);
    void setBool(const QString &key, bool v);
    void setStringList(const QString &key, const QStringList &v);
    void remove(const QString &key);
    void clear();

private:
    std::unique_ptr<QSettings> s_;
};

/// Каталоги: data — постоянное (<~/.local/share/Oshinobu>), cache — кэш вложений, temp — временное.
struct AppDirs {
    QString data;
    QString cache;
    QString temp;
    static AppDirs standard();
    static AppDirs under(const QString &root);
};

class Session {
public:
    explicit Session(Prefs &prefs) : prefs_(prefs) {}
    std::optional<QString> token() const { return prefs_.getString("auth_token"); }
    std::optional<QString> login() const { return prefs_.getString("saved_login"); }
    std::optional<QString> accountId() const { return prefs_.getString("saved_account_id"); }
    void setToken(const std::optional<QString> &v) { set("auth_token", v); }
    void setLogin(const std::optional<QString> &v) { set("saved_login", v); }
    void setAccountId(const std::optional<QString> &v) { set("saved_account_id", v); }

private:
    void set(const char *k, const std::optional<QString> &v) { v ? prefs_.setString(k, *v) : prefs_.remove(k); }
    Prefs &prefs_;
};

struct DeviceIdentity {
    Ed25519KeyPair identity;
    X25519KeyPair identityDh;
    QByteArray identityDhSignature;
};

/// Ключи устройства.
class KeyStore {
public:
    explicit KeyStore(SecureStore &s) : s_(s) {}
    std::optional<QString> deviceId() const { return s_.read(StoredIdentity::DeviceId); }
    void saveDeviceId(const QString &id) { s_.write(StoredIdentity::DeviceId, id); }
    std::optional<StoredIdentity> loadIdentity() const;
    DeviceIdentity getOrCreateIdentity();
    /// Новый signed prekey: (публичный ключ, подпись identity-ключом).
    std::pair<QByteArray, QByteArray> createSignedPrekey(const Ed25519KeyPair &identity);
    QList<QByteArray> createOneTimePrekeys(int count);
    void deleteOneTimePrekey(const QString &publicKeyB64);
    void clearAll() { s_.removeAll(); }

private:
    SecureStore &s_;
};

/**
 * Сессии ratchet по устройству собеседника + архив до 3 прежних (только приём):
 * сообщение, зашифрованное старой сессией (собеседник ещё не получил сброс),
 * расшифровывается архивной, и она снова становится текущей.
 */
class SessionStore {
public:
    explicit SessionStore(SecureStore &s) : s_(s) {}
    std::optional<RatchetState> get(const QString &deviceId) const;
    void save(const QString &deviceId, const RatchetState &state);
    void clear(const QString &deviceId);
    QList<RatchetState> archived(const QString &deviceId) const;
    /// Текущую — в архив (новая появится по X3DH).
    void retire(const QString &deviceId);
    void replace(const QString &deviceId, const RatchetState &state);
    /// Архивная [index] расшифровала сообщение — снова текущая, прежняя текущая — в архив.
    void promote(const QString &deviceId, int index, const RatchetState &state);
    std::optional<QJsonObject> pendingInit(const QString &deviceId) const;
    void savePendingInit(const QString &deviceId, const QJsonObject &header);
    void clearPendingInit(const QString &deviceId);

private:
    void saveArchive(const QString &deviceId, const QList<RatchetState> &states);
    SecureStore &s_;
};

class PeerAccountStore {
public:
    explicit PeerAccountStore(SecureStore &s) : s_(s) {}
    std::optional<QString> get(const QString &deviceId) const { return s_.read("peer_account:" + deviceId); }
    void save(const QString &deviceId, const QString &accountId) { s_.write("peer_account:" + deviceId, accountId); }

private:
    SecureStore &s_;
};

class PeerIdentityStore {
public:
    explicit PeerIdentityStore(SecureStore &s) : s_(s) {}
    std::optional<QString> get(const QString &deviceId) const { return s_.read("peer_identity:" + deviceId); }
    void save(const QString &deviceId, const QString &identityDhB64) { s_.write("peer_identity:" + deviceId, identityDhB64); }

private:
    SecureStore &s_;
};

/// Список JSON-заданий с полем "id" под одним ключом.
class JsonQueueStore {
public:
    JsonQueueStore(SecureStore &s, QString key) : s_(s), key_(std::move(key)) {}
    QList<QJsonObject> getAll() const;
    void put(const QJsonObject &job);
    void remove(const QString &id);

private:
    void writeAll(const QList<QJsonObject> &items);
    SecureStore &s_;
    QString key_;
};

class SendQueueStore : public JsonQueueStore {
public:
    explicit SendQueueStore(SecureStore &s) : JsonQueueStore(s, "send_queue") {}
    void add(const QString &id, const QString &toDeviceId, const QJsonObject &envelope, bool silent = false,
             const std::optional<QString> &messageId = std::nullopt, const std::optional<QString> &peerLogin = std::nullopt);
};

class ChunkedUploadSessionStore {
public:
    struct Entry {
        QString mediaId, uploadId;
        int partSize = 0;
        QString keyBase64;
    };
    explicit ChunkedUploadSessionStore(SecureStore &s) : s_(s) {}
    std::optional<Entry> get(const QString &messageId) const;
    void save(const QString &messageId, const Entry &e);
    void clear(const QString &messageId) { s_.remove("chunked_upload_session_" + messageId); }

private:
    SecureStore &s_;
};

/// Файлы вложений: расшифрованный кэш и недокачанные хвосты.
class MediaFiles {
public:
    explicit MediaFiles(AppDirs dirs) : dirs_(std::move(dirs)) {}
    QString cacheFile(const QString &mediaId) const;
    QString partialFile(const QString &mediaId) const;
    int clearCache() const;
    qint64 cacheSize() const;
    void pruneStalePartials(qint64 maxAgeMs = 7LL * 24 * 3600 * 1000) const;

private:
    AppDirs dirs_;
};

struct AppLockSettings {
    bool enabled = false;
    int timeoutSeconds = 60;
    bool hasPin = false;
    int pinLength = 4;
};

/// Блокировка приложения PIN-кодом (хеш с солью, как на Android).
class AppLockStore {
public:
    explicit AppLockStore(SecureStore &s) : s_(s) {}
    AppLockSettings load() const;
    void setPin(const QString &pin);
    bool verifyPin(const QString &pin) const;
    void removePin();
    void setEnabled(bool v);
    void setTimeoutSeconds(int seconds);

private:
    SecureStore &s_;
};

} // namespace osh
