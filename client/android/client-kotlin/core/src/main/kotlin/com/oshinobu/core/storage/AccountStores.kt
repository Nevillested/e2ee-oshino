package com.oshinobu.core.storage

import com.oshinobu.core.crypto.Ed25519KeyPair
import com.oshinobu.core.crypto.RatchetState
import com.oshinobu.core.crypto.StoredIdentity
import com.oshinobu.core.crypto.X25519KeyPair
import com.oshinobu.core.crypto.b64
import com.oshinobu.core.crypto.randomBytes
import com.oshinobu.core.crypto.unb64
import com.oshinobu.core.optInt
import com.oshinobu.core.optString
import com.oshinobu.core.string
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import java.security.MessageDigest
import java.util.UUID

// Остальные хранилища Flutter-клиента — те же ключи, тот же формат значений
// (см. одноимённые классы в client/lib/storage и client/lib/services).

/** Токен и логин — shared_preferences (session.dart). */
class Session(private val prefs: Prefs) {
    var token: String?
        get() = prefs.getString("auth_token")
        set(v) = if (v == null) prefs.remove("auth_token") else prefs.setString("auth_token", v)

    var login: String?
        get() = prefs.getString("saved_login")
        set(v) = if (v == null) prefs.remove("saved_login") else prefs.setString("saved_login", v)

    var accountId: String?
        get() = prefs.getString("saved_account_id")
        set(v) = if (v == null) prefs.remove("saved_account_id") else prefs.setString("saved_account_id", v)
}

/** Identity-ключ устройства (подписи) и подписанный им X25519-ключ для DH. */
class DeviceIdentity(val identity: Ed25519KeyPair, val identityDh: X25519KeyPair, val identityDhSignature: ByteArray)

/** Долговременные ключи устройства (key_store.dart) — отдельными строками secure storage. */
class KeyStore(private val secure: SecureStore) {
    private val lock = Mutex()

    suspend fun deviceId(): String? = secure.read(StoredIdentity.DEVICE_ID)

    suspend fun saveDeviceId(id: String) = secure.write(StoredIdentity.DEVICE_ID, id)

    /** Ключи для X3DH и подписей; null — устройство ещё не настроено. */
    suspend fun loadIdentity(): StoredIdentity? {
        val names = listOf(
            StoredIdentity.DEVICE_ID, StoredIdentity.IDENTITY_PRIVATE, StoredIdentity.IDENTITY_PUBLIC,
            StoredIdentity.IDENTITY_DH_PRIVATE, StoredIdentity.IDENTITY_DH_PUBLIC, StoredIdentity.IDENTITY_DH_SIGNATURE,
            StoredIdentity.SIGNED_PREKEY_PRIVATE, StoredIdentity.SIGNED_PREKEY_PUBLIC, StoredIdentity.ONE_TIME_PREKEYS,
        )
        val store = names.mapNotNull { n -> secure.read(n)?.let { n to it } }.toMap()
        return StoredIdentity.fromStore(store)
    }

    /** Identity Ed25519 + подписанный X25519 identity_dh — создаются один раз за жизнь устройства. */
    suspend fun getOrCreateIdentity(): DeviceIdentity = lock.withLock {
        val idPriv = secure.read(StoredIdentity.IDENTITY_PRIVATE)
        val idPub = secure.read(StoredIdentity.IDENTITY_PUBLIC)
        val identity = if (idPriv != null && idPub != null) {
            Ed25519KeyPair(unb64(idPriv), unb64(idPub))
        } else {
            Ed25519KeyPair.generate().also {
                secure.write(StoredIdentity.IDENTITY_PRIVATE, b64(it.seed))
                secure.write(StoredIdentity.IDENTITY_PUBLIC, b64(it.publicKey))
            }
        }
        val dhPriv = secure.read(StoredIdentity.IDENTITY_DH_PRIVATE)
        val dhPub = secure.read(StoredIdentity.IDENTITY_DH_PUBLIC)
        val dhSig = secure.read(StoredIdentity.IDENTITY_DH_SIGNATURE)
        if (dhPriv != null && dhPub != null && dhSig != null) {
            DeviceIdentity(identity, X25519KeyPair(unb64(dhPriv), unb64(dhPub)), unb64(dhSig))
        } else {
            val dh = X25519KeyPair.generate()
            val sig = identity.sign(dh.publicKey)
            secure.write(StoredIdentity.IDENTITY_DH_PRIVATE, b64(dh.privateKey))
            secure.write(StoredIdentity.IDENTITY_DH_PUBLIC, b64(dh.publicKey))
            secure.write(StoredIdentity.IDENTITY_DH_SIGNATURE, b64(sig))
            DeviceIdentity(identity, dh, sig)
        }
    }

