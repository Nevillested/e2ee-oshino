import Foundation

// REST-клиент сервера (как core/net/ApiClient.kt). Вместо готового текста ошибки
// бросается [ApiError] с КЛЮЧОМ локализации ("error.loginTaken" и т. п.) —
// переводит его слой интерфейса. Транспорт — URLSession (HTTP/2, системные
// прокси и сертификаты), async/await.

public struct ApiConfig: Sendable {
    public var baseURL: URL

    public init(baseURL: URL = URL(string: "https://ee2e.oshino.space")!) { self.baseURL = baseURL }

    /// wss:// для WebSocket.
    public var webSocketURL: URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        return c.url!
    }
}

public struct ApiError: Error, Equatable {
    public let key: String
    public let statusCode: Int?

    public init(_ key: String, _ statusCode: Int? = nil) {
        self.key = key
        self.statusCode = statusCode
    }

    public static let cancelled = ApiError("error.cancelledByUser")
}

public struct LoginResult: Sendable { public let token: String; public let language: String }
public struct ChunkedUploadInit: Sendable { public let mediaId: String; public let uploadId: String; public let partSize: Int }
public struct BlockedContacts: Sendable { public let blockedByMe: [String]; public let blockingMe: [String] }
public struct DeviceOwner: Sendable { public let accountId: String; public let login: String; public let displayName: String }
public struct AccountDevices: Sendable { public let accountId: String; public let devices: [[String: JSONValue]] }
public struct AppVersionInfo: Equatable, Sendable { public let versionCode: Int; public let apkURL: String? }

public struct MyAccountInfo: Sendable {
    public let accountId: String
    public let login: String
    public let displayName: String?
    public let language: String
    public let email: String?
    public let hasAvatar: Bool
    public let status: String?
    public let birthday: String?
    public let findByLoginVisibility: Int
    public let avatarVisibility: Int
    public let birthdayVisibility: Int
    public let statusVisibility: Int
}

public struct AccountProfile: Sendable {
    public let accountId: String
    public let login: String
    public let displayName: String
    public let devices: [[String: JSONValue]]
    public let status: String?
    public let birthday: String?
    public let hasAvatar: Bool
}

/// Видимость полей профиля: 0 = никто, 1 = все, 2 = только контакты.
public struct PrivacySettings: Sendable {
    public var findByLogin: Int
    public var avatar: Int
    public var birthday: Int
    public var status: Int

    public init(findByLogin: Int, avatar: Int, birthday: Int, status: Int) {
        self.findByLogin = findByLogin
        self.avatar = avatar
        self.birthday = birthday
        self.status = status
    }
}

public struct StickerInfo: Sendable, Hashable {
    public let id: String
    public let format: String
    public let packId: String
    public var animated: Bool { format == "tgs" }
}

public struct StickerPackInfo: Sendable {
    public let id: String
    public let title: String
    public let isOwner: Bool
    public let installed: Bool
    public let deleted: Bool
    public let stickers: [StickerInfo]
}

public final class ApiClient: @unchecked Sendable {
    public let config: ApiConfig
    private let http: URLSession
    private let media: URLSession

    /// Последняя версия приложения по данным сервера (для сборок не из App Store не нужна, оставлена для паритета).
    public private(set) var latestVersion: AppVersionInfo?

    public init(config: ApiConfig = ApiConfig()) {
        self.config = config
        let short = URLSessionConfiguration.default
        short.timeoutIntervalForRequest = 30
        short.waitsForConnectivity = false
        http = URLSession(configuration: short)
        let long = URLSessionConfiguration.default
        long.timeoutIntervalForRequest = 60
        long.timeoutIntervalForResource = 60 * 60
        media = URLSession(configuration: long)
    }

    /// Сменилась сеть: обрываем идущие запросы, чтобы новые не сели на мёртвый сокет.
    public func dropConnections() {
        http.getAllTasks { $0.forEach { $0.cancel() } }
        media.getAllTasks { $0.forEach { $0.cancel() } }
    }

    // MARK: - основа

