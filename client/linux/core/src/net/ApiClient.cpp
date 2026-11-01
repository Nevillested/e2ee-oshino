#include "net/ApiClient.h"

#include "support/Json.h"
#include "support/Log.h"

#include <QFile>
#include <QHttpMultiPart>
#include <QJsonDocument>
#include <QUrlQuery>

namespace osh {

namespace {

constexpr int ShortTimeoutMs = 8000;
constexpr int MediaTimeoutMs = 5 * 60 * 1000;

QJsonObject obj(const QByteArray &body) { return json::parseObject(body); }

QString str(const QJsonObject &o, const char *name) { return json::optString(o, name).value_or(QString()); }

int intOr(const QJsonObject &o, const char *name, int def) {
    const QJsonValue v = o.value(QLatin1String(name));
    return v.isDouble() ? int(v.toInteger()) : def;
}

QList<QJsonObject> objects(const QJsonObject &o, const char *name) {
    QList<QJsonObject> out;
    for (const QJsonValue &v : o.value(QLatin1String(name)).toArray()) out << v.toObject();
    return out;
}

QStringList strings(const QJsonObject &o, const char *name) {
    QStringList out;
    for (const QJsonValue &v : o.value(QLatin1String(name)).toArray()) out << v.toString();
    return out;
}

[[noreturn]] void fail(const QString &key, std::optional<int> code = std::nullopt) { throw ApiError(key, code); }

QHttpPart formField(const QString &name, const QByteArray &value) {
    QHttpPart p;
    p.setHeader(QNetworkRequest::ContentDispositionHeader, QStringLiteral("form-data; name=\"%1\"").arg(name));
    p.setBody(value);
    return p;
}

QHttpPart fileField(const QString &name, const QString &fileName, const QString &contentType) {
    QHttpPart p;
    p.setHeader(QNetworkRequest::ContentDispositionHeader, QStringLiteral("form-data; name=\"%1\"; filename=\"%2\"").arg(name, fileName));
    p.setHeader(QNetworkRequest::ContentTypeHeader, contentType);
    return p;
}

} // namespace

ApiError::ApiError(QString k, std::optional<int> s) : std::runtime_error(k.toStdString()), key(std::move(k)), status(s) {}

StickerUploadError::StickerUploadError(QString c, std::optional<QString> f, std::optional<int> l)
    : std::runtime_error(c.toStdString()), code(std::move(c)), fileName(std::move(f)), limit(l) {}

ApiClient::ApiClient(QString baseUrl) : baseUrl_(std::move(baseUrl)) {
    net_.setAutoDeleteReplies(true);
}

QString ApiClient::wsBaseUrl() const {
    if (baseUrl_.startsWith(QLatin1String("https://"))) return QStringLiteral("wss://") + baseUrl_.mid(8);
    return QStringLiteral("ws://") + baseUrl_.mid(7);
}

QNetworkRequest ApiClient::request(const QString &path, const QString &token, int timeoutMs) const {
    QNetworkRequest req(QUrl(baseUrl_ + path));
    if (!token.isEmpty()) req.setRawHeader("Authorization", "Bearer " + token.toUtf8());
    req.setTransferTimeout(timeoutMs);
    return req;
}

Task<ApiClient::Response> ApiClient::send(QNetworkRequest req, QByteArray method, QByteArray body, QString errorKey) {
    QNetworkReply *reply = net_.sendCustomRequest(req, method, body);
    co_await awaitReply{reply};
    Response r;
    r.code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    r.error = reply->error();
    r.body = reply->readAll();
    for (const auto &pair : reply->rawHeaderPairs()) r.headers.insert(pair.first.toLower(), pair.second);
    // HTTP-ответ с кодом ошибки — не сетевая ошибка: решает вызывающий по коду
    if (r.code == 0) {
        log(QStringLiteral("HTTP %1 %2 — нет ответа: %3").arg(QString::fromLatin1(method), req.url().path(), reply->errorString()));
        throw ApiError(errorKey);
    }
    co_return r;
}

Task<ApiClient::Response> ApiClient::sendJson(const QString &method, const QString &path, const QString &token, const QJsonObject &body,
                                              int timeoutMs) {
    QNetworkRequest req = request(path, token, timeoutMs);
    QByteArray payload;
    if (method != QLatin1String("GET") && method != QLatin1String("HEAD") && (!body.isEmpty() || method != QLatin1String("DELETE"))) {
        req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
        payload = QJsonDocument(body).toJson(QJsonDocument::Compact);
    }
    co_return co_await send(req, method.toLatin1(), payload);
}

// ---------------- вход и регистрация ----------------

Task<QString> ApiClient::registerAccount(QString login, QString password, QString inviteCode) {
    const QJsonObject body{{"login", login}, {"password", password}, {"invite_code", inviteCode}};
    const Response r = co_await sendJson("POST", "/register", {}, body);
    switch (r.code) {
    case 200: co_return json::string(obj(r.body), "totp_url");
    case 409: fail("error.loginTaken");
    case 403: fail("error.loginReserved");
    case 422: fail("error.inviteCodeInvalid");
    default: fail("error.registerFailed", r.code);
    }
}

Task<void> ApiClient::verifyTotp(QString login, QString code) {
    const QJsonObject body1{{"login", login}, {"code", code}};
    const Response r = co_await sendJson("POST", "/verify-totp", {}, body1);
    if (r.code != 200) fail("error.wrongTotpCode");
}

Task<LoginResult> ApiClient::login(QString login, QString password, QString totpCode) {
    const QJsonObject body2{{"login", login}, {"password", password}, {"totp_code", totpCode}};
    const Response r = co_await sendJson("POST", "/login", {}, body2);
    if (r.code == 429) fail("error.tooManyLoginAttempts");
    if (r.code != 200) fail("error.wrongCredentials");
    const QJsonObject o = obj(r.body);
    co_return LoginResult{json::string(o, "token"), json::optString(o, "language").value_or(QStringLiteral("en"))};
}

Task<void> ApiClient::requestPasswordRecovery(QString login) {
    const QJsonObject body3{{"login", login}};
    const Response r = co_await sendJson("POST", "/account/recover/request", {}, body3);
    if (r.code == 404) fail("error.recoveryUserNotFound");
    if (r.code == 422) fail("error.recoveryNoEmailOnFile");
    if (r.code != 200) fail("error.recoveryRequestFailed");
}

Task<void> ApiClient::verifyRecoveryCode(QString login, QString token) {
    const QJsonObject body4{{"login", login}, {"token", token}};
    const Response r = co_await sendJson("POST", "/account/recover/verify", {}, body4);
    if (r.code != 200) fail("error.recoveryWrongCode");
}

Task<void> ApiClient::resetPasswordWithRecoveryCode(QString login, QString token, QString newPassword) {
    const QJsonObject body5{{"login", login}, {"token", token}, {"new_password", newPassword}};
    const Response r = co_await sendJson("POST", "/account/recover/reset", {}, body5);
    if (r.code != 200) fail("error.recoveryWrongCode");
}

Task<QString> ApiClient::resetTotpWithRecoveryCode(QString login, QString token) {
    const QJsonObject body6{{"login", login}, {"token", token}};
    const Response r = co_await sendJson("POST", "/account/recover/reset-totp", {}, body6);
    if (r.code != 200) fail("error.recoveryWrongCode");
    co_return json::string(obj(r.body), "totp_url");
}

Task<std::optional<bool>> ApiClient::checkSession(QString token) {
    try {
        const Response r = co_await sendJson("GET", "/session/check", token, {}, ShortTimeoutMs);
        if (r.code == 200) co_return true;
        if (r.code == 401) co_return false;
    } catch (const ApiError &) {
    }
    co_return std::nullopt;
}

// ---------------- устройство и ключи ----------------

Task<QString> ApiClient::registerDevice(QString token, QString identityPub, QString identityDhPub, QString identityDhSignature) {
    const QJsonObject body7{{"identity_pubkey", identityPub}, {"identity_dh_pubkey", identityDhPub}, {"identity_dh_signature", identityDhSignature}};
    const Response r = co_await sendJson(
        "POST", "/register-device", token, body7);
    if (r.code != 200) fail("error.deviceRegisterFailed");
    co_return json::string(obj(r.body), "device_id");
}

Task<void> ApiClient::uploadPrekeys(QString token, QString deviceId, QString signedPrekey, QString signedPrekeySignature, QStringList oneTime) {
    const QJsonObject body8{{"device_id", deviceId}, {"signed_prekey", signedPrekey}, {"signed_prekey_signature", signedPrekeySignature}, {"one_time_prekeys", QJsonArray::fromStringList(oneTime)}};
    const Response r = co_await sendJson("POST", "/prekeys/upload", token, body8);
    if (r.code != 200) fail("error.prekeysFailed");
}

Task<QJsonObject> ApiClient::getPrekeyBundle(QString token, QString deviceId) {
    const Response r = co_await sendJson("GET", "/devices/" + deviceId + "/prekey-bundle", token, {});
    if (r.code == 409) fail("error.peerOutOfKeys");
    if (r.code != 200) fail("error.peerKeysFailed");
    co_return obj(r.body);
}

Task<std::optional<int>> ApiClient::getPrekeyCount(QString token, QString deviceId) {
    try {
        const Response r = co_await sendJson("GET", "/devices/" + deviceId + "/prekey-count", token, {});
        if (r.code == 200) co_return int(obj(r.body).value("remaining").toInteger());
    } catch (const std::exception &) {
    }
    co_return std::nullopt;
}

Task<AccountDevices> ApiClient::getDevicesByLogin(QString token, QString login) {
    const Response r = co_await sendJson("GET", "/accounts/" + QString::fromLatin1(QUrl::toPercentEncoding(login)) + "/devices", token, {});
    if (r.code == 404) fail("error.userNotFound");
    if (r.code != 200) fail("error.userLookupFailed");
    const QJsonObject o = obj(r.body);
    QString accountId = str(o, "account_id");
    if (accountId.isEmpty()) accountId = str(o, "accountId");
    if (accountId.isEmpty()) accountId = str(o, "id");
    if (accountId.isEmpty()) fail("error.noAccountId");
    co_return AccountDevices{accountId, objects(o, "devices")};
}

Task<std::optional<DeviceOwner>> ApiClient::getDeviceOwnerInfo(QString token, QString deviceId) {
    try {
        const Response r = co_await sendJson("GET", "/devices/" + deviceId + "/owner", token, {}, ShortTimeoutMs);
        if (r.code == 200) {
            const QJsonObject o = obj(r.body);
            const QString login = json::string(o, "login");
            co_return DeviceOwner{json::string(o, "account_id"), login, json::optString(o, "display_name").value_or(login)};
        }
    } catch (const std::exception &) {
    }
    co_return std::nullopt;
}

Task<bool> ApiClient::declineCall(QString token, QString deviceId, QString callId, bool busy) {
    QJsonObject body{{"device_id", deviceId}, {"call_id", callId}};
    if (busy) body.insert("reason", "busy");
    try {
        co_return (co_await sendJson("POST", "/calls/decline", token, body, ShortTimeoutMs)).code == 200;
    } catch (const ApiError &) {
        co_return false;
    }
}

Task<std::optional<QJsonObject>> ApiClient::getTurnCredentials(QString token) {
    try {
        const Response r = co_await sendJson("GET", "/turn-credentials", token, {}, ShortTimeoutMs);
        if (r.code == 200) co_return obj(r.body);
    } catch (const std::exception &) {
    }
    co_return std::nullopt;
}

Task<bool> ApiClient::unregisterPushToken(QString token, QString deviceId) {
    try {
        const QJsonObject body9{{"device_id", deviceId}};
        co_return (co_await sendJson("DELETE", "/push/register", token, body9, ShortTimeoutMs)).code == 200;
    } catch (const ApiError &) {
        co_return false;
    }
}

Task<std::optional<AppVersionInfo>> ApiClient::getAppVersion() {
    try {
        const Response r = co_await sendJson("GET", "/app/version", {}, {}, ShortTimeoutMs);
        if (r.code == 200) {
            const QJsonObject o = obj(r.body);
            co_return AppVersionInfo{intOr(o, "version_code", 0), str(o, "apk_url")};
        }
    } catch (const std::exception &) {
    }
    co_return std::nullopt;
}

// ---------------- аккаунт и профиль ----------------

Task<bool> ApiClient::deleteAccount(QString token) { co_return (co_await sendJson("DELETE", "/account", token, {}, ShortTimeoutMs)).code == 200; }

Task<std::optional<MyAccountInfo>> ApiClient::getMyAccountInfo(QString token) {
    try {
        const Response r = co_await sendJson("GET", "/account/me", token, {}, ShortTimeoutMs);
        if (r.code != 200) co_return std::nullopt;
        const QJsonObject o = obj(r.body);
        MyAccountInfo m;
        m.accountId = json::string(o, "account_id");
        m.login = json::string(o, "login");
        m.displayName = json::optString(o, "display_name");
        m.language = json::optString(o, "language").value_or(QStringLiteral("en"));
        m.email = json::optString(o, "email");
        m.hasAvatar = o.value("has_avatar").toBool();
        m.status = json::optString(o, "status");
        m.birthday = json::optString(o, "birthday");
        m.findByLoginVisibility = intOr(o, "find_by_login_visibility", 1);
        m.avatarVisibility = intOr(o, "avatar_visibility", 1);
        m.birthdayVisibility = intOr(o, "birthday_visibility", 1);
        m.statusVisibility = intOr(o, "status_visibility", 1);
        co_return m;
    } catch (const std::exception &) {
        co_return std::nullopt;
    }
}

Task<std::optional<AccountProfile>> ApiClient::getAccountProfile(QString token, QString login) {
    const Response r = co_await sendJson("GET", "/account/profile/" + QString::fromLatin1(QUrl::toPercentEncoding(login)), token, {});
    if (r.code == 404) co_return std::nullopt;
    if (r.code != 200) fail("error.userLookupFailed");
    const QJsonObject o = obj(r.body);
    const QString resolved = json::string(o, "login");
    co_return AccountProfile{json::string(o, "account_id"),        resolved,
                             json::optString(o, "display_name").value_or(resolved), objects(o, "devices"),
                             json::optString(o, "status"),         json::optString(o, "birthday"),
                             o.value("has_avatar").toBool()};
}

Task<void> ApiClient::putJson(QString token, QString path, QJsonObject body, QString errorKey) {
    if ((co_await sendJson("PUT", path, token, body)).code != 200) fail(errorKey);
}

Task<void> ApiClient::updateLanguage(QString token, QString language) {
    const QJsonObject body17{{"language", language}};
    co_await putJson(token, "/account/language", body17, "error.languageSaveFailed");
}
Task<void> ApiClient::changePassword(QString token, QString newPassword) {
    const QJsonObject body18{{"new_password", newPassword}};
    co_await putJson(token, "/account/password", body18, "error.changePasswordFailed");
}
Task<void> ApiClient::updateEmail(QString token, QString email) {
    const QJsonObject body19{{"email", email}};
    co_await putJson(token, "/account/email", body19, "error.emailSaveFailed");
}
Task<void> ApiClient::updateDisplayName(QString token, QString displayName) {
    const QJsonObject body20{{"display_name", displayName}};
    co_await putJson(token, "/account/display-name", body20, "error.displayNameSaveFailed");
}
Task<void> ApiClient::updateStatus(QString token, QString status) {
    const QJsonObject body21{{"status", status}};
    co_await putJson(token, "/account/status", body21, "error.statusSaveFailed");
}
Task<void> ApiClient::updateBirthday(QString token, std::optional<QString> birthday) {
    const QJsonObject body22{{"birthday", json::nullable(birthday)}};
    co_await putJson(token, "/account/birthday", body22, "error.birthdaySaveFailed");
}
Task<void> ApiClient::updatePrivacy(QString token, PrivacySettings p) {
    const QJsonObject body23{{"find_by_login", p.findByLogin}, {"avatar", p.avatar}, {"birthday", p.birthday}, {"status", p.status}};
    co_await putJson(token, "/account/privacy", body23,
                     "error.privacySaveFailed");
}

Task<void> ApiClient::requestEmailVerification(QString token, QString email) {
    const QJsonObject body10{{"email", email}};
    const Response r = co_await sendJson("POST", "/account/email/request", token, body10);
    if (r.code == 409) fail("error.emailTaken");
    if (r.code != 200) fail("error.emailVerifyRequestFailed");
}

Task<void> ApiClient::confirmEmailVerification(QString token, QString code) {
    const QJsonObject body11{{"code", code}};
    const Response r = co_await sendJson("POST", "/account/email/confirm", token, body11);
    if (r.code == 409) fail("error.emailTaken");
    if (r.code != 200) fail("error.recoveryWrongCode");
}

Task<void> ApiClient::uploadAvatar(QString token, QByteArray jpeg) {
    auto *multi = new QHttpMultiPart(QHttpMultiPart::FormDataType);
    QHttpPart file = fileField("file", "avatar.jpg", "image/jpeg");
    file.setBody(jpeg);
    multi->append(file);
    QNetworkReply *reply = net_.post(request("/account/avatar", token, MediaTimeoutMs), multi);
    multi->setParent(reply);
    co_await awaitReply{reply};
    const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (code != 200) fail("error.uploadFailed", code);
}

Task<void> ApiClient::deleteAvatar(QString token) {
    if ((co_await sendJson("DELETE", "/account/avatar", token, {})).code != 200) fail("error.uploadFailed");
}

Task<std::optional<QByteArray>> ApiClient::avatarBytes(QString token, QString path) {
    const Response r = co_await send(request(path, token, ShortTimeoutMs), "GET", {}, "error.avatarLoadFailed");
    if (r.code == 404) co_return std::nullopt;
    if (r.code != 200 || r.body.isEmpty()) fail("error.avatarLoadFailed", r.code);
    co_return r.body;
}

Task<std::optional<QByteArray>> ApiClient::getAvatar(QString token, QString accountId) { return avatarBytes(token, "/account/avatar/" + accountId); }
Task<std::optional<QByteArray>> ApiClient::getMyAvatar(QString token) { return avatarBytes(token, "/account/avatar"); }

// ---------------- чаты и контакты ----------------

Task<void> ApiClient::postPeer(QString token, QString path, QString peerAccountId, QString errorKey) {
    const QJsonObject body12{{"peer_account_id", peerAccountId}};
    if ((co_await sendJson("POST", path, token, body12)).code != 200) fail(errorKey);
}

Task<void> ApiClient::muteChat(QString token, QString peer) { co_await postPeer(token, "/chats/mute", peer, "error.muteFailed"); }
Task<void> ApiClient::unmuteChat(QString token, QString peer) { co_await postPeer(token, "/chats/unmute", peer, "error.muteFailed"); }
Task<void> ApiClient::blockContact(QString token, QString peer) { co_await postPeer(token, "/contacts/block", peer, "error.blockFailed"); }
Task<void> ApiClient::unblockContact(QString token, QString peer) { co_await postPeer(token, "/contacts/unblock", peer, "error.blockFailed"); }

Task<QStringList> ApiClient::getMutedChats(QString token) {
    try {
        const Response r = co_await sendJson("GET", "/chats/muted", token, {}, ShortTimeoutMs);
        if (r.code == 200) co_return strings(obj(r.body), "peer_account_ids");
    } catch (const std::exception &) {
    }
    co_return QStringList();
}

Task<std::optional<QMap<QString, qint64>>> ApiClient::getChatWallpapers(QString token) {
    try {
        const Response r = co_await sendJson("GET", "/chats/wallpapers", token, {}, ShortTimeoutMs);
        if (r.code == 200) {
            QMap<QString, qint64> m;
            for (const QJsonObject &w : objects(obj(r.body), "wallpapers")) {
                if (const auto id = json::optString(w, "peer_account_id")) m[*id] = w.value("version").toInteger();
            }
            co_return m;
        }
    } catch (const std::exception &) {
    }
    co_return std::nullopt;
}

Task<std::optional<QByteArray>> ApiClient::getChatWallpaper(QString token, QString peerAccountId) {
    const Response r = co_await send(request("/chats/wallpapers/" + peerAccountId, token, MediaTimeoutMs), "GET", {}, "error.wallpaperFailed");
    if (r.code == 404) co_return std::nullopt;
    if (r.code != 200 || r.body.isEmpty()) fail("error.wallpaperFailed", r.code);
    co_return r.body;
}

Task<qint64> ApiClient::setChatWallpaper(QString token, QString peerAccountId, QByteArray jpeg, bool forPeer) {
    auto *multi = new QHttpMultiPart(QHttpMultiPart::FormDataType);
    multi->append(formField("for_peer", forPeer ? "1" : "0"));
    QHttpPart file = fileField("file", "wallpaper.jpg", "image/jpeg");
    file.setBody(jpeg);
    multi->append(file);
    QNetworkReply *reply = net_.put(request("/chats/wallpapers/" + peerAccountId, token, MediaTimeoutMs), multi);
    multi->setParent(reply);
    co_await awaitReply{reply};
    const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (code != 200) fail("error.wallpaperFailed", code);
    co_return obj(reply->readAll()).value("version").toInteger();
}

Task<void> ApiClient::deleteChatWallpaper(QString token, QString peerAccountId) {
    if ((co_await sendJson("DELETE", "/chats/wallpapers/" + peerAccountId, token, {})).code != 200) fail("error.wallpaperFailed");
}

Task<std::optional<BlockedContacts>> ApiClient::getBlockedContacts(QString token) {
    try {
        const Response r = co_await sendJson("GET", "/contacts/blocked", token, {}, ShortTimeoutMs);
        if (r.code == 200) {
            const QJsonObject o = obj(r.body);
            co_return BlockedContacts{strings(o, "blocked_by_me"), strings(o, "blocking_me")};
        }
    } catch (const std::exception &) {
    }
    co_return std::nullopt;
}

Task<void> ApiClient::reportMessage(QString token, QString reportedDeviceId, QString messageText, QString reason) {
    const QJsonObject body13{{"reported_device_id", reportedDeviceId}, {"message_text", messageText}, {"reason", reason}};
    const Response r = co_await sendJson("POST", "/reports", token, body13,
                                         ShortTimeoutMs);
    if (r.code != 200) fail("error.reportFailed", r.code);
}

Task<void> ApiClient::reportCrashLog(QString token, QString logText, QString kind) {
    const QJsonObject body14{{"message", logText}, {"kind", kind}};
    const Response r = co_await sendJson("POST", "/feedback", token, body14, 15000);
    if (r.code != 200) fail("crash report failed", r.code);
}

// ---------------- вложения ----------------

Task<QString> ApiClient::uploadEncryptedMediaFile(QString token, QString path, QString recipientAccountId, ProgressFn onProgress) {
    auto *multi = new QHttpMultiPart(QHttpMultiPart::FormDataType);
    multi->append(formField("recipient_account_id", recipientAccountId.toUtf8()));
    auto *file = new QFile(path, multi);
    if (!file->open(QIODevice::ReadOnly)) {
        delete multi;
        fail("error.uploadFailed");
    }
    QHttpPart part = fileField("file", "encrypted.bin", "application/octet-stream");
    part.setBodyDevice(file);
    multi->append(part);
    QNetworkReply *reply = net_.post(request("/upload-media", token, MediaTimeoutMs), multi);
    multi->setParent(reply);
    if (onProgress) {
        QObject::connect(reply, &QNetworkReply::uploadProgress, reply, [onProgress](qint64 sent, qint64 total) {
            if (total > 0) onProgress(sent * 100.0 / total);
        });
    }
    co_await awaitReply{reply};
    const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QString text = QString::fromUtf8(reply->readAll());
    if (code != 200 || text.isEmpty()) fail("error.uploadFailed", code ? std::optional(code) : std::nullopt);
    co_return text;
}

Task<ChunkedUploadInit> ApiClient::initChunkedUpload(QString token, qint64 sizeBytes) {
    const QJsonObject body15{{"size_bytes", sizeBytes}};
    const Response r = co_await sendJson("POST", "/upload-media/init", token, body15);
    if (r.code != 200) fail("error.uploadFailed", r.code);
    const QJsonObject o = obj(r.body);
    co_return ChunkedUploadInit{json::string(o, "media_id"), json::string(o, "upload_id"), intOr(o, "part_size", 0)};
}

Task<void> ApiClient::uploadChunkedPart(QString token, QString mediaId, QString uploadId, int partNumber, QByteArray data, ProgressFn onProgress) {
    QNetworkRequest req = request(QStringLiteral("/upload-media/%1/part/%2?upload_id=%3").arg(mediaId).arg(partNumber).arg(uploadId), token, MediaTimeoutMs);
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/octet-stream"));
    QNetworkReply *reply = net_.put(req, data);
    if (onProgress) {
        QObject::connect(reply, &QNetworkReply::uploadProgress, reply, [onProgress](qint64 sent, qint64 total) {
            if (total > 0) onProgress(sent * 100.0 / total);
        });
    }
    co_await awaitReply{reply};
    const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (code != 200) fail("error.uploadFailed", code ? std::optional(code) : std::nullopt);
}

Task<QSet<int>> ApiClient::listChunkedParts(QString token, QString mediaId, QString uploadId) {
    const Response r = co_await send(request("/upload-media/" + mediaId + "/parts?upload_id=" + uploadId, token), "GET", {}, "error.uploadFailed");
    if (r.code != 200) fail("error.uploadFailed", r.code);
    QSet<int> parts;
    for (const QJsonValue &v : QJsonDocument::fromJson(r.body).array()) parts.insert(int(v.toObject().value("part_number").toInteger()));
    co_return parts;
}

Task<void> ApiClient::completeChunkedUpload(QString token, QString mediaId, QString uploadId, QString recipientAccountId) {
    const QJsonObject body16{{"recipient_account_id", recipientAccountId}};
    const Response r = co_await sendJson("POST", "/upload-media/" + mediaId + "/complete?upload_id=" + uploadId, token, body16);
    if (r.code != 200) fail("error.uploadFailed", r.code);
}

Task<void> ApiClient::abortChunkedUpload(QString token, QString mediaId, QString uploadId) {
    try {
        co_await send(request("/upload-media/" + mediaId + "/abort?upload_id=" + uploadId, token), "POST", {});
    } catch (const std::exception &) {
    }
}

Task<qint64> ApiClient::probeEncryptedMediaSize(QString token, QString mediaId) {
    try {
        const Response r = co_await send(request("/media/" + mediaId, token, ShortTimeoutMs), "HEAD", {});
        co_return r.headers.value("content-length").toLongLong();
    } catch (const std::exception &) {
        co_return 0;
    }
}

Task<qint64> ApiClient::downloadEncryptedMediaResumable(QString token, QString mediaId, QString dest, std::optional<qint64> knownTotal,
                                                        ProgressFn onProgress) {
    qint64 existing = QFile::exists(dest) ? QFile(dest).size() : 0;
    qint64 total = knownTotal.value_or(0);
    if (existing > 0 && total <= 0) {
        total = co_await probeEncryptedMediaSize(token, mediaId);
        if (total > 0 && existing == total) {
            if (onProgress) onProgress(100.0);
            co_return total;
        }
        if (total > 0 && total < existing) {
            QFile::remove(dest);
            existing = 0;
        }
    }
    QNetworkRequest req = request("/media/" + mediaId, token, MediaTimeoutMs);
    if (existing > 0) req.setRawHeader("Range", "bytes=" + QByteArray::number(existing) + "-");
    QNetworkReply *reply = net_.get(req);
    auto out = std::make_shared<QFile>(dest);
    auto state = std::make_shared<std::pair<qint64, bool>>(0, false); // получено байт, открыт ли файл
    QObject::connect(reply, &QNetworkReply::readyRead, reply, [reply, out, state, existing, &total, onProgress] {
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code != 200 && code != 206) return;
        if (!state->second) {
            const bool append = code == 206 && existing > 0;
            state->second = out->open(append ? QIODevice::Append : (QIODevice::WriteOnly | QIODevice::Truncate));
            const QByteArray range = reply->rawHeader("Content-Range");
            if (const int slash = range.lastIndexOf('/'); slash >= 0) total = range.mid(slash + 1).toLongLong();
            if (total <= 0 && reply->header(QNetworkRequest::ContentLengthHeader).toLongLong() > 0) {
                total = (append ? existing : 0) + reply->header(QNetworkRequest::ContentLengthHeader).toLongLong();
            }
        }
        const QByteArray chunk = reply->readAll();
        if (state->second) out->write(chunk);
        state->first += chunk.size();
        const qint64 base = (code == 206 && existing > 0) ? existing : 0;
        if (onProgress && total > 0) onProgress(std::clamp((base + state->first) * 100.0 / total, 0.0, 100.0));
    });
    co_await awaitReply{reply};
    const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (state->second) {
        out->write(reply->readAll());
        out->close();
    }
    if (code == 416 && existing > 0) {
        QFile::remove(dest);
        co_return co_await downloadEncryptedMediaResumable(token, mediaId, dest, std::nullopt, onProgress);
    }
    if (reply->error() != QNetworkReply::NoError && code != 200 && code != 206) fail("error.downloadFailed", code ? std::optional(code) : std::nullopt);
    if (code != 200 && code != 206) fail("error.downloadFailed", code);
    if (reply->error() != QNetworkReply::NoError) fail("error.downloadFailed"); // обрыв посреди — хвост докачается
    if (total <= 0) total = QFile(dest).size();
    co_return total;
}

