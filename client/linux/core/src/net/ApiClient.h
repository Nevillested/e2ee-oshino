#pragma once

// REST-клиент сервера (как ApiClient.kt): те же пути, поля и коды ошибок. Ошибка —
// ApiError с ключом строки ("error.x"; в интерфейсе — строка "error_x").

#include "support/Task.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QSet>
#include <QStringList>
#include <functional>
#include <optional>
#include <stdexcept>

namespace osh {

struct ApiError : std::runtime_error {
    QString key;
    std::optional<int> status;
    explicit ApiError(QString key, std::optional<int> status = std::nullopt);
};

struct LoginResult {
    QString token;
    QString language;
};

struct ChunkedUploadInit {
    QString mediaId;
    QString uploadId;
    int partSize = 0;
};

struct BlockedContacts {
    QStringList blockedByMe;
    QStringList blockingMe;
};

struct DeviceOwner {
    QString accountId;
    QString login;
    QString displayName;
};

struct AccountDevices {
    QString accountId;
    QList<QJsonObject> devices;
};

struct MyAccountInfo {
    QString accountId;
    QString login;
    std::optional<QString> displayName;
    QString language;
    std::optional<QString> email;
    bool hasAvatar = false;
    std::optional<QString> status;
    std::optional<QString> birthday;
    int findByLoginVisibility = 1;
    int avatarVisibility = 1;
    int birthdayVisibility = 1;
    int statusVisibility = 1;
};

struct AccountProfile {
    QString accountId;
    QString login;
    QString displayName;
    QList<QJsonObject> devices;
    std::optional<QString> status;
    std::optional<QString> birthday;
    bool hasAvatar = false;
};

struct StickerInfo {
    QString id;
    QString format;
    QString packId;
    bool animated() const { return format == QLatin1String("tgs"); }
};

struct StickerPackInfo {
    QString id;
    QString title;
    bool isOwner = false;
    bool installed = false;
    bool deleted = false;
    QList<StickerInfo> stickers;
};

struct StickerUploadEvent {
    QString stage;
    std::optional<qint64> bytes;
    std::optional<int> count, index, total;
    std::optional<QString> name, code;
    std::optional<int> limit;
};

struct StickerUploadError : std::runtime_error {
    QString code;
    std::optional<QString> fileName;
    std::optional<int> limit;
    StickerUploadError(QString code, std::optional<QString> fileName = std::nullopt, std::optional<int> limit = std::nullopt);
};

struct PrivacySettings {
    int findByLogin = 1;
    int avatar = 1;
    int birthday = 1;
    int status = 1;
};

struct AppVersionInfo {
    int versionCode = 0;
    QString apkUrl;
};

using ProgressFn = std::function<void(double percent)>;

class ApiClient {
public:
    explicit ApiClient(QString baseUrl = QStringLiteral("https://ee2e.oshino.space"));

    const QString &baseUrl() const { return baseUrl_; }
    QString wsBaseUrl() const;
    QNetworkAccessManager &network() { return net_; }

    // вход и регистрация
    Task<QString> registerAccount(QString login, QString password, QString inviteCode);
    Task<void> verifyTotp(QString login, QString code);
    Task<LoginResult> login(QString login, QString password, QString totpCode);
    Task<void> requestPasswordRecovery(QString login);
    Task<void> verifyRecoveryCode(QString login, QString token);
    Task<void> resetPasswordWithRecoveryCode(QString login, QString token, QString newPassword);
    Task<QString> resetTotpWithRecoveryCode(QString login, QString token);
    /// true — сессия жива, false — сервер её не признаёт, nullopt — нет связи.
    Task<std::optional<bool>> checkSession(QString token);

    // устройство и ключи
    Task<QString> registerDevice(QString token, QString identityPub, QString identityDhPub, QString identityDhSignature);
    Task<void> uploadPrekeys(QString token, QString deviceId, QString signedPrekey, QString signedPrekeySignature, QStringList oneTimePrekeys);
    Task<QJsonObject> getPrekeyBundle(QString token, QString deviceId);
    Task<std::optional<int>> getPrekeyCount(QString token, QString deviceId);
    Task<AccountDevices> getDevicesByLogin(QString token, QString login);
    Task<std::optional<DeviceOwner>> getDeviceOwnerInfo(QString token, QString deviceId);
    Task<bool> declineCall(QString token, QString deviceId, QString callId, bool busy = false);
    Task<std::optional<QJsonObject>> getTurnCredentials(QString token);
    Task<bool> unregisterPushToken(QString token, QString deviceId);
    Task<std::optional<AppVersionInfo>> getAppVersion();