    /** Новый signed prekey (заменяет прежний). Возвращает публичную часть и подпись. */
    suspend fun createSignedPrekey(identity: Ed25519KeyPair): Pair<ByteArray, ByteArray> {
        val kp = X25519KeyPair.generate()
        secure.write(StoredIdentity.SIGNED_PREKEY_PRIVATE, b64(kp.privateKey))
        secure.write(StoredIdentity.SIGNED_PREKEY_PUBLIC, b64(kp.publicKey))
        return kp.publicKey to identity.sign(kp.publicKey)
    }

    private fun parseOneTime(raw: String?): MutableList<JsonObject> =
        raw?.let { Json.parseToJsonElement(it).jsonArray.map { e -> e.jsonObject }.toMutableList() } ?: mutableListOf()

    /** ДОПОЛНЯЕТ (не затирает) сохранённые одноразовые prekey; возвращает новые публичные части. */
    suspend fun createOneTimePrekeys(count: Int): List<ByteArray> = lock.withLock {
        val fresh = List(count) { X25519KeyPair.generate() }
        val list = parseOneTime(secure.read(StoredIdentity.ONE_TIME_PREKEYS))
        fresh.forEach {
            list += JsonObject(mapOf("public" to JsonPrimitive(b64(it.publicKey)), "private" to JsonPrimitive(b64(it.privateKey))))
        }
        secure.write(StoredIdentity.ONE_TIME_PREKEYS, JsonArray(list).toString())
        fresh.map { it.publicKey }
    }

    /** Одноразовый prekey использован — приватную часть удаляем сразу (forward secrecy). */
    suspend fun deleteOneTimePrekey(publicKeyB64: String) = lock.withLock {
        val list = parseOneTime(secure.read(StoredIdentity.ONE_TIME_PREKEYS))
        if (list.removeAll { it["public"]?.jsonPrimitive?.content == publicKeyB64 }) {
            secure.write(StoredIdentity.ONE_TIME_PREKEYS, JsonArray(list).toString())
        }
    }

    /** Как и во Flutter — стирает ВСЁ secure storage (выход из аккаунта). */
    suspend fun clearAll() = secure.deleteAll()
}

/** Состояние Double Ratchet по устройствам собеседников (`ratchet:<deviceId>`). */
class SessionStore(private val secure: SecureStore) {
    private fun key(deviceId: String) = "ratchet:$deviceId"

    suspend fun get(deviceId: String): RatchetState? =
        secure.read(key(deviceId))?.let { RatchetState.fromJson(Json.parseToJsonElement(it).jsonObject) }

    suspend fun save(deviceId: String, state: RatchetState) = secure.write(key(deviceId), state.toJson().toString())

    suspend fun clear(deviceId: String) {
        secure.delete(key(deviceId))
        clearPendingInit(deviceId)
    }

    private fun initKey(deviceId: String) = "x3dh_init:$deviceId"

    /**
     * X3DH-поля исходящей сессии, которые прикладываются к КАЖДОМУ сообщению,
     * пока собеседник не ответил (как в Signal): если первое сообщение
     * потерялось — например, сигнал звонка, который не стоит в очереди, —
     * собеседник поднимет сессию по любому следующему. Ключ новый, Flutter-
     * клиент его не читает (он прикладывает поля только к первому сообщению).
     */
    suspend fun pendingInit(deviceId: String): Map<String, JsonElement>? =
        secure.read(initKey(deviceId))?.let { Json.parseToJsonElement(it).jsonObject }