    private func request(_ path: String, token: String? = nil, method: String = "GET", query: [String: String] = [:]) -> URLRequest {
        var c = URLComponents(url: config.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    private func withJSON(_ r: URLRequest, _ fields: [String: JSONValue]) -> URLRequest {
        var r = r
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(JSONValue.object(fields).encoded().utf8)
        return r
    }

    @discardableResult
    private func call(_ r: URLRequest, session: URLSession? = nil, timeout: TimeInterval? = nil) async throws -> (Int, Data) {
        var r = r
        if let timeout { r.timeoutInterval = timeout }
        let (data, response) = try await (session ?? http).data(for: r)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// Короткие "фоновые" запросы — не дольше 8 с.
    private func callShort(_ r: URLRequest) async throws -> (Int, Data) { try await call(r, timeout: 8) }

    private func object(_ data: Data) throws -> [String: JSONValue] {
        guard let o = try JSONValue.parse(data).object else { throw ApiError("error.badResponse") }
        return o
    }

    private func fail(_ key: String, _ code: Int? = nil) -> ApiError { ApiError(key, code) }

    /// Сетевые сбои передачи → ключ ошибки; отмена — как есть.
    private func transfer<T>(_ errorKey: String, _ block: () async throws -> T) async throws -> T {
        do { return try await block() }
        catch let e as ApiError { throw e }
        catch is CancellationError { throw CancellationError() }
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch { throw ApiError(errorKey) }
    }

    // MARK: - версия

    public func getAppVersion() async -> AppVersionInfo? {
        guard case let (code, body)? = try? await callShort(request("/app/version")), code == 200,
              let o = try? object(body), let v = o["version_code"]?.int, v > 0 else { return nil }
        let apk = o["apk_url"]?.string.flatMap { $0.isEmpty ? nil : URL(string: $0, relativeTo: config.baseURL)?.absoluteString }
        let info = AppVersionInfo(versionCode: Int(v), apkURL: apk)
        latestVersion = info
        return info
    }

    // MARK: - регистрация, вход, восстановление

    /// Возвращает otpauth://-ссылку для настройки TOTP.
    public func register(login: String, password: String, inviteCode: String) async throws -> String {
        let (code, body) = try await call(withJSON(request("/register", method: "POST"), ["login": .string(login), "password": .string(password), "invite_code": .string(inviteCode)]))
        switch code {
        case 200:
            guard let url = try object(body)["totp_url"]?.string else { throw fail("error.registerFailed") }
            return url
        case 409: throw fail("error.loginTaken")
        case 403: throw fail("error.loginReserved")
        case 422: throw fail("error.inviteCodeInvalid")
        default: throw fail("error.registerFailed", code)
        }
    }

    public func verifyTotp(login: String, code: String) async throws {
        let (status, _) = try await call(withJSON(request("/verify-totp", method: "POST"), ["login": .string(login), "code": .string(code)]))
        if status != 200 { throw fail("error.wrongTotpCode") }
    }

    public func login(login: String, password: String, totpCode: String) async throws -> LoginResult {
        let (code, body) = try await call(withJSON(request("/login", method: "POST"), ["login": .string(login), "password": .string(password), "totp_code": .string(totpCode)]))
        if code == 429 { throw fail("error.tooManyLoginAttempts") }
        guard code == 200, let o = try? object(body), let token = o["token"]?.string else { throw fail("error.wrongCredentials") }
        return LoginResult(token: token, language: o["language"]?.string ?? "en")
    }

    public func requestPasswordRecovery(login: String) async throws {
        let (code, _) = try await call(withJSON(request("/account/recover/request", method: "POST"), ["login": .string(login)]))
        switch code {
        case 200: return
        case 404: throw fail("error.recoveryUserNotFound")
        case 422: throw fail("error.recoveryNoEmailOnFile")
        default: throw fail("error.recoveryRequestFailed")
        }
    }

    public func verifyRecoveryCode(login: String, token: String) async throws {
        let (code, _) = try await call(withJSON(request("/account/recover/verify", method: "POST"), ["login": .string(login), "token": .string(token)]))
        if code != 200 { throw fail("error.recoveryWrongCode") }
    }

    public func resetPasswordWithRecoveryCode(login: String, token: String, newPassword: String) async throws {
        let (code, _) = try await call(withJSON(request("/account/recover/reset", method: "POST"),
                                                ["login": .string(login), "token": .string(token), "new_password": .string(newPassword)]))
        if code != 200 { throw fail("error.recoveryWrongCode") }
    }

    /// Возвращает новую otpauth://-ссылку.
    public func resetTotpWithRecoveryCode(login: String, token: String) async throws -> String {
        let (code, body) = try await call(withJSON(request("/account/recover/reset-totp", method: "POST"), ["login": .string(login), "token": .string(token)]))
        guard code == 200, let url = try object(body)["totp_url"]?.string else { throw fail("error.recoveryWrongCode") }
        return url
    }

    /// true — сессия жива, false — сервер её больше не признаёт (401), nil — неизвестно.
    /// Только 401 — повод выйти: 5xx и сеть сессию не отменяют.
    public func checkSession(token: String) async -> Bool? {
        guard case let (code, _)? = try? await callShort(request("/session/check", token: token)) else { return nil }
        switch code {
        case 200: return true
        case 401: return false
        default: return nil
        }
    }

    // MARK: - устройство и ключи

    public func registerDevice(token: String, identityPubkey: String, identityDhPubkey: String, identityDhSignature: String) async throws -> String {
        let (code, body) = try await call(withJSON(request("/register-device", token: token, method: "POST"), [
            "identity_pubkey": .string(identityPubkey), "identity_dh_pubkey": .string(identityDhPubkey), "identity_dh_signature": .string(identityDhSignature),
        ]))
        guard code == 200, let id = try object(body)["device_id"]?.string else { throw fail("error.deviceRegisterFailed") }
        return id
    }

    public func uploadPrekeys(token: String, deviceId: String, signedPrekey: String, signedPrekeySignature: String, oneTimePrekeys: [String]) async throws {
        let (code, _) = try await call(withJSON(request("/prekeys/upload", token: token, method: "POST"), [
            "device_id": .string(deviceId), "signed_prekey": .string(signedPrekey),
            "signed_prekey_signature": .string(signedPrekeySignature), "one_time_prekeys": .array(oneTimePrekeys.map(JSONValue.string)),
        ]))
        if code != 200 { throw fail("error.prekeysFailed") }
    }

    public func getPrekeyBundle(token: String, deviceId: String) async throws -> [String: JSONValue] {
        let (code, body) = try await call(request("/devices/\(deviceId)/prekey-bundle", token: token))
        if code == 409 { throw fail("error.peerOutOfKeys") }
        if code != 200 { throw fail("error.peerKeysFailed") }
        return try object(body)
    }

    public func getPrekeyCount(token: String, deviceId: String) async -> Int? {
        guard case let (code, body)? = try? await call(request("/devices/\(deviceId)/prekey-count", token: token)), code == 200,
              let n = try? object(body)["remaining"]?.int else { return nil }
        return Int(n)
    }

    public func getDevicesByLogin(token: String, login: String) async throws -> AccountDevices {
        let (code, body) = try await call(request("/accounts/\(login)/devices", token: token))
        if code == 404 { throw fail("error.userNotFound") }
        if code != 200 { throw fail("error.userLookupFailed") }
        let o = try object(body)
        guard let id = o["account_id"]?.string ?? o["accountId"]?.string ?? o["id"]?.string else { throw fail("error.noAccountId") }
        return AccountDevices(accountId: id, devices: (o["devices"]?.array ?? []).compactMap(\.object))
    }

    public func getDeviceOwnerInfo(token: String, deviceId: String) async -> DeviceOwner? {
        guard case let (code, body)? = try? await callShort(request("/devices/\(deviceId)/owner", token: token)), code == 200,
              let o = try? object(body), let login = o["login"]?.string, let id = o["account_id"]?.string else { return nil }
        return DeviceOwner(accountId: id, login: login, displayName: o["display_name"]?.string ?? login)
    }

    /// Отклонить звонок, который сервер держит до подключения этого устройства. [busy] — "занято".
    @discardableResult
    public func declineCall(token: String, deviceId: String, callId: String, busy: Bool = false) async -> Bool {
        var f: [String: JSONValue] = ["device_id": .string(deviceId), "call_id": .string(callId)]
        if busy { f["reason"] = "busy" }
        return (try? await callShort(withJSON(request("/calls/decline", token: token, method: "POST"), f)).0) == 200
    }

    public func getTurnCredentials(token: String) async -> [String: JSONValue]? {
        guard case let (code, body)? = try? await callShort(request("/turn-credentials", token: token)), code == 200 else { return nil }
        return try? object(body)
    }

    /// Push-токены APNs (hex): обычный — уведомления о сообщениях, VoIP — звонки (PushKit).
    /// nil — не менять. [sandbox] — сборка из Xcode (development APNs).
    public func registerApnsTokens(token: String, deviceId: String, alert: String?, voip: String?, sandbox: Bool) async -> Bool {
        var f: [String: JSONValue] = ["device_id": .string(deviceId), "sandbox": .bool(sandbox)]
        if let alert { f["alert_token"] = .string(alert) }
        if let voip { f["voip_token"] = .string(voip) }
        return (try? await callShort(withJSON(request("/push/register-apns", token: token, method: "POST"), f)).0) == 200
    }

    /// Снять все push-токены устройства (выход из аккаунта).
    public func unregisterPushToken(token: String, deviceId: String) async -> Bool {
        (try? await callShort(withJSON(request("/push/register", token: token, method: "DELETE"), ["device_id": .string(deviceId)])).0) == 200
    }

    // MARK: - аккаунт и профиль

    public func deleteAccount(token: String) async throws -> Bool {
        try await callShort(request("/account", token: token, method: "DELETE")).0 == 200
    }

    public func getMyAccountInfo(token: String) async -> MyAccountInfo? {
        guard case let (code, body)? = try? await callShort(request("/account/me", token: token)), code == 200,
              let o = try? object(body), let id = o["account_id"]?.string, let login = o["login"]?.string else { return nil }
        func vis(_ k: String) -> Int { Int(o[k]?.int ?? 1) }
        return MyAccountInfo(
            accountId: id, login: login, displayName: o["display_name"]?.string, language: o["language"]?.string ?? "en",
            email: o["email"]?.string, hasAvatar: o["has_avatar"]?.bool ?? false, status: o["status"]?.string, birthday: o["birthday"]?.string,
            findByLoginVisibility: vis("find_by_login_visibility"), avatarVisibility: vis("avatar_visibility"),
            birthdayVisibility: vis("birthday_visibility"), statusVisibility: vis("status_visibility")
        )
    }

    /// nil — такого логина нет (или он скрыт настройкой приватности).
    public func getAccountProfile(token: String, login: String) async throws -> AccountProfile? {
        let (code, body) = try await call(request("/account/profile/\(login)", token: token))
        if code == 404 { return nil }
        guard code == 200 else { throw fail("error.userLookupFailed") }
        let o = try object(body)
        guard let resolved = o["login"]?.string, let id = o["account_id"]?.string else { throw fail("error.userLookupFailed") }
        return AccountProfile(
            accountId: id, login: resolved, displayName: o["display_name"]?.string ?? resolved,
            devices: (o["devices"]?.array ?? []).compactMap(\.object), status: o["status"]?.string, birthday: o["birthday"]?.string,
            hasAvatar: o["has_avatar"]?.bool ?? false
        )
    }

    private func put(_ token: String, _ path: String, _ fields: [String: JSONValue], _ errorKey: String) async throws {
        if try await call(withJSON(request(path, token: token, method: "PUT"), fields)).0 != 200 { throw fail(errorKey) }
    }

    public func updateLanguage(token: String, language: String) async throws { try await put(token, "/account/language", ["language": .string(language)], "error.languageSaveFailed") }
    public func changePassword(token: String, newPassword: String) async throws { try await put(token, "/account/password", ["new_password": .string(newPassword)], "error.changePasswordFailed") }
    public func updateEmail(token: String, email: String) async throws { try await put(token, "/account/email", ["email": .string(email)], "error.emailSaveFailed") }
    public func updateDisplayName(token: String, displayName: String) async throws { try await put(token, "/account/display-name", ["display_name": .string(displayName)], "error.displayNameSaveFailed") }
    public func updateStatus(token: String, status: String) async throws { try await put(token, "/account/status", ["status": .string(status)], "error.statusSaveFailed") }
    /// [birthday] — "YYYY-MM-DD" или nil (убрать).
    public func updateBirthday(token: String, birthday: String?) async throws { try await put(token, "/account/birthday", ["birthday": .optional(birthday)], "error.birthdaySaveFailed") }

    public func updatePrivacy(token: String, _ p: PrivacySettings) async throws {
        try await put(token, "/account/privacy", [
            "find_by_login": .int(Int64(p.findByLogin)), "avatar": .int(Int64(p.avatar)), "birthday": .int(Int64(p.birthday)), "status": .int(Int64(p.status)),
        ], "error.privacySaveFailed")
    }

    public func requestEmailVerification(token: String, email: String) async throws {
        let (code, _) = try await call(withJSON(request("/account/email/request", token: token, method: "POST"), ["email": .string(email)]))
        if code == 409 { throw fail("error.emailTaken") }
        if code != 200 { throw fail("error.emailVerifyRequestFailed") }
    }

    public func confirmEmailVerification(token: String, code: String) async throws {
        let (status, _) = try await call(withJSON(request("/account/email/confirm", token: token, method: "POST"), ["code": .string(code)]))
        if status == 409 { throw fail("error.emailTaken") }
        if status != 200 { throw fail("error.recoveryWrongCode") }
    }

    public func uploadAvatar(token: String, jpeg: Data) async throws {
        let (r, body) = multipart(request("/account/avatar", token: token, method: "POST"), fields: [:], file: ("file", "avatar.jpg", "image/jpeg", jpeg))
        let (_, response) = try await media.upload(for: r, from: body)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 { throw fail("error.uploadFailed", code) }
    }

    public func deleteAvatar(token: String) async throws {
        if try await call(request("/account/avatar", token: token, method: "DELETE")).0 != 200 { throw fail("error.uploadFailed") }
    }

    /// nil — аватара нет. Пустое тело 200 — сбой хранилища, а не новое фото.
    private func avatarBytes(_ token: String, _ path: String) async throws -> Data? {
        let (code, body) = try await callShort(request(path, token: token))
        switch code {
        case 200:
            guard !body.isEmpty else { throw fail("error.avatarLoadFailed", 200) }
            return body
        case 404: return nil
        default: throw fail("error.avatarLoadFailed", code)
        }
    }

    public func getAvatar(token: String, accountId: String) async throws -> Data? { try await avatarBytes(token, "/account/avatar/\(accountId)") }
    public func getMyAvatar(token: String) async throws -> Data? { try await avatarBytes(token, "/account/avatar") }

    // MARK: - чаты, контакты, обои, жалобы

    private func postPeer(_ token: String, _ path: String, _ peerAccountId: String, _ errorKey: String) async throws {
        if try await call(withJSON(request(path, token: token, method: "POST"), ["peer_account_id": .string(peerAccountId)])).0 != 200 { throw fail(errorKey) }
    }

    public func muteChat(token: String, peerAccountId: String) async throws { try await postPeer(token, "/chats/mute", peerAccountId, "error.muteFailed") }
    public func unmuteChat(token: String, peerAccountId: String) async throws { try await postPeer(token, "/chats/unmute", peerAccountId, "error.muteFailed") }
    public func blockContact(token: String, peerAccountId: String) async throws { try await postPeer(token, "/contacts/block", peerAccountId, "error.blockFailed") }
    public func unblockContact(token: String, peerAccountId: String) async throws { try await postPeer(token, "/contacts/unblock", peerAccountId, "error.blockFailed") }

    public func getMutedChats(token: String) async -> [String] {
        guard case let (code, body)? = try? await callShort(request("/chats/muted", token: token)), code == 200 else { return [] }
        return ((try? object(body))?["peer_account_ids"]?.array ?? []).compactMap(\.string)
    }

    public func getBlockedContacts(token: String) async -> BlockedContacts? {
        guard case let (code, body)? = try? await callShort(request("/contacts/blocked", token: token)), code == 200, let o = try? object(body) else { return nil }
        return BlockedContacts(blockedByMe: (o["blocked_by_me"]?.array ?? []).compactMap(\.string), blockingMe: (o["blocking_me"]?.array ?? []).compactMap(\.string))
    }

    /// Обои чатов: account_id собеседника → версия; nil — ошибка сети.
    public func getChatWallpapers(token: String) async -> [String: Int64]? {
        guard case let (code, body)? = try? await callShort(request("/chats/wallpapers", token: token)), code == 200, let o = try? object(body) else { return nil }
        var m: [String: Int64] = [:]
        for w in o["wallpapers"]?.array ?? [] { if let id = w["peer_account_id"]?.string { m[id] = w["version"]?.int ?? 0 } }
        return m
    }

    /// JPEG обоев чата; nil — обоев нет.
    public func getChatWallpaper(token: String, peerAccountId: String) async throws -> Data? {
        let (code, body) = try await call(request("/chats/wallpapers/\(peerAccountId)", token: token), session: media)
        switch code {
        case 200:
            guard !body.isEmpty else { throw fail("error.wallpaperFailed", 200) }
            return body
        case 404: return nil
        default: throw fail("error.wallpaperFailed", code)
        }
    }

    public func setChatWallpaper(token: String, peerAccountId: String, jpeg: Data, forPeer: Bool) async throws -> Int64 {
        let (r, body) = multipart(request("/chats/wallpapers/\(peerAccountId)", token: token, method: "PUT"),
                                  fields: ["for_peer": forPeer ? "1" : "0"], file: ("file", "wallpaper.jpg", "image/jpeg", jpeg))
        let (data, response) = try await media.upload(for: r, from: body)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw fail("error.wallpaperFailed", code) }
        return (try? object(data))?["version"]?.int ?? 0
    }

    public func deleteChatWallpaper(token: String, peerAccountId: String) async throws {
        if try await call(request("/chats/wallpapers/\(peerAccountId)", token: token, method: "DELETE")).0 != 200 { throw fail("error.wallpaperFailed") }
    }

    public func reportMessage(token: String, reportedDeviceId: String, messageText: String, reason: String) async throws {
        let (code, _) = try await callShort(withJSON(request("/reports", token: token, method: "POST"), [
            "reported_device_id": .string(reportedDeviceId), "message_text": .string(messageText), "reason": .string(reason),
        ]))
        if code != 200 { throw fail("error.reportFailed", code) }
    }

    /// Автоотчёт в feedback: auto_crash (ошибки и падения) или call_problem (звонок сработал плохо).
    public func reportCrashLog(token: String, logText: String, kind: String = "auto_crash") async throws {
        let (code, _) = try await call(withJSON(request("/feedback", token: token, method: "POST"), ["message": .string(logText), "kind": .string(kind)]), timeout: 15)
        if code != 200 { throw ApiError("crash report failed", code) }
    }

    // MARK: - медиа: загрузка

    private func multipart(_ r: URLRequest, fields: [String: String], file: (name: String, fileName: String, mime: String, data: Data)) -> (URLRequest, Data) {
        let boundary = "oshinobu-\(UUID().uuidString)"
        var r = r
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        for (k, v) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.fileName)\"\r\nContent-Type: \(file.mime)\r\n\r\n".utf8))
        body.append(file.data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return (r, body)
    }

