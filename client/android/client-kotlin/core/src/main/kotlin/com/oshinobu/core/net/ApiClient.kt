package com.oshinobu.core.net

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.Buffer
import okio.BufferedSink
import okio.ForwardingSink
import okio.buffer
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

// REST-клиент сервера. Вместо готового переведённого текста ошибки
// бросается [ApiException] с КЛЮЧОМ локализации ('error.loginTaken' и т.п.) —
// переводит его уже слой интерфейса (app: ui/Messages.kt).

/**
 * [appVersionCode] — versionCode приложения: уходит в каждом запросе
 * (заголовок X-App-Version), сервер обслуживает только одну версию.
 */
class ApiConfig(val baseUrl: String = "https://ee2e.oshino.space", val appVersionCode: Int? = null) {
    val wsBaseUrl: String
        get() = when {
            baseUrl.startsWith("https://") -> "wss://" + baseUrl.removePrefix("https://")
            else -> "ws://" + baseUrl.removePrefix("http://")
        }
}

class ApiException(val errorKey: String, val httpStatus: Int? = null, cause: Throwable? = null) :
    IOException(if (httpStatus != null) "$errorKey ($httpStatus)" else errorKey, cause) {
    val isCancelled: Boolean get() = errorKey == CANCELLED

    companion object {
        const val CANCELLED = "error.cancelledByUser"
    }
}

data class LoginResult(val token: String, val language: String)
data class ChunkedUploadInit(val mediaId: String, val uploadId: String, val partSize: Int)
data class BlockedContacts(val blockedByMe: List<String>, val blockingMe: List<String>)
data class DeviceOwner(val accountId: String, val login: String, val displayName: String)
data class AccountDevices(val accountId: String, val devices: List<JsonObject>)

data class MyAccountInfo(
    val accountId: String,
    val login: String,
    val displayName: String?,
    val language: String,
    val email: String?,
    val hasAvatar: Boolean,
    val status: String?,
    val birthday: String?,
    val findByLoginVisibility: Int,
    val avatarVisibility: Int,
    val birthdayVisibility: Int,
    val statusVisibility: Int,
)

data class AccountProfile(
    val accountId: String,
    val login: String,
    val displayName: String,
    val devices: List<JsonObject>,
    val status: String?,
    val birthday: String?,
    val hasAvatar: Boolean,
)

/** Стикер: id и формат файла — png, webp (статичные) или tgs (анимированный Lottie). */
data class StickerInfo(val id: String, val format: String, val packId: String) {
    val animated: Boolean get() = format == "tgs"
}

data class StickerPackInfo(
    val id: String,
    val title: String,
    val isOwner: Boolean,
    val installed: Boolean,
    /** Удалён автором: стикеров в ответе нет. */
    val deleted: Boolean,
    val stickers: List<StickerInfo>,
)

/**
 * Шаг загрузки пака, о котором сообщил сервер: received, unpacking,
 * counting, checking, saving, registering, done (с [pack]) или error (с
 * [code]). [name] — файл в архиве, [limit] — нарушенный предел.
 */
data class StickerUploadEvent(
    val stage: String,
    val bytes: Long? = null,
    val count: Int? = null,
    val index: Int? = null,
    val total: Int? = null,
    val name: String? = null,
    val code: String? = null,
    val limit: Int? = null,
    val pack: StickerPackInfo? = null,
)

/** Сервер отверг пак: [code] — ключ причины (title.invalid, pack.quota, file.webm …). */
class StickerUploadException(val code: String, val fileName: String? = null, val limit: Int? = null) : Exception(code)

/** Видимость полей профиля: 0 = никто, 1 = все, 2 = только контакты. */
data class PrivacySettings(val findByLogin: Int, val avatar: Int, val birthday: Int, val status: Int)

private val JSON_TYPE = "application/json".toMediaType()
private val OCTET = "application/octet-stream".toMediaType()

/** Ожидание OkHttp-вызова в корутине; отмена корутины отменяет и запрос. */
suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    cont.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onResponse(call: Call, response: Response) = cont.resume(response)
        override fun onFailure(call: Call, e: IOException) {
            if (!cont.isCancelled) cont.resumeWithException(e)
        }
    })
}

/** Тело запроса, сообщающее о прогрессе отправки (в процентах). */
private class ProgressBody(private val delegate: RequestBody, private val onProgress: (Double) -> Unit) : RequestBody() {
    override fun contentType() = delegate.contentType()
    override fun contentLength() = delegate.contentLength()
    override fun writeTo(sink: BufferedSink) {
        val total = contentLength()
        var sent = 0L
        val counting = object : ForwardingSink(sink) {
            override fun write(source: Buffer, byteCount: Long) {
                super.write(source, byteCount)
                sent += byteCount
                if (total > 0) onProgress(sent * 100.0 / total)
            }
        }.buffer()
        delegate.writeTo(counting)
        counting.flush()
    }
}