    suspend fun savePendingInit(deviceId: String, header: Map<String, JsonElement>) =
        secure.write(initKey(deviceId), JsonObject(header).toString())

    /** Собеседник ответил — сессия у него точно есть. */
    suspend fun clearPendingInit(deviceId: String) = secure.delete(initKey(deviceId))
}

/** device_id собеседника → его account_id. */
class PeerAccountStore(private val secure: SecureStore) {
    suspend fun get(deviceId: String) = secure.read("peer_account:$deviceId")
    suspend fun save(deviceId: String, accountId: String) = secure.write("peer_account:$deviceId", accountId)
}

/** Последний виденный identity DH-ключ устройства собеседника (диагностика подмены). */
class PeerIdentityStore(private val secure: SecureStore) {
    suspend fun get(deviceId: String) = secure.read("peer_identity:$deviceId")
    suspend fun save(deviceId: String, identityDhB64: String) = secure.write("peer_identity:$deviceId", identityDhB64)
}

/** JSON-список заданий под одним ключом secure storage, с сериализацией операций. */
open class JsonQueueStore(private val secure: SecureStore, private val key: String) {
    private val lock = Mutex()

    suspend fun getAll(): List<JsonObject> =
        secure.read(key)?.let { Json.parseToJsonElement(it).jsonArray.map { e -> e.jsonObject } }.orEmpty()

    private suspend fun writeAll(items: List<JsonObject>) = secure.write(key, JsonArray(items).toString())

    /** Добавляет задание; задание с тем же "id" заменяется. */
    suspend fun put(job: JsonObject) = lock.withLock {
        val id = job["id"]?.jsonPrimitive?.content
        writeAll(getAll().filter { it["id"]?.jsonPrimitive?.content != id } + job)
    }

    suspend fun remove(id: String) = lock.withLock {
        writeAll(getAll().filter { it["id"]?.jsonPrimitive?.content != id })
    }
}

/** Готовые конверты, ждущие ack сервера (send_queue_store.dart). */
class SendQueueStore(secure: SecureStore) : JsonQueueStore(secure, "send_queue") {
    suspend fun add(id: String, toDeviceId: String, envelope: JsonObject, silent: Boolean = false, messageId: String? = null, peerLogin: String? = null) =
        put(
            buildJsonObject {
                put("id", id)
                put("to_device_id", toDeviceId)
                put("envelope", envelope)
                put("silent", silent)
                if (messageId != null) put("message_id", messageId)
                if (peerLogin != null) put("peer_login", peerLogin)
            },
        )
}

/**
 * Отправки, упавшие ДО готового конверта (pending_send_store.dart): формат
 * задания — тот же JSON, что пишет PendingSendRetrier во Flutter.
 */
class PendingSendStore(secure: SecureStore, private val dirs: AppDirs) : JsonQueueStore(secure, "pending_send_queue") {
    /** Типизированные задания; неизвестные (из будущей версии) пропускаются. */
    suspend fun jobs(): List<PendingSendJob> = getAll().mapNotNull { PendingSendJob.fromJson(it) }

    suspend fun job(id: String): PendingSendJob? = jobs().firstOrNull { it.id == id }

    suspend fun put(job: PendingSendJob) = put(job.toJson())

    /** Копия исходного файла в постоянную папку — temp система может стереть. */
    fun persistFile(source: File, tag: String): File {
        val dir = File(dirs.support, "pending_uploads").apply { mkdirs() }
        val ext = source.name.substringAfterLast('.', "bin")
        return source.copyTo(File(dir, "$tag.$ext"), overwrite = true)
    }

    /** Новый файл в постоянной папке отправок (для импорта из чужого content://). */
    fun newPersistedFile(extension: String): File {
        val dir = File(dirs.support, "pending_uploads").apply { mkdirs() }
        val ext = extension.ifBlank { "bin" }
        return File(dir, "${UUID.randomUUID()}.$ext")
    }

    fun deletePersistedFile(path: String) {
        runCatching { File(path).delete() }
    }
}