    /// Нечанковый файл (уже зашифрованный) одним multipart-запросом. Имя на сервере —
    /// всегда "encrypted.bin": настоящее едет только внутри конверта. Возвращает media_id.
    public func uploadEncryptedMediaFile(token: String, file: URL, recipientAccountId: String, onProgress: ((Double) -> Void)? = nil) async throws -> String {
        try await transfer("error.uploadFailed") {
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            let (r, body) = multipart(request("/upload-media", token: token, method: "POST"), fields: ["recipient_account_id": recipientAccountId],
                                      file: ("file", "encrypted.bin", "application/octet-stream", data))
            let (respData, response) = try await media.upload(for: r, from: body, delegate: onProgress.map(UploadProgress.init))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(decoding: respData, as: UTF8.self)
            guard code == 200, !text.isEmpty else { throw fail("error.uploadFailed", code) }
            return text
        }
    }

    public func initChunkedUpload(token: String, sizeBytes: Int64) async throws -> ChunkedUploadInit {
        let (code, body) = try await call(withJSON(request("/upload-media/init", token: token, method: "POST"), ["size_bytes": .int(sizeBytes)]))
        guard code == 200, let o = try? object(body), let m = o["media_id"]?.string, let u = o["upload_id"]?.string, let p = o["part_size"]?.int else {
            throw fail("error.uploadFailed", code)
        }
        return ChunkedUploadInit(mediaId: m, uploadId: u, partSize: Int(p))
    }