Task<void> ApiClient::confirmMediaReceived(QString token, QString mediaId) {
    try {
        co_await send(request("/media/" + mediaId + "/received", token), "POST", {});
    } catch (const std::exception &) {
    }
}

// ---------------- стикеры ----------------

StickerPackInfo ApiClient::parseStickerPack(const QJsonObject &o) {
    StickerPackInfo p;
    p.id = json::string(o, "id");
    p.title = str(o, "title");
    p.isOwner = o.value("is_owner").toBool();
    p.installed = o.value("installed").toBool();
    p.deleted = o.value("deleted").toBool();
    for (const QJsonObject &s : objects(o, "stickers")) p.stickers << StickerInfo{json::string(s, "id"), json::string(s, "format"), p.id};
    return p;
}

Task<QList<StickerPackInfo>> ApiClient::getMyStickerPacks(QString token) {
    const Response r = co_await sendJson("GET", "/stickers/packs/mine", token, {}, ShortTimeoutMs);
    if (r.code != 200) fail("error.stickersFailed", r.code);
    QList<StickerPackInfo> packs;
    for (const QJsonObject &o : objects(obj(r.body), "packs")) packs << parseStickerPack(o);
    co_return packs;
}

Task<std::optional<StickerPackInfo>> ApiClient::getStickerPack(QString token, QString packId) {
    const Response r = co_await sendJson("GET", "/stickers/packs/" + packId, token, {}, ShortTimeoutMs);
    if (r.code == 404) co_return std::nullopt;
    if (r.code != 200) fail("error.stickersFailed", r.code);
    co_return parseStickerPack(obj(r.body));
}