/** Незавершённые чанковые загрузки — для докачки после перезапуска. */
class ChunkedUploadSessionStore(private val secure: SecureStore) {
    data class Entry(val mediaId: String, val uploadId: String, val partSize: Int, val keyBase64: String)

    private fun key(messageId: String) = "chunked_upload_session_$messageId"

    suspend fun get(messageId: String): Entry? = secure.read(key(messageId))?.let {
        val j = Json.parseToJsonElement(it).jsonObject
        Entry(j.string("media_id"), j.string("upload_id"), j["part_size"]!!.jsonPrimitive.int, j.string("key_base64"))
    }

    suspend fun save(messageId: String, e: Entry) = secure.write(
        key(messageId),
        buildJsonObject {
            put("media_id", e.mediaId); put("upload_id", e.uploadId); put("part_size", e.partSize); put("key_base64", e.keyBase64)
        }.toString(),
    )

    suspend fun clear(messageId: String) = secure.delete(key(messageId))
}

/** Очереди скачивания (ручная и авто), переживают перезапуск. */
class DownloadQueueStore(private val secure: SecureStore) {
    private val key = "media_download_queues_v1"
    private val autoCap = 300

    suspend fun load(): Pair<List<JsonObject>, List<JsonObject>> = try {
        val raw = secure.read(key)
        if (raw == null) {
            emptyList<JsonObject>() to emptyList()
        } else {
            val j = Json.parseToJsonElement(raw).jsonObject
            fun list(name: String) = (j[name] as? JsonArray)?.map { it.jsonObject }.orEmpty()
            list("manual") to list("auto")
        }
    } catch (_: Exception) {
        emptyList<JsonObject>() to emptyList()
    }

    suspend fun save(manual: List<JsonObject>, auto: List<JsonObject>) {
        runCatching {
            secure.write(key, JsonObject(mapOf("manual" to JsonArray(manual), "auto" to JsonArray(auto.take(autoCap)))).toString())
        }
    }

    suspend fun clear() {
        runCatching { secure.delete(key) }
    }
}

/** Файлы медиа на диске: расшифрованный кэш и недокачанные хвосты. */
class MediaFiles(private val dirs: AppDirs) {
    /** Расшифрованный файл (media_cache.dart — temp/media_cache_<id>). */
    fun cacheFile(mediaId: String) = File(dirs.temp, "media_cache_$mediaId")

    /** Недокачанный зашифрованный хвост (support/partial_downloads/<id>.part). */
    fun partialFile(mediaId: String): File = File(File(dirs.support, "partial_downloads").apply { mkdirs() }, "$mediaId.part")

    fun clearCache(): Int = dirs.temp.listFiles { f -> f.isFile && f.name.startsWith("media_cache_") }?.count { it.delete() } ?: 0

    fun cacheSize(): Long = dirs.temp.listFiles { f -> f.isFile && f.name.startsWith("media_cache_") }?.sumOf { it.length() } ?: 0

    fun pruneStalePartials(maxAgeMs: Long = 7L * 24 * 3600 * 1000) {
        val cutoff = System.currentTimeMillis() - maxAgeMs
        File(dirs.support, "partial_downloads").listFiles()?.filter { it.lastModified() < cutoff }?.forEach { it.delete() }
    }
}

data class AppLockSettings(
    val enabled: Boolean = false,
    val timeoutSeconds: Int = 60,
    val biometricEnabled: Boolean = false,
    val hasPin: Boolean = false,
    val pinLength: Int = 4,
)

/** Блокировка приложения PIN-кодом (app_lock_store.dart): hash = hex(SHA-256(utf8(pin) || salt)). */
class AppLockStore(private val secure: SecureStore) {
    private companion object {
        const val ENABLED = "app_lock_enabled"
        const val TIMEOUT = "app_lock_timeout_seconds"
        const val BIOMETRIC = "app_lock_biometric_enabled"
        const val PIN_HASH = "app_lock_pin_hash"
        const val PIN_SALT = "app_lock_pin_salt"
        const val PIN_LENGTH = "app_lock_pin_length"
    }

    private val _state = MutableStateFlow<AppLockSettings?>(null)