    public func uploadChunkedPart(token: String, mediaId: String, uploadId: String, partNumber: Int, data: Data, onProgress: ((Double) -> Void)? = nil) async throws {
        try await transfer("error.uploadFailed") {
            var r = request("/upload-media/\(mediaId)/part/\(partNumber)", token: token, method: "PUT", query: ["upload_id": uploadId])
            r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await media.upload(for: r, from: data, delegate: onProgress.map(UploadProgress.init))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 { throw fail("error.uploadFailed", code) }
        }
    }

    /// Номера частей, которые сервер уже принял (истина для докачки).
    public func listChunkedParts(token: String, mediaId: String, uploadId: String) async throws -> Set<Int> {
        let (code, body) = try await call(request("/upload-media/\(mediaId)/parts", token: token, query: ["upload_id": uploadId]))
        guard code == 200 else { throw fail("error.uploadFailed", code) }
        return Set((try JSONValue.parse(body).array ?? []).compactMap { $0["part_number"]?.int.map(Int.init) })
    }

    /// Имя файла серверу намеренно не передаётся.
    public func completeChunkedUpload(token: String, mediaId: String, uploadId: String, recipientAccountId: String) async throws {
        let r = withJSON(request("/upload-media/\(mediaId)/complete", token: token, method: "POST", query: ["upload_id": uploadId]),
                         ["recipient_account_id": .string(recipientAccountId)])
        let (code, _) = try await call(r)
        if code != 200 { throw fail("error.uploadFailed", code) }
    }