/**
 * Версии приложения по данным сервера: [versionCode] — последняя выпущенная,
 * [minVersionCode] — самая старая, которую сервер ещё обслуживает (0 — любая),
 * [apkUrl] — откуда взять APK последней версии тем, кто ставил не из Play.
 */
data class AppVersionInfo(val versionCode: Int, val minVersionCode: Int, val apkUrl: String?)

class ApiClient(
    val config: ApiConfig = ApiConfig(),
    /** Обычные API-запросы. */
    http: OkHttpClient = defaultHttpClient(),
    /** Передача файлов: большие таймауты. */
    media: OkHttpClient = defaultMediaClient(),
) {
    private val _latestVersion = MutableStateFlow<AppVersionInfo?>(null)

    /**
     * Последнее, что сервер сообщил о версиях ([getAppVersion] или ответ 426);
     * null — ещё не спрашивали или не было связи.
     */
    val latestVersion: StateFlow<AppVersionInfo?> = _latestVersion.asStateFlow()

    /** Заголовок версии в запрос; ответ 426 — эту версию сервер больше не обслуживает. */
    private val versionInterceptor = Interceptor { chain ->
        val request = config.appVersionCode?.let { chain.request().newBuilder().header(APP_VERSION_HEADER, it.toString()).build() }
            ?: chain.request()
        val response = chain.proceed(request)
        if (response.code == HTTP_UPGRADE_REQUIRED) {
            runCatching { parseAppVersion(response.peekBody(4096).string()) }.getOrNull()?.let { _latestVersion.value = it }
        }
        response
    }

    /** Тот же клиент, но с версией приложения в каждом запросе (для WebSocket). */
    fun versioned(client: OkHttpClient): OkHttpClient = client.newBuilder().addInterceptor(versionInterceptor).build()

    private val http: OkHttpClient = versioned(http)
    private val media: OkHttpClient = versioned(media)

    /**
     * Сменилась сеть (Wi-Fi ↔ мобильная): соединения старой сети мертвы, но
     * сами об этом не узнают до таймаута. Обрываем идущие запросы (загрузки
     * повторят шаг уже по новой сети) и выбрасываем пул, чтобы новые запросы
     * не сели на мёртвый сокет.
     */
    fun dropConnections() {
        for (client in listOf(http, media)) {
            client.dispatcher.cancelAll()
            client.connectionPool.evictAll()
        }
    }

    private fun parseAppVersion(body: String): AppVersionInfo? {
        val o = obj(body)
        val code = (o["version_code"] as? JsonPrimitive)?.intOrNull ?: return null
        // сервер раздаёт APK сам — адрес относительный (/app/apk), дополняем адресом сервера
        val apk = o.str("apk_url")?.takeIf { it.isNotBlank() }?.let { config.baseUrl.toHttpUrl().resolve(it)?.toString() }
        val min = (o["min_version_code"] as? JsonPrimitive)?.intOrNull ?: 0
        return AppVersionInfo(code, min, apk)
    }

    /**
     * Спросить у сервера версии приложения (результат — и в [latestVersion]);
     * null — нет связи или сервер о версиях не знает.
     */
    suspend fun getAppVersion(): AppVersionInfo? = try {
        val (code, body) = callShort(req("/app/version").get().build())
        if (code == 200) parseAppVersion(body)?.takeIf { it.versionCode > 0 }?.also { _latestVersion.value = it } else null
    } catch (_: Exception) {
        null
    }

    companion object {
        fun defaultHttpClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .build()

        // запись: минута без единого отправленного байта — соединение мёртвое (сменилась
        // сеть), а не медленное; ответ после загрузки сервер может готовить долго
        fun defaultMediaClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(5, TimeUnit.MINUTES)
            .writeTimeout(1, TimeUnit.MINUTES)
            .build()

        const val APP_VERSION_HEADER = "X-App-Version"
        const val HTTP_UPGRADE_REQUIRED = 426

        /** Короткие "фоновые" запросы — не дольше 8 с. */
        private const val SHORT_TIMEOUT_MS = 8_000L
    }

    private fun url(path: String) = config.baseUrl + path

    private fun req(path: String, token: String? = null) = Request.Builder().url(url(path)).apply {
        if (token != null) header("Authorization", "Bearer $token")
    }

    private fun json(vararg fields: Pair<String, Any?>): RequestBody = JsonObject(
        fields.associate { (k, v) ->
            k to when (v) {
                null -> JsonNull
                is JsonElement -> v
                is String -> JsonPrimitive(v)
                is Number -> JsonPrimitive(v)
                is Boolean -> JsonPrimitive(v)
                is List<*> -> JsonArray(v.map { JsonPrimitive(it as String) })
                else -> error("не JSON-значение: $v")
            }
        },
    ).toString().toRequestBody(JSON_TYPE)

    private suspend fun exec(client: OkHttpClient, request: Request): Response = client.newCall(request).await()

    private suspend fun call(request: Request): Pair<Int, String> =
        exec(http, request).use { it.code to (it.body?.string() ?: "") }

    private suspend fun callShort(request: Request): Pair<Int, String> =
        withTimeout(SHORT_TIMEOUT_MS) { call(request) }

    private fun obj(body: String): JsonObject = Json.parseToJsonElement(body).jsonObject

    private fun JsonObject.str(name: String): String? = (this[name] as? JsonPrimitive)?.contentOrNull

    private fun JsonObject.int(name: String, default: Int): Int = (this[name] as? JsonPrimitive)?.intOrNull ?: default

    private fun JsonObject.bool(name: String): Boolean = (this[name] as? JsonPrimitive)?.booleanOrNull ?: false

    private fun JsonObject.objects(name: String): List<JsonObject> =
        (this[name] as? JsonArray)?.map { it.jsonObject }.orEmpty()

    private fun JsonObject.strings(name: String): List<String> =
        (this[name] as? JsonArray)?.map { it.jsonPrimitive.content }.orEmpty()

    private fun fail(key: String, code: Int? = null): Nothing = throw ApiException(key, code)

    // ---------------- регистрация, вход, восстановление ----------------

    /** Возвращает otpauth://-ссылку для настройки TOTP. */
    suspend fun register(login: String, password: String, inviteCode: String): String {
        val (code, body) = call(req("/register").post(json("login" to login, "password" to password, "invite_code" to inviteCode)).build())
        when (code) {
            200 -> return obj(body).str("totp_url")!!
            409 -> fail("error.loginTaken")
            403 -> fail("error.loginReserved")
            422 -> fail("error.inviteCodeInvalid")
            else -> fail("error.registerFailed", code)
        }
    }

    suspend fun verifyTotp(login: String, code: String) {
        val (status, _) = call(req("/verify-totp").post(json("login" to login, "code" to code)).build())
        if (status != 200) fail("error.wrongTotpCode")
    }

    suspend fun login(login: String, password: String, totpCode: String): LoginResult {
        val (code, body) = call(req("/login").post(json("login" to login, "password" to password, "totp_code" to totpCode)).build())
        if (code == 429) fail("error.tooManyLoginAttempts")
        if (code != 200) fail("error.wrongCredentials")
        val o = obj(body)
        return LoginResult(o.str("token")!!, o.str("language") ?: "en")
    }

    suspend fun requestPasswordRecovery(login: String) {
        val (code, _) = call(req("/account/recover/request").post(json("login" to login)).build())
        when (code) {
            200 -> Unit
            404 -> fail("error.recoveryUserNotFound")
            422 -> fail("error.recoveryNoEmailOnFile")
            else -> fail("error.recoveryRequestFailed")
        }
    }

    suspend fun verifyRecoveryCode(login: String, token: String) {
        val (code, _) = call(req("/account/recover/verify").post(json("login" to login, "token" to token)).build())
        if (code != 200) fail("error.recoveryWrongCode")
    }

    suspend fun resetPasswordWithRecoveryCode(login: String, token: String, newPassword: String) {
        val (code, _) = call(req("/account/recover/reset").post(json("login" to login, "token" to token, "new_password" to newPassword)).build())
        if (code != 200) fail("error.recoveryWrongCode")
    }

    /** Возвращает новую otpauth://-ссылку. */
    suspend fun resetTotpWithRecoveryCode(login: String, token: String): String {
        val (code, body) = call(req("/account/recover/reset-totp").post(json("login" to login, "token" to token)).build())
        if (code != 200) fail("error.recoveryWrongCode")
        return obj(body).str("totp_url")!!
    }

    /** true — сессия жива, false — сервер её отверг (вход с другого устройства), null — сеть. */
    /**
     * true — сессия жива, false — сервер её больше не признаёт (401: вошли на
     * другом устройстве), null — неизвестно. Только 401 — повод выйти: 426
     * (версия приложения устарела), 5xx на время перезапуска сервера и т. п.
     * сессию не отменяют — выход по ним стирал бы ключи и всю переписку.
     */
    suspend fun checkSession(token: String): Boolean? = try {
        when (callShort(req("/session/check", token).get().build()).first) {
            200 -> true
            401 -> false
            else -> null
        }
    } catch (_: Exception) {
        null
    }

    // ---------------- устройство и ключи ----------------

    suspend fun registerDevice(token: String, identityPubkeyB64: String, identityDhPubkeyB64: String, identityDhSignatureB64: String): String {
        val (code, body) = call(
            req("/register-device", token).post(
                json("identity_pubkey" to identityPubkeyB64, "identity_dh_pubkey" to identityDhPubkeyB64, "identity_dh_signature" to identityDhSignatureB64),
            ).build(),
        )
        if (code != 200) fail("error.deviceRegisterFailed")
        return obj(body).str("device_id")!!
    }

    suspend fun uploadPrekeys(token: String, deviceId: String, signedPrekeyB64: String, signedPrekeySignatureB64: String, oneTimePrekeysB64: List<String>) {
        val (code, _) = call(
            req("/prekeys/upload", token).post(
                json(
                    "device_id" to deviceId, "signed_prekey" to signedPrekeyB64,
                    "signed_prekey_signature" to signedPrekeySignatureB64, "one_time_prekeys" to oneTimePrekeysB64,
                ),
            ).build(),
        )
        if (code != 200) fail("error.prekeysFailed")
    }

    suspend fun getPrekeyBundle(token: String, deviceId: String): JsonObject {
        val (code, body) = call(req("/devices/$deviceId/prekey-bundle", token).get().build())
        if (code == 409) fail("error.peerOutOfKeys")
        if (code != 200) fail("error.peerKeysFailed")
        return obj(body)
    }

    /** Сколько одноразовых prekey осталось на сервере; null — не удалось узнать. */
    suspend fun getPrekeyCount(token: String, deviceId: String): Int? = try {
        val (code, body) = call(req("/devices/$deviceId/prekey-count", token).get().build())
        if (code == 200) obj(body)["remaining"]!!.jsonPrimitive.int else null
    } catch (_: Exception) {
        null
    }

    suspend fun getDevicesByLogin(token: String, login: String): AccountDevices {
        val (code, body) = call(req("/accounts/$login/devices", token).get().build())
        if (code == 404) fail("error.userNotFound")
        if (code != 200) fail("error.userLookupFailed")
        val o = obj(body)
        val accountId = o.str("account_id") ?: o.str("accountId") ?: o.str("id") ?: fail("error.noAccountId")
        return AccountDevices(accountId, o.objects("devices"))
    }

    suspend fun getDeviceOwnerInfo(token: String, deviceId: String): DeviceOwner? = try {
        val (code, body) = callShort(req("/devices/$deviceId/owner", token).get().build())
        if (code != 200) {
            null
        } else {
            val o = obj(body)
            val login = o.str("login")!!
            DeviceOwner(o.str("account_id")!!, login, o.str("display_name") ?: login)
        }
    } catch (_: Exception) {
        null
    }

    /**
     * Отклонить звонок, который сервер держит до подключения этого устройства
     * (кнопка в уведомлении, когда приложение не на связи). [busy] — "занято".
     */
    suspend fun declineCall(token: String, deviceId: String, callId: String, busy: Boolean = false): Boolean = try {
        val body = if (busy) json("device_id" to deviceId, "call_id" to callId, "reason" to "busy") else json("device_id" to deviceId, "call_id" to callId)
        callShort(req("/calls/decline", token).post(body).build()).first == 200
    } catch (_: Exception) {
        false
    }

    suspend fun getTurnCredentials(token: String): JsonObject? = try {
        val (code, body) = callShort(req("/turn-credentials", token).get().build())
        if (code == 200) obj(body) else null
    } catch (_: Exception) {
        null
    }

    suspend fun registerPushToken(token: String, deviceId: String, fcmToken: String): Boolean = try {
        callShort(req("/push/register", token).post(json("device_id" to deviceId, "fcm_token" to fcmToken)).build()).first == 200
    } catch (_: Exception) {
        false
    }

    suspend fun unregisterPushToken(token: String, deviceId: String): Boolean = try {
        callShort(req("/push/register", token).delete(json("device_id" to deviceId)).build()).first == 200
    } catch (_: Exception) {
        false
    }

    // ---------------- аккаунт и профиль ----------------

    suspend fun deleteAccount(token: String): Boolean =
        callShort(req("/account", token).delete().build()).first == 200

    suspend fun getMyAccountInfo(token: String): MyAccountInfo? = try {
        val (code, body) = callShort(req("/account/me", token).get().build())
        if (code != 200) {
            null
        } else {
            val o = obj(body)
            MyAccountInfo(
                accountId = o.str("account_id")!!,
                login = o.str("login")!!,
                displayName = o.str("display_name"),
                language = o.str("language") ?: "en",
                email = o.str("email"),
                hasAvatar = o.bool("has_avatar"),
                status = o.str("status"),
                birthday = o.str("birthday"),
                findByLoginVisibility = o.int("find_by_login_visibility", 1),
                avatarVisibility = o.int("avatar_visibility", 1),
                birthdayVisibility = o.int("birthday_visibility", 1),
                statusVisibility = o.int("status_visibility", 1),
            )
        }
    } catch (_: Exception) {
        null
    }

    /** null — такого логина нет (или он скрыт настройкой приватности). */
    suspend fun getAccountProfile(token: String, login: String): AccountProfile? {
        val (code, body) = call(req("/account/profile/$login", token).get().build())
        if (code == 404) return null
        if (code != 200) fail("error.userLookupFailed")
        val o = obj(body)
        val resolved = o.str("login")!!
        return AccountProfile(
            accountId = o.str("account_id")!!,
            login = resolved,
            displayName = o.str("display_name") ?: resolved,
            devices = o.objects("devices"),
            status = o.str("status"),
            birthday = o.str("birthday"),
            hasAvatar = o.bool("has_avatar"),
        )
    }

    private suspend fun put(token: String, path: String, body: RequestBody, errorKey: String) {
        if (call(req(path, token).put(body).build()).first != 200) fail(errorKey)
    }

    suspend fun updateLanguage(token: String, language: String) =
        put(token, "/account/language", json("language" to language), "error.languageSaveFailed")

    suspend fun changePassword(token: String, newPassword: String) =
        put(token, "/account/password", json("new_password" to newPassword), "error.changePasswordFailed")

    suspend fun updateEmail(token: String, email: String) =
        put(token, "/account/email", json("email" to email), "error.emailSaveFailed")

    suspend fun updateDisplayName(token: String, displayName: String) =
        put(token, "/account/display-name", json("display_name" to displayName), "error.displayNameSaveFailed")

    suspend fun updateStatus(token: String, status: String) =
        put(token, "/account/status", json("status" to status), "error.statusSaveFailed")

    /** [birthday] — "YYYY-MM-DD" или null (убрать). */
    suspend fun updateBirthday(token: String, birthday: String?) =
        put(token, "/account/birthday", json("birthday" to birthday), "error.birthdaySaveFailed")

    suspend fun updatePrivacy(token: String, p: PrivacySettings) = put(
        token, "/account/privacy",
        json("find_by_login" to p.findByLogin, "avatar" to p.avatar, "birthday" to p.birthday, "status" to p.status),
        "error.privacySaveFailed",
    )

    suspend fun requestEmailVerification(token: String, email: String) {
        val (code, _) = call(req("/account/email/request", token).post(json("email" to email)).build())
        if (code == 409) fail("error.emailTaken")
        if (code != 200) fail("error.emailVerifyRequestFailed")
    }

    suspend fun confirmEmailVerification(token: String, code: String) {
        val (status, _) = call(req("/account/email/confirm", token).post(json("code" to code)).build())
        if (status == 409) fail("error.emailTaken")
        if (status != 200) fail("error.recoveryWrongCode")
    }

    suspend fun uploadAvatar(token: String, jpegBytes: ByteArray) {
        val body = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("file", "avatar.jpg", jpegBytes.toRequestBody("image/jpeg".toMediaType()))
            .build()
        val code = exec(media, req("/account/avatar", token).post(body).build()).use { it.code }
        if (code != 200) fail("error.uploadFailed", code)
    }

    suspend fun deleteAvatar(token: String) {
        if (call(req("/account/avatar", token).delete().build()).first != 200) fail("error.uploadFailed")
    }

    private suspend fun avatarBytes(token: String, path: String): ByteArray? = withTimeout(SHORT_TIMEOUT_MS) {
        exec(http, req(path, token).get().build()).use {
            when (it.code) {
                // пустое "фото" — сбой хранилища, а не новое фото: сохранённую копию не затираем
                200 -> it.body!!.bytes().takeIf { bytes -> bytes.isNotEmpty() } ?: throw ApiException("error.avatarLoadFailed", 200)
                404 -> null
                else -> throw ApiException("error.avatarLoadFailed", it.code)
            }
        }
    }

    /** null — аватара нет. */
    suspend fun getAvatar(token: String, accountId: String): ByteArray? = avatarBytes(token, "/account/avatar/$accountId")

    suspend fun getMyAvatar(token: String): ByteArray? = avatarBytes(token, "/account/avatar")

    // ---------------- чаты, контакты, жалобы ----------------

    private suspend fun postPeer(token: String, path: String, peerAccountId: String, errorKey: String) {
        if (call(req(path, token).post(json("peer_account_id" to peerAccountId)).build()).first != 200) fail(errorKey)
    }

    suspend fun muteChat(token: String, peerAccountId: String) = postPeer(token, "/chats/mute", peerAccountId, "error.muteFailed")

    suspend fun unmuteChat(token: String, peerAccountId: String) = postPeer(token, "/chats/unmute", peerAccountId, "error.muteFailed")

    /** account_id замьюченных собеседников; пусто и при ошибке сети. */
    suspend fun getMutedChats(token: String): List<String> = try {
        val (code, body) = callShort(req("/chats/muted", token).get().build())
        if (code == 200) obj(body).strings("peer_account_ids") else emptyList()
    } catch (_: Exception) {
        emptyList()
    }

    // ---------------- обои чатов ----------------

    /** Обои чатов: account_id собеседника → версия (время смены, мс); null — ошибка сети. */
    suspend fun getChatWallpapers(token: String): Map<String, Long>? = try {
        val (code, body) = callShort(req("/chats/wallpapers", token).get().build())
        if (code == 200) {
            obj(body).objects("wallpapers").mapNotNull { w ->
                val id = w.str("peer_account_id") ?: return@mapNotNull null
                id to ((w["version"] as? JsonPrimitive)?.longOrNull ?: 0L)
            }.toMap()
        } else {
            null
        }
    } catch (_: Exception) {
        null
    }

    /** JPEG обоев чата; null — обоев нет. */
    suspend fun getChatWallpaper(token: String, peerAccountId: String): ByteArray? =
        exec(media, req("/chats/wallpapers/$peerAccountId", token).get().build()).use {
            when (it.code) {
                200 -> it.body!!.bytes().takeIf { bytes -> bytes.isNotEmpty() } ?: fail("error.wallpaperFailed", 200)
                404 -> null
                else -> fail("error.wallpaperFailed", it.code)
            }
        }

    /** Поставить обои чату ([forPeer] — и собеседнику); возвращает версию. */
    suspend fun setChatWallpaper(token: String, peerAccountId: String, jpegBytes: ByteArray, forPeer: Boolean): Long {
        val body = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("for_peer", if (forPeer) "1" else "0")
            .addFormDataPart("file", "wallpaper.jpg", jpegBytes.toRequestBody("image/jpeg".toMediaType()))
            .build()
        val (code, text) = exec(media, req("/chats/wallpapers/$peerAccountId", token).put(body).build()).use { it.code to (it.body?.string() ?: "") }
        if (code != 200) fail("error.wallpaperFailed", code)
        return (obj(text)["version"] as? JsonPrimitive)?.longOrNull ?: 0L
    }

    suspend fun deleteChatWallpaper(token: String, peerAccountId: String) {
        if (call(req("/chats/wallpapers/$peerAccountId", token).delete().build()).first != 200) fail("error.wallpaperFailed")
    }

    suspend fun blockContact(token: String, peerAccountId: String) = postPeer(token, "/contacts/block", peerAccountId, "error.blockFailed")

    suspend fun unblockContact(token: String, peerAccountId: String) = postPeer(token, "/contacts/unblock", peerAccountId, "error.blockFailed")

    suspend fun getBlockedContacts(token: String): BlockedContacts? = try {
        val (code, body) = callShort(req("/contacts/blocked", token).get().build())
        if (code == 200) obj(body).let { BlockedContacts(it.strings("blocked_by_me"), it.strings("blocking_me")) } else null
    } catch (_: Exception) {
        null
    }

    suspend fun reportMessage(token: String, reportedDeviceId: String, messageText: String, reason: String) {
        val code = callShort(
            req("/reports", token).post(json("reported_device_id" to reportedDeviceId, "message_text" to messageText, "reason" to reason)).build(),
        ).first
        if (code != 200) fail("error.reportFailed", code)
    }

    /** Автоотчёт в feedback: [kind] — auto_crash (ошибки и падения) или call_problem (звонок сработал плохо). */
    suspend fun reportCrashLog(token: String, logText: String, kind: String = "auto_crash") {
        val code = withTimeout(15_000) {
            call(req("/feedback", token).post(json("message" to logText, "kind" to kind)).build()).first
        }
        if (code != 200) throw ApiException("crash report failed", code)
    }

    // ---------------- медиа: загрузка ----------------

    private suspend fun <T> transfer(errorKey: String, block: suspend () -> T): T = try {
        block()
    } catch (e: ApiException) {
        throw e
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: IOException) {
        throw ApiException(errorKey, cause = e)
    }

    /**
     * Нечанковый файл (уже зашифрованный, на диске) одним multipart-запросом.
     * Имя файла на сервере — всегда "encrypted.bin": настоящее едет только
     * внутри зашифрованного конверта. Возвращает media_id.
     */
    suspend fun uploadEncryptedMediaFile(token: String, file: File, recipientAccountId: String, onProgress: ((Double) -> Unit)? = null): String =
        transfer("error.uploadFailed") {
            val multipart = MultipartBody.Builder().setType(MultipartBody.FORM)
                .addFormDataPart("recipient_account_id", recipientAccountId)
                .addFormDataPart("file", "encrypted.bin", file.asRequestBody(OCTET))
                .build()
            val body = if (onProgress != null) ProgressBody(multipart, onProgress) else multipart
            exec(media, req("/upload-media", token).post(body).build()).use {
                val text = it.body?.string()
                if (it.code != 200 || text.isNullOrEmpty()) fail("error.uploadFailed", it.code)
                text
            }
        }

    suspend fun initChunkedUpload(token: String, sizeBytes: Long): ChunkedUploadInit {
        val (code, body) = call(req("/upload-media/init", token).post(json("size_bytes" to sizeBytes)).build())
        if (code != 200) fail("error.uploadFailed", code)
        val o = obj(body)
        return ChunkedUploadInit(o.str("media_id")!!, o.str("upload_id")!!, o["part_size"]!!.jsonPrimitive.int)
    }

    suspend fun uploadChunkedPart(token: String, mediaId: String, uploadId: String, partNumber: Int, data: ByteArray, onProgress: ((Double) -> Unit)? = null) =
        transfer("error.uploadFailed") {
            val u = url("/upload-media/$mediaId/part/$partNumber").toHttpUrl().newBuilder().addQueryParameter("upload_id", uploadId).build()
            val raw = data.toRequestBody(OCTET)
            val body = if (onProgress != null) ProgressBody(raw, onProgress) else raw
            val code = exec(media, Request.Builder().url(u).header("Authorization", "Bearer $token").put(body).build()).use { it.code }
            if (code != 200) fail("error.uploadFailed", code)
        }

    /** Номера частей, которые сервер уже принял (истина для докачки). */
    suspend fun listChunkedParts(token: String, mediaId: String, uploadId: String): Set<Int> {
        val u = url("/upload-media/$mediaId/parts").toHttpUrl().newBuilder().addQueryParameter("upload_id", uploadId).build()
        val (code, body) = call(Request.Builder().url(u).header("Authorization", "Bearer $token").get().build())
        if (code != 200) fail("error.uploadFailed", code)
        return Json.parseToJsonElement(body).jsonArray.map { it.jsonObject["part_number"]!!.jsonPrimitive.int }.toSet()
    }

    /** Имя файла серверу намеренно не передаётся. */
    suspend fun completeChunkedUpload(token: String, mediaId: String, uploadId: String, recipientAccountId: String) {
        val u = url("/upload-media/$mediaId/complete").toHttpUrl().newBuilder().addQueryParameter("upload_id", uploadId).build()
        val (code, _) = call(Request.Builder().url(u).header("Authorization", "Bearer $token").post(json("recipient_account_id" to recipientAccountId)).build())
        if (code != 200) fail("error.uploadFailed", code)
    }

    suspend fun abortChunkedUpload(token: String, mediaId: String, uploadId: String) {
        try {
            val u = url("/upload-media/$mediaId/abort").toHttpUrl().newBuilder().addQueryParameter("upload_id", uploadId).build()
            call(Request.Builder().url(u).header("Authorization", "Bearer $token").post(ByteArray(0).toRequestBody()).build())
        } catch (_: Exception) {
            // пользователь и так уже отказался от файла
        }
    }

    // ---------------- медиа: скачивание ----------------

    /** Полный размер зашифрованного файла (HEAD); 0 при любой ошибке. */
    suspend fun probeEncryptedMediaSize(token: String, mediaId: String): Long = try {
        exec(media, req("/media/$mediaId", token).head().build()).use { it.header("Content-Length")?.toLongOrNull() ?: 0L }
    } catch (_: Exception) {
        0L
    }

    /**
     * Скачивает зашифрованный файл в [dest] С ДОКАЧКОЙ: если в [dest] уже
     * есть начало, дотягивает только хвост (`Range: bytes=<есть>-`).
     * [onProgress] — абсолютный процент по всему файлу. Возвращает полный
     * размер зашифрованного файла.
     */
    suspend fun downloadEncryptedMediaResumable(
        token: String,
        mediaId: String,
        dest: File,
        knownTotalBytes: Long? = null,
        onProgress: ((Double) -> Unit)? = null,
    ): Long = transfer("error.downloadFailed") {
        var existing = if (dest.exists()) dest.length() else 0L
        var total = knownTotalBytes ?: 0L
        if (existing > 0 && total <= 0) {
            total = probeEncryptedMediaSize(token, mediaId)
            if (total > 0 && existing == total) {
                onProgress?.invoke(100.0)
                return@transfer total
            }
            if (total in 1 until existing) {
                dest.delete()
                existing = 0
            }
        }

        val request = req("/media/$mediaId", token).get().apply {
            if (existing > 0) header("Range", "bytes=$existing-")
        }.build()
        val response = exec(media, request)
        response.use {
            if (it.code == 416 && existing > 0) {
                // хвост на диске не сходится с сервером — качаем заново
                dest.delete()
                return@transfer downloadEncryptedMediaResumable(token, mediaId, dest, null, onProgress)
            }
            if (it.code != 200 && it.code != 206) fail("error.downloadFailed", it.code)
            // 200 на запрос с Range — сервер отдал файл целиком, пишем с нуля
            val append = it.code == 206 && existing > 0
            if (!append) existing = 0
            it.header("Content-Range")?.substringAfterLast('/')?.toLongOrNull()?.let { t -> total = t }
            val body = it.body!!
            if (total <= 0 && body.contentLength() > 0) total = existing + body.contentLength()
            FileOutputStream(dest, append).use { out ->
                val buf = ByteArray(64 * 1024)
                var received = 0L
                body.byteStream().use { ins ->
                    while (true) {
                        val n = ins.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        received += n
                        if (total > 0) onProgress?.invoke(((existing + received) * 100.0 / total).coerceIn(0.0, 100.0))
                    }
                }
            }
        }
        if (total <= 0) total = dest.length()
        total
    }

    /** Получатель скачал и расшифровал файл — сервер может убрать его в архив. Ошибки глотаются. */
    suspend fun confirmMediaReceived(token: String, mediaId: String) {
        try {
            call(req("/media/$mediaId/received", token).post(ByteArray(0).toRequestBody()).build())
        } catch (_: Exception) {
        }
    }

    // ---------------- стикеры ----------------

    private fun parseStickerPack(o: JsonObject): StickerPackInfo {
        val id = o.str("id")!!
        return StickerPackInfo(
            id = id,
            title = o.str("title").orEmpty(),
            isOwner = o.bool("is_owner"),
            installed = o.bool("installed"),
            deleted = o.bool("deleted"),
            stickers = o.objects("stickers").map { StickerInfo(it.str("id")!!, it.str("format")!!, id) },
        )
    }

    /** Установленные паки аккаунта, новые первыми. */
    suspend fun getMyStickerPacks(token: String): List<StickerPackInfo> {
        val (code, body) = callShort(req("/stickers/packs/mine", token).get().build())
        if (code != 200) fail("error.stickersFailed", code)
        return obj(body).objects("packs").map(::parseStickerPack)
    }

    /** null — пака нет. */
    suspend fun getStickerPack(token: String, packId: String): StickerPackInfo? {
        val (code, body) = callShort(req("/stickers/packs/$packId", token).get().build())
        return when (code) {
            200 -> parseStickerPack(obj(body))
            404 -> null
            else -> fail("error.stickersFailed", code)
        }
    }

    /** Пак, которому принадлежит стикер из переписки; null — такого стикера нет. */
    suspend fun getStickerPackBySticker(token: String, stickerId: String): StickerPackInfo? {
        val (code, body) = callShort(req("/stickers/items/$stickerId/pack", token).get().build())
        return when (code) {
            200 -> parseStickerPack(obj(body))
            404 -> null
            else -> fail("error.stickersFailed", code)
        }
    }

    /** Весь пак одним ZIP в [dest]; false — пак удалён автором (410). */
    suspend fun downloadStickerPack(token: String, packId: String, dest: File): Boolean = transfer("error.downloadFailed") {
        exec(media, req("/stickers/packs/$packId/files", token).get().build()).use {
            when (it.code) {
                200 -> {
                    dest.outputStream().use { out -> it.body!!.byteStream().copyTo(out) }
                    true
                }
                410 -> false
                else -> fail("error.downloadFailed", it.code)
            }
        }
    }

    suspend fun installStickerPack(token: String, packId: String) {
        if (callShort(req("/stickers/packs/$packId/install", token).post(ByteArray(0).toRequestBody()).build()).first != 200) fail("error.stickersFailed")
    }

    suspend fun uninstallStickerPack(token: String, packId: String) {
        if (callShort(req("/stickers/packs/$packId/install", token).delete().build()).first != 200) fail("error.stickersFailed")
    }

    /** Удалить пак навсегда — только автор. */
    suspend fun deleteStickerPack(token: String, packId: String) {
        if (callShort(req("/stickers/packs/$packId", token).delete().build()).first != 200) fail("error.stickersFailed")
    }

    /**
     * Загрузка пака (ZIP): [onProgress] — отправка архива в процентах,
     * дальше [onEvent] — шаги проверки на сервере. Возвращает готовый пак;
     * отказ сервера — [StickerUploadException]. Отмена корутины рвёт
     * соединение — сервер тогда ничего не сохраняет.
     */
    suspend fun uploadStickerPack(
        token: String,
        title: String,
        archive: File,
        onProgress: (Double) -> Unit,
        onEvent: (StickerUploadEvent) -> Unit,
    ): StickerPackInfo = transfer("error.uploadFailed") {
        val u = url("/stickers/packs").toHttpUrl().newBuilder().addQueryParameter("title", title).build()
        val body = ProgressBody(archive.asRequestBody("application/zip".toMediaType()), onProgress)
        val request = Request.Builder().url(u).header("Authorization", "Bearer $token").post(body).build()
        exec(media, request).use { response ->
            if (response.code != 200) {
                val o = runCatching { obj(response.body?.string().orEmpty()) }.getOrNull()
                val code = o?.str("code") ?: fail("error.uploadFailed", response.code)
                throw StickerUploadException(code, limit = o.int("limit", 0).takeIf { it > 0 })
            }
            val source = response.body!!.source()
            while (true) {
                val line = source.readUtf8Line() ?: break
                if (line.isBlank()) continue
                val o = obj(line)
                val event = StickerUploadEvent(
                    stage = o.str("stage").orEmpty(),
                    bytes = (o["bytes"] as? JsonPrimitive)?.contentOrNull?.toLongOrNull(),
                    count = o.int("count", -1).takeIf { it >= 0 },
                    index = o.int("index", -1).takeIf { it >= 0 },
                    total = o.int("total", -1).takeIf { it >= 0 },
                    name = o.str("name"),
                    code = o.str("code"),
                    limit = o.int("limit", 0).takeIf { it > 0 },
                    pack = (o["pack"] as? JsonObject)?.let(::parseStickerPack),
                )
                when (event.stage) {
                    "error" -> throw StickerUploadException(event.code ?: "server.error", event.name, event.limit)
                    "done" -> return@transfer event.pack ?: throw StickerUploadException("server.error")
                    else -> onEvent(event)
                }
            }
            // поток оборвался без "done" — пак не сохранён
            throw StickerUploadException("server.error")
        }
    }
}