Task<std::optional<StickerPackInfo>> ApiClient::getStickerPackBySticker(QString token, QString stickerId) {
    const Response r = co_await sendJson("GET", "/stickers/items/" + stickerId + "/pack", token, {}, ShortTimeoutMs);
    if (r.code == 404) co_return std::nullopt;
    if (r.code != 200) fail("error.stickersFailed", r.code);
    co_return parseStickerPack(obj(r.body));
}

Task<bool> ApiClient::downloadStickerPack(QString token, QString packId, QString dest) {
    const Response r = co_await send(request("/stickers/packs/" + packId + "/files", token, MediaTimeoutMs), "GET", {}, "error.downloadFailed");
    if (r.code == 410) co_return false;
    if (r.code != 200) fail("error.downloadFailed", r.code);
    QFile f(dest);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate) || f.write(r.body) != r.body.size()) fail("error.downloadFailed");
    co_return true;
}

Task<void> ApiClient::installStickerPack(QString token, QString packId) {
    if ((co_await send(request("/stickers/packs/" + packId + "/install", token, ShortTimeoutMs), "POST", {})).code != 200) fail("error.stickersFailed");
}

Task<void> ApiClient::uninstallStickerPack(QString token, QString packId) {
    if ((co_await send(request("/stickers/packs/" + packId + "/install", token, ShortTimeoutMs), "DELETE", {})).code != 200) {
        fail("error.stickersFailed");
    }
}