    public func abortChunkedUpload(token: String, mediaId: String, uploadId: String) async {
        _ = try? await call(request("/upload-media/\(mediaId)/abort", token: token, method: "POST", query: ["upload_id": uploadId]))
    }

    // MARK: - медиа: скачивание

    /// Полный размер зашифрованного файла (HEAD); 0 при любой ошибке.
    public func probeEncryptedMediaSize(token: String, mediaId: String) async -> Int64 {
        guard case let (_, response)? = try? await media.data(for: request("/media/\(mediaId)", token: token, method: "HEAD")) else { return 0 }
        return Int64((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0
    }

    /// Скачивает зашифрованный файл в [dest] С ДОКАЧКОЙ (`Range: bytes=<есть>-`).
    /// [onProgress] — абсолютный процент. Возвращает полный размер.
    public func downloadEncryptedMediaResumable(token: String, mediaId: String, dest: URL, knownTotalBytes: Int64? = nil,
                                                onProgress: ((Double) -> Void)? = nil) async throws -> Int64 {
        try await transfer("error.downloadFailed") {
            let fm = FileManager.default
            var existing = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            var total = knownTotalBytes ?? 0
            if existing > 0, total <= 0 {
                total = await probeEncryptedMediaSize(token: token, mediaId: mediaId)
                if total > 0, existing == total { onProgress?(100); return total }
                if total > 0, total < existing { try? fm.removeItem(at: dest); existing = 0 }
            }
            var r = request("/media/\(mediaId)", token: token)
            if existing > 0 { r.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
            // поток сразу в файл (без побайтового чтения); прогресс — по записанным байтам
            let base = existing
            let knownTotal = total
            let (tmp, response) = try await media.download(for: r, delegate: DownloadProgress { written, expected in
                let t = knownTotal > 0 ? knownTotal : (expected > 0 ? base + expected : 0)
                if t > 0 { onProgress?(min(100, Double(base + written) * 100 / Double(t))) }
            })
            defer { try? fm.removeItem(at: tmp) }
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 416, existing > 0 {
                // хвост на диске не сходится с сервером — качаем заново
                try? fm.removeItem(at: dest)
                return try await downloadEncryptedMediaResumable(token: token, mediaId: mediaId, dest: dest, onProgress: onProgress)
            }
            guard code == 200 || code == 206 else { throw fail("error.downloadFailed", code) }
            if let range = http?.value(forHTTPHeaderField: "Content-Range"), let t = Int64(range.split(separator: "/").last ?? "") { total = t }
            if code == 206, existing > 0 {
                // докачка: хвост дописать в конец уже скачанного
                let out = try FileHandle(forWritingTo: dest)
                defer { try? out.close() }
                try out.seekToEnd()
                let ins = try FileHandle(forReadingFrom: tmp)
                defer { try? ins.close() }
                while let chunk = try ins.read(upToCount: 1 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
            } else {
                // 200 на запрос с Range — сервер отдал файл целиком: пишем с нуля
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: tmp, to: dest)
            }
            let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            if total <= 0 { total = size }
            onProgress?(100)
            return total
        }
    }

    /// Получатель скачал и расшифровал файл — сервер может убрать его в архив.
    public func confirmMediaReceived(token: String, mediaId: String) async {
        _ = try? await call(request("/media/\(mediaId)/received", token: token, method: "POST"))
    }

    // MARK: - стикеры

    private func parseStickerPack(_ o: [String: JSONValue]) -> StickerPackInfo? {
        guard let id = o["id"]?.string else { return nil }
        return StickerPackInfo(
            id: id, title: o["title"]?.string ?? "", isOwner: o["is_owner"]?.bool ?? false, installed: o["installed"]?.bool ?? false,
            deleted: o["deleted"]?.bool ?? false,
            stickers: (o["stickers"]?.array ?? []).compactMap { s in
                guard let sid = s["id"]?.string, let f = s["format"]?.string else { return nil }
                return StickerInfo(id: sid, format: f, packId: id)
            }
        )
    }

    /// Установленные паки аккаунта, новые первыми.
    public func getMyStickerPacks(token: String) async throws -> [StickerPackInfo] {
        let (code, body) = try await call(request("/stickers/packs/mine", token: token))
        guard code == 200 else { throw fail("error.stickersFailed", code) }
        return (try object(body)["packs"]?.array ?? []).compactMap { $0.object.flatMap(parseStickerPack) }
    }

    public func getStickerPack(token: String, packId: String) async throws -> StickerPackInfo? {
        let (code, body) = try await call(request("/stickers/packs/\(packId)", token: token))
        if code == 404 { return nil }
        guard code == 200 else { throw fail("error.stickersFailed", code) }
        return parseStickerPack(try object(body))
    }

    public func getStickerPackBySticker(token: String, stickerId: String) async throws -> StickerPackInfo? {
        let (code, body) = try await call(request("/stickers/items/\(stickerId)/pack", token: token))
        if code == 404 { return nil }
        guard code == 200 else { throw fail("error.stickersFailed", code) }
        return parseStickerPack(try object(body))
    }

    /// Весь пак одним ZIP (сервер не видит, какой стикер пришёл в переписке).
    public func downloadStickerPack(token: String, packId: String, dest: URL) async throws -> Bool {
        try await transfer("error.downloadFailed") {
            let (tmp, response) = try await media.download(for: request("/stickers/packs/\(packId)/files", token: token))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return false }
            guard code == 200 else { throw fail("error.downloadFailed", code) }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return true
        }
    }

    /// Шаг загрузки пака, о котором сообщил сервер (received, unpacking, counting, checking,
    /// converting, saving, registering).
    public struct StickerUploadEvent: Sendable {
        public let stage: String
        public let count: Int?
        public let index: Int?
        public let total: Int?
        public let name: String?
    }

    /// Сервер отверг пак: [code] — ключ причины (title.invalid, pack.quota, file.webm …).
    public struct StickerUploadError: Error {
        public let code: String
        public let fileName: String?
        public let limit: Int?
    }

    /// Загрузить свой пак (ZIP); ответ — NDJSON по шагам, последний — done с паком или error.
    public func uploadStickerPack(token: String, title: String, archive: URL, onEvent: @escaping (StickerUploadEvent) -> Void) async throws -> StickerPackInfo {
        var r = request("/stickers/packs", token: token, method: "POST", query: ["title": title])
        r.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        r.httpBody = try Data(contentsOf: archive)
        r.timeoutInterval = 600
        let (bytes, response) = try await media.bytes(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            var body = Data()
            for try await b in bytes { body.append(b) }
            let o = try? object(body)
            guard let c = o?["code"]?.string else { throw fail("error.uploadFailed", code) }
            throw StickerUploadError(code: c, fileName: nil, limit: o?["limit"]?.int.map(Int.init))
        }
        for try await line in bytes.lines {
            guard !line.isEmpty, let o = try? JSONValue.parse(line).object else { continue }
            func int(_ k: String) -> Int? { o[k]?.int.map(Int.init) }
            switch o["stage"]?.string ?? "" {
            case "error":
                throw StickerUploadError(code: o["code"]?.string ?? "server.error", fileName: o["name"]?.string, limit: int("limit"))
            case "done":
                guard let pack = o["pack"]?.object.flatMap(parseStickerPack) else { throw StickerUploadError(code: "server.error", fileName: nil, limit: nil) }
                return pack
            case let stage:
                onEvent(StickerUploadEvent(stage: stage, count: int("count"), index: int("index"), total: int("total"), name: o["name"]?.string))
            }
        }
        // поток оборвался без "done" — пак не сохранён
        throw StickerUploadError(code: "server.error", fileName: nil, limit: nil)
    }

    public func installStickerPack(token: String, packId: String) async throws {
        if try await call(request("/stickers/packs/\(packId)/install", token: token, method: "POST")).0 != 200 { throw fail("error.stickersFailed") }
    }

    public func uninstallStickerPack(token: String, packId: String) async throws {
        if try await call(request("/stickers/packs/\(packId)/install", token: token, method: "DELETE")).0 != 200 { throw fail("error.stickersFailed") }
    }

    public func deleteStickerPack(token: String, packId: String) async throws {
        if try await call(request("/stickers/packs/\(packId)", token: token, method: "DELETE")).0 != 200 { throw fail("error.stickersFailed") }
    }
}

/// Прогресс скачивания — по реально записанным байтам.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Int64, Int64) -> Void

    init(_ onProgress: @escaping (Int64, Int64) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

/// Прогресс отправки тела запроса — по реально отправленным байтам.
private final class UploadProgress: NSObject, URLSessionTaskDelegate {
    let onProgress: (Double) -> Void

    init(_ onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { onProgress(Double(totalBytesSent) * 100 / Double(totalBytesExpectedToSend)) }
    }
}