    // аккаунт и профиль
    Task<bool> deleteAccount(QString token);
    Task<std::optional<MyAccountInfo>> getMyAccountInfo(QString token);
    Task<std::optional<AccountProfile>> getAccountProfile(QString token, QString login);
    Task<void> updateLanguage(QString token, QString language);
    Task<void> changePassword(QString token, QString newPassword);
    Task<void> updateEmail(QString token, QString email);
    Task<void> updateDisplayName(QString token, QString displayName);
    Task<void> updateStatus(QString token, QString status);
    Task<void> updateBirthday(QString token, std::optional<QString> birthday);
    Task<void> updatePrivacy(QString token, PrivacySettings p);
    Task<void> requestEmailVerification(QString token, QString email);
    Task<void> confirmEmailVerification(QString token, QString code);
    Task<void> uploadAvatar(QString token, QByteArray jpeg);
    Task<void> deleteAvatar(QString token);
    Task<std::optional<QByteArray>> getAvatar(QString token, QString accountId);
    Task<std::optional<QByteArray>> getMyAvatar(QString token);

    // чаты и контакты
    Task<void> muteChat(QString token, QString peerAccountId);
    Task<void> unmuteChat(QString token, QString peerAccountId);
    Task<QStringList> getMutedChats(QString token);
    Task<std::optional<QMap<QString, qint64>>> getChatWallpapers(QString token);
    Task<std::optional<QByteArray>> getChatWallpaper(QString token, QString peerAccountId);
    Task<qint64> setChatWallpaper(QString token, QString peerAccountId, QByteArray jpeg, bool forPeer);
    Task<void> deleteChatWallpaper(QString token, QString peerAccountId);
    Task<void> blockContact(QString token, QString peerAccountId);
    Task<void> unblockContact(QString token, QString peerAccountId);
    Task<std::optional<BlockedContacts>> getBlockedContacts(QString token);
    Task<void> reportMessage(QString token, QString reportedDeviceId, QString messageText, QString reason);
    Task<void> reportCrashLog(QString token, QString logText, QString kind = QStringLiteral("auto_crash"));

    // вложения
    Task<QString> uploadEncryptedMediaFile(QString token, QString file, QString recipientAccountId, ProgressFn onProgress = {});
    Task<ChunkedUploadInit> initChunkedUpload(QString token, qint64 sizeBytes);
    Task<void> uploadChunkedPart(QString token, QString mediaId, QString uploadId, int partNumber, QByteArray data, ProgressFn onProgress = {});
    Task<QSet<int>> listChunkedParts(QString token, QString mediaId, QString uploadId);
    Task<void> completeChunkedUpload(QString token, QString mediaId, QString uploadId, QString recipientAccountId);
    Task<void> abortChunkedUpload(QString token, QString mediaId, QString uploadId);
    Task<qint64> probeEncryptedMediaSize(QString token, QString mediaId);
    /// Докачка в [dest] (Range); возвращает полный размер.
    Task<qint64> downloadEncryptedMediaResumable(QString token, QString mediaId, QString dest, std::optional<qint64> knownTotal = std::nullopt,
                                                 ProgressFn onProgress = {});
    Task<void> confirmMediaReceived(QString token, QString mediaId);

    // стикеры
    Task<QList<StickerPackInfo>> getMyStickerPacks(QString token);
    Task<std::optional<StickerPackInfo>> getStickerPack(QString token, QString packId);
    Task<std::optional<StickerPackInfo>> getStickerPackBySticker(QString token, QString stickerId);
    /// false — пак удалён (410).
    Task<bool> downloadStickerPack(QString token, QString packId, QString dest);
    Task<void> installStickerPack(QString token, QString packId);
    Task<void> uninstallStickerPack(QString token, QString packId);
    Task<void> deleteStickerPack(QString token, QString packId);
    Task<StickerPackInfo> uploadStickerPack(QString token, QString title, QString archive, ProgressFn onProgress,
                                            std::function<void(const StickerUploadEvent &)> onEvent);

    static StickerPackInfo parseStickerPack(const QJsonObject &o);

private:
    struct Response {
        int code = 0;
        QByteArray body;
        QNetworkReply::NetworkError error = QNetworkReply::NoError;
        QMap<QByteArray, QByteArray> headers;
    };

    QNetworkRequest request(const QString &path, const QString &token = {}, int timeoutMs = 30000) const;
    /// Сетевая ошибка (нет связи, таймаут) — ApiError(errorKey); HTTP-коды — в Response.
    Task<Response> send(QNetworkRequest req, QByteArray method, QByteArray body, QString errorKey = QStringLiteral("error.network"));
    Task<Response> sendJson(const QString &method, const QString &path, const QString &token, const QJsonObject &body,
                            int timeoutMs = 30000);
    Task<void> putJson(QString token, QString path, QJsonObject body, QString errorKey);
    Task<void> postPeer(QString token, QString path, QString peerAccountId, QString errorKey);
    Task<std::optional<QByteArray>> avatarBytes(QString token, QString path);

    QString baseUrl_;
    QNetworkAccessManager net_;
};

} // namespace osh