Task<void> ApiClient::deleteStickerPack(QString token, QString packId) {
    if ((co_await send(request("/stickers/packs/" + packId, token, ShortTimeoutMs), "DELETE", {})).code != 200) fail("error.stickersFailed");
}

Task<StickerPackInfo> ApiClient::uploadStickerPack(QString token, QString title, QString archive, ProgressFn onProgress,
                                                   std::function<void(const StickerUploadEvent &)> onEvent) {
    QUrlQuery q;
    q.addQueryItem("title", title);
    QNetworkRequest req = request("/stickers/packs?" + q.toString(QUrl::FullyEncoded), token, MediaTimeoutMs);
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/zip"));
    auto *file = new QFile(archive);
    if (!file->open(QIODevice::ReadOnly)) {
        delete file;
        fail("error.uploadFailed");
    }
    QNetworkReply *reply = net_.post(req, file);
    file->setParent(reply);
    if (onProgress) {
        QObject::connect(reply, &QNetworkReply::uploadProgress, reply, [onProgress](qint64 sent, qint64 total) {
            if (total > 0) onProgress(sent * 100.0 / total);
        });
    }
    // ответ — NDJSON с этапами обработки: читаем построчно по мере прихода
    auto buffer = std::make_shared<QByteArray>();
    auto result = std::make_shared<std::optional<StickerPackInfo>>();
    auto error = std::make_shared<std::optional<StickerUploadError>>();
    auto drain = [reply, buffer, result, error, onEvent](bool final) {
        if (reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() != 200) return;
        buffer->append(reply->readAll());
        while (true) {
            int nl = buffer->indexOf('\n');
            if (nl < 0) {
                if (!final || buffer->trimmed().isEmpty()) return;
                nl = buffer->size();
            }
            const QByteArray line = buffer->left(nl).trimmed();
            buffer->remove(0, nl + 1);
            if (line.isEmpty() || result->has_value() || error->has_value()) continue;
            const QJsonObject o = QJsonDocument::fromJson(line).object();
            StickerUploadEvent e;
            e.stage = str(o, "stage");
            if (o.contains("bytes")) e.bytes = o.value("bytes").toVariant().toLongLong();
            if (intOr(o, "count", -1) >= 0) e.count = intOr(o, "count", -1);
            if (intOr(o, "index", -1) >= 0) e.index = intOr(o, "index", -1);
            if (intOr(o, "total", -1) >= 0) e.total = intOr(o, "total", -1);
            e.name = json::optString(o, "name");
            e.code = json::optString(o, "code");
            if (intOr(o, "limit", 0) > 0) e.limit = intOr(o, "limit", 0);
            if (e.stage == "error") {
                error->emplace(e.code.value_or("server.error"), e.name, e.limit);
            } else if (e.stage == "done") {
                if (o.value("pack").isObject()) result->emplace(parseStickerPack(o.value("pack").toObject()));
                else error->emplace("server.error");
            } else if (onEvent) {
                onEvent(e);
            }
        }
    };
    QObject::connect(reply, &QNetworkReply::readyRead, reply, [drain] { drain(false); });
    co_await awaitReply{reply};
    const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (code != 200) {
        const QJsonObject o = QJsonDocument::fromJson(reply->readAll()).object();
        const auto c = json::optString(o, "code");
        if (!c) fail("error.uploadFailed", code ? std::optional(code) : std::nullopt);
        throw StickerUploadError(*c, std::nullopt, intOr(o, "limit", 0) > 0 ? std::optional(intOr(o, "limit", 0)) : std::nullopt);
    }
    drain(true);
    if (*error) throw **error;
    if (!*result) throw StickerUploadError("server.error");
    co_return **result;
}

} // namespace osh
