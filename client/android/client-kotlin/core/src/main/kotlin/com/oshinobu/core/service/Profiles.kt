package com.oshinobu.core.service

import com.oshinobu.core.net.ApiClient
import com.oshinobu.core.net.MyAccountInfo
import com.oshinobu.core.net.PrivacySettings
import com.oshinobu.core.optBool
import com.oshinobu.core.optObjects
import com.oshinobu.core.optString
import com.oshinobu.core.storage.AppDirs
import com.oshinobu.core.storage.MyProfile
import com.oshinobu.core.storage.Session
import com.oshinobu.core.string
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/** Профиль собеседника, каким его отдаёт сервер с учётом его настроек приватности. */
data class PeerProfile(
    val login: String,
    val displayName: String,
    val devices: List<JsonObject>,
    val status: String?,
    val birthday: String?,
    val hasAvatar: Boolean,
) {
    /** Тот же JSON, что кладёт на диск Flutter-клиент (peer_profile_cache_<id>). */
    fun toJson() = buildJsonObject {
        put("login", login)
        put("display_name", displayName)
        put("devices", JsonArray(devices))
        put("status", status)
        put("birthday", birthday)
        put("has_avatar", hasAvatar)
    }

    companion object {
        fun fromJson(j: JsonObject): PeerProfile {
            val login = j.string("login")
            return PeerProfile(
                login, j.optString("display_name") ?: login, j.optObjects("devices"),
                j.optString("status"), j.optString("birthday"), j.optBool("has_avatar") ?: false,
            )
        }
    }
}

/** Профили собеседников по account_id (кэш — [RemoteCache], копия — temp/peer_profile_cache_<id>). */
class PeerProfiles(api: ApiClient, session: Session, dirs: AppDirs, scope: CoroutineScope, log: Logger = NoopLogger) {
    /** account_id → логин: профиль запрашивается по логину. */
    private val logins = ConcurrentHashMap<String, String>()

    private val cache = RemoteCache(
        scope = scope,
        diskFile = { File(dirs.temp, "peer_profile_cache_$it") },
        encode = { it.toJson().toString().toByteArray() },
        decode = { PeerProfile.fromJson(Json.parseToJsonElement(it.decodeToString()).jsonObject) },
        fetch = { accountId ->
            val token = session.token ?: error("not logged in")
            api.getAccountProfile(token, logins.getValue(accountId))?.let {
                PeerProfile(it.login, it.displayName, it.devices, it.status, it.birthday, it.hasAvatar)
            }
        },
        log = log,
    )

    val changes = cache.changes

    fun peek(accountId: String) = cache.peek(accountId)

    /** null — профиль скрыт или аккаунт удалён. */
    suspend fun get(accountId: String, login: String): PeerProfile? {
        logins[accountId] = login
        return cache.get(accountId)
    }

    /** Сервер прислал profile_updated. */
    suspend fun invalidate(accountId: String) = cache.invalidate(accountId)

    /** Дисковую копию — в память без сети (см. [RemoteCache.warm]). */
    suspend fun warm(accountId: String, login: String) {
        logins[accountId] = login
        cache.warm(accountId)
    }
}

/** Аватары собеседников по account_id (копия — temp/avatar_cache_<id>). */
class Avatars(api: ApiClient, session: Session, dirs: AppDirs, scope: CoroutineScope, log: Logger = NoopLogger) {
    private val cache = RemoteCache(
        scope = scope,
        diskFile = { File(dirs.temp, "avatar_cache_$it") },
        encode = { it },
        decode = { it },
        fetch = { accountId -> api.getAvatar(session.token ?: error("not logged in"), accountId) },
        same = { a, b -> (a == null && b == null) || (a != null && b != null && a.contentEquals(b)) },
        log = log,
    )

    val changes = cache.changes

    fun peek(accountId: String) = cache.peek(accountId)

    /** JPEG-байты; null — аватара нет. */
    suspend fun get(accountId: String): ByteArray? = cache.get(accountId)

    /** Сервер прислал avatar_changed / profile_updated. */
    suspend fun invalidate(accountId: String) = cache.invalidate(accountId)

    /** Дисковую копию — в память без сети (см. [RemoteCache.warm]). */
    suspend fun warm(accountId: String) = cache.warm(accountId)
}

/**
 * Свой аккаунт для экранов профиля и настроек: профиль, аватар, почта
 * (порт my_profile_store / my_avatar_store / my_email_store). Копия профиля
 * и аватара — на диске, первым кадром показывается она, затем — свежее с сервера.
 */
class MyAccount(private val api: ApiClient, private val session: Session, private val dirs: AppDirs, private val log: Logger = NoopLogger) {
    private val _profile = MutableStateFlow<MyProfile?>(null)
    private val _avatar = MutableStateFlow<ByteArray?>(null)
    private val _email = MutableStateFlow<String?>(null)

    val profile: StateFlow<MyProfile?> = _profile.asStateFlow()
    val avatar: StateFlow<ByteArray?> = _avatar.asStateFlow()
    val email: StateFlow<String?> = _email.asStateFlow()

    private val profileFile get() = MyProfile.cacheFile(dirs)
    private val avatarFile get() = MyProfile.avatarCacheFile(dirs)

    /** Диск → сервер. Сетевые ошибки оставляют дисковую копию. */
    suspend fun load() {
        val token = session.token ?: return
        runCatching { _profile.value = MyProfile.fromJson(Json.parseToJsonElement(profileFile.readText()).jsonObject) }
        runCatching { if (avatarFile.exists()) _avatar.value = avatarFile.readBytes() }
            .onFailure { log.error("MyAccount: avatar copy unreadable: $it") }

        api.getMyAccountInfo(token)?.let { info -> applyInfo(info) }
        try {
            setAvatar(api.getMyAvatar(token))
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
        }
    }

    private fun applyInfo(info: MyAccountInfo) {
        session.login = info.login
        session.accountId = info.accountId
        _email.value = info.email
        setProfile(
            MyProfile(
                info.login, info.displayName, info.status, info.birthday,
                info.findByLoginVisibility, info.avatarVisibility, info.birthdayVisibility, info.statusVisibility,
            ),
        )
    }

    private fun setProfile(p: MyProfile?) {
        _profile.value = p
        runCatching { if (p == null) profileFile.delete() else profileFile.writeText(p.toJson().toString()) }
    }

    private fun update(change: (MyProfile) -> MyProfile) = _profile.value?.let { setProfile(change(it)) }

    fun setDisplayName(name: String?) = update { it.copy(displayName = name?.takeIf { n -> n.isNotEmpty() }) }
    fun setStatus(status: String?) = update { it.copy(status = status) }
    fun setBirthday(birthday: String?) = update { it.copy(birthday = birthday) }
    fun setPrivacy(p: PrivacySettings) = update {
        it.copy(findByLoginVisibility = p.findByLogin, avatarVisibility = p.avatar, birthdayVisibility = p.birthday, statusVisibility = p.status)
    }

    fun setEmail(email: String?) = _email.update { email }

    /** null/пусто — аватар удалён. */
    fun setAvatar(bytes: ByteArray?) {
        val value = bytes?.takeIf { it.isNotEmpty() }
        _avatar.value = value
        runCatching {
            if (value == null) {
                avatarFile.delete()
            } else {
                val tmp = File(avatarFile.path + ".tmp").apply { writeBytes(value) }
                tmp.renameTo(avatarFile)
            }
        }.onFailure { log.error("MyAccount: avatar write failed: $it") }
    }

    /** Выход из аккаунта. */
    fun reset() {
        setProfile(null)
        setAvatar(null)
        _email.value = null
    }
}