    /** Текущие настройки; null — ещё не прочитаны ([load]). Обновляется после каждого изменения. */
    val state: StateFlow<AppLockSettings?> = _state.asStateFlow()

    suspend fun load(): AppLockSettings = AppLockSettings(
        enabled = secure.read(ENABLED) == "true",
        timeoutSeconds = secure.read(TIMEOUT)?.toIntOrNull() ?: 60,
        biometricEnabled = secure.read(BIOMETRIC) == "true",
        hasPin = secure.read(PIN_HASH) != null,
        pinLength = secure.read(PIN_LENGTH)?.toIntOrNull() ?: 4,
    ).also { _state.value = it }

    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }

    private fun unhex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private fun hash(pin: String, saltHex: String) =
        hex(MessageDigest.getInstance("SHA-256").digest(pin.toByteArray(Charsets.UTF_8) + unhex(saltHex)))

    suspend fun setPin(pin: String) {
        val salt = hex(randomBytes(16))
        secure.write(PIN_SALT, salt)
        secure.write(PIN_HASH, hash(pin, salt))
        secure.write(PIN_LENGTH, pin.length.toString())
        load()
    }

    suspend fun verifyPin(pin: String): Boolean {
        val salt = secure.read(PIN_SALT) ?: return false
        val stored = secure.read(PIN_HASH) ?: return false
        return MessageDigest.isEqual(hash(pin, salt).toByteArray(), stored.toByteArray())
    }

    suspend fun removePin() {
        secure.delete(PIN_HASH)
        secure.delete(PIN_SALT)
        secure.delete(PIN_LENGTH)
        secure.write(BIOMETRIC, "false")
        secure.write(ENABLED, "false")
        load()
    }

    /** Включить можно только при заданном PIN. */
    suspend fun setEnabled(v: Boolean) {
        if (v && secure.read(PIN_HASH) == null) return
        secure.write(ENABLED, v.toString())
        load()
    }

    suspend fun setTimeoutSeconds(seconds: Int) {
        secure.write(TIMEOUT, seconds.toString())
        load()
    }

    suspend fun setBiometricEnabled(v: Boolean) {
        if (v && secure.read(PIN_HASH) == null) return
        secure.write(BIOMETRIC, v.toString())
        load()
    }
}

/**
 * Код подтверждения почты отправлен, но ещё не введён (email_dialog.dart):
 * 25 минут окно сразу открывается на шаге ввода кода, даже после перезапуска.
 */
class PendingEmailVerification(private val prefs: Prefs, private val now: () -> Long = System::currentTimeMillis) {
    private companion object {
        const val EMAIL = "pending_email_verification_email"
        const val AT = "pending_email_verification_requested_at_ms"
        const val TTL_MS = 25 * 60_000L
    }

    fun get(): String? {
        val email = prefs.getString(EMAIL) ?: return null
        val at = prefs.getLong(AT) ?: return null
        if (now() - at >= TTL_MS) {
            clear()
            return null
        }
        return email
    }

    fun set(email: String) {
        prefs.setString(EMAIL, email)
        prefs.setLong(AT, now())
    }

    fun clear() {
        prefs.remove(EMAIL)
        prefs.remove(AT)
    }
}

/** Мелкие настройки интерфейса — там же, где их держит Flutter. */
class UiSettings(private val secure: SecureStore, private val prefs: Prefs) {
    companion object {
        val TEXT_SCALE_STEPS = listOf(0.85, 0.9, 1.0, 1.1, 1.2, 1.3)
        const val DEFAULT_REACTION = "👍"
    }

    /** "light" | "dark" (по умолчанию dark). */
    suspend fun theme(): String = if (secure.read("app_theme_mode") == "light") "light" else "dark"
    suspend fun setTheme(mode: String) = secure.write("app_theme_mode", if (mode == "light") "light" else "dark")

    /** "ru" | "en" (по умолчанию en). */
    fun locale(): String = if (prefs.getString("app_locale") == "ru") "ru" else "en"
    fun setLocale(locale: String) = prefs.setString("app_locale", if (locale == "ru") "ru" else "en")

    fun textScale(): Double = prefs.getDouble("app_text_scale")?.takeIf { it in TEXT_SCALE_STEPS } ?: 1.0
    fun setTextScale(scale: Double) = prefs.setDouble("app_text_scale", scale)

    suspend fun defaultReaction(): String = secure.read("default_reaction_emoji") ?: DEFAULT_REACTION
    suspend fun setDefaultReaction(emoji: String) = secure.write("default_reaction_emoji", emoji)

    /** Частота реакций — для сортировки панели реакций. */
    suspend fun reactionUsage(): Map<String, Int> = secure.read("reaction_usage_counts")
        ?.let { Json.parseToJsonElement(it).jsonObject.mapValues { (_, v) -> v.jsonPrimitive.int } }.orEmpty()

    suspend fun recordReactionUse(emoji: String) {
        val counts = reactionUsage().toMutableMap()
        counts[emoji] = (counts[emoji] ?: 0) + 1
        secure.write("reaction_usage_counts", JsonObject(counts.mapValues { JsonPrimitive(it.value) }).toString())
    }

    /** [all] в исходном порядке, отсортированные по частоте использования. */
    suspend fun sortedReactions(all: List<String>): List<String> {
        val counts = reactionUsage()
        return all.sortedWith(compareByDescending<String> { counts[it] ?: 0 }.thenBy { all.indexOf(it) })
    }

    /**
     * Где пользователь остановился в чате: сообщение у нижнего края и сдвиг
     * в пикселях; null — был в самом низу. (Пиксельный offset Flutter-клиента,
     * "chat_scroll_pos:", к ленивому списку неприменим и не читается.)
     */
    fun chatScrollAnchor(peerLogin: String): Pair<String, Int>? =
        prefs.getString("chat_scroll_anchor:$peerLogin")?.let { v ->
            val id = v.substringBeforeLast('|')
            val offset = v.substringAfterLast('|').toIntOrNull() ?: return null
            id to offset
        }

    fun setChatScrollAnchor(peerLogin: String, anchor: Pair<String, Int>?) {
        if (anchor == null) prefs.remove("chat_scroll_anchor:$peerLogin")
        else prefs.setString("chat_scroll_anchor:$peerLogin", "${anchor.first}|${anchor.second}")
    }

    fun keyboardHeight(fallback: Double = 280.0): Double = prefs.getDouble("keyboard_height_v1") ?: fallback
    fun setKeyboardHeight(height: Double) = prefs.setDouble("keyboard_height_v1", height)

    /** Спрашивали ли разрешение "поверх других приложений" (входящий звонок на весь экран) — спрашиваем один раз. */
    fun overlayPermissionAsked(): Boolean = prefs.getBool("overlay_permission_asked") ?: false
    fun setOverlayPermissionAsked() = prefs.setBool("overlay_permission_asked", true)
}

/** Кэш своего профиля на диске (my_profile_store.dart — documents/my_profile_cache.json). */
data class MyProfile(
    val login: String,
    val displayName: String? = null,
    val status: String? = null,
    val birthday: String? = null,
    val findByLoginVisibility: Int = 1,
    val avatarVisibility: Int = 1,
    val birthdayVisibility: Int = 1,
    val statusVisibility: Int = 1,
) {
    fun toJson(): JsonObject = buildJsonObject {
        put("login", login)
        put("display_name", displayName)
        put("status", status)
        put("birthday", birthday)
        put("find_by_login_visibility", findByLoginVisibility)
        put("avatar_visibility", avatarVisibility)
        put("birthday_visibility", birthdayVisibility)
        put("status_visibility", statusVisibility)
    }

    companion object {
        fun fromJson(j: JsonObject): MyProfile {
            fun i(n: String) = j.optInt(n) ?: 1
            return MyProfile(
                j.string("login"), j.optString("display_name"), j.optString("status"), j.optString("birthday"),
                i("find_by_login_visibility"), i("avatar_visibility"), i("birthday_visibility"), i("status_visibility"),
            )
        }

        fun cacheFile(dirs: AppDirs) = File(dirs.documents, "my_profile_cache.json")
        fun avatarCacheFile(dirs: AppDirs) = File(dirs.documents, "my_avatar_cache.bin")
    }
}
