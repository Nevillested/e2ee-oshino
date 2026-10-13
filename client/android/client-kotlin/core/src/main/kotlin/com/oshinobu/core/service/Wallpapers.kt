package com.oshinobu.core.service

import com.oshinobu.core.net.ApiClient
import com.oshinobu.core.storage.AppDirs
import com.oshinobu.core.storage.Session
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.io.File

/** Обои чата на устройстве; [version] меняется с каждой новой картинкой. */
data class Wallpaper(val file: File, val version: Long)

/**
 * Обои чатов. Главная копия — на сервере (переживает переустановку), здесь —
 * файлы для показа без сети: support/wallpapers/<account_id собеседника>.jpg
 * и index.json (account_id → версия). При запуске и по сигналу
 * wallpaper_changed список сверяется с сервером: новые и сменившиеся —
 * скачиваются, снятые — удаляются.
 */
class Wallpapers(
    private val api: ApiClient,
    private val session: Session,
    dirs: AppDirs,
    private val log: Logger = NoopLogger,
) {
    private val dir = File(dirs.support, "wallpapers")
    private val indexFile = File(dir, "index.json")
    private val lock = Mutex()

    private val _all = MutableStateFlow<Map<String, Wallpaper>>(emptyMap())

    /** account_id собеседника → обои чата с ним. */
    val all: StateFlow<Map<String, Wallpaper>> = _all.asStateFlow()

    private fun fileOf(peerAccountId: String) = File(dir, "$peerAccountId.jpg")

    /** Дисковая копия — в память (до сети). */
    suspend fun load() = lock.withLock {
        val index = runCatching {
            Json.parseToJsonElement(indexFile.readText()).jsonObject.mapValues { it.value.jsonPrimitive.long }
        }.getOrDefault(emptyMap())
        _all.value = index.mapNotNull { (id, version) -> fileOf(id).takeIf { it.exists() }?.let { id to Wallpaper(it, version) } }.toMap()
    }

    /** Сверка с сервером; без сети — остаётся то, что на устройстве. */
    suspend fun sync() {
        val token = session.token ?: return
        val remote = api.getChatWallpapers(token) ?: return
        lock.withLock {
            for (id in _all.value.keys - remote.keys) drop(id)
            for ((id, version) in remote) {
                if (_all.value[id]?.version == version) continue
                try {
                    val bytes = api.getChatWallpaper(token, id)
                    if (bytes == null) drop(id) else save(id, bytes, version)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    log.error("Wallpapers: download failed for $id: $e")
                }
            }
        }
    }

    /** Поставить обои чату с [peerAccountId] ([forPeer] — и собеседнику). Ошибка сети — исключение. */
    suspend fun set(peerAccountId: String, jpeg: ByteArray, forPeer: Boolean) {
        val token = session.token ?: error("not logged in")
        val version = api.setChatWallpaper(token, peerAccountId, jpeg, forPeer)
        lock.withLock { save(peerAccountId, jpeg, version) }
    }

    /** Убрать обои чата (только у себя). */
    suspend fun remove(peerAccountId: String) {
        val token = session.token ?: error("not logged in")
        api.deleteChatWallpaper(token, peerAccountId)
        lock.withLock { drop(peerAccountId) }
    }

    /** Выход из аккаунта. */
    suspend fun reset() = lock.withLock {
        _all.value = emptyMap()
        dir.deleteRecursively()
    }

    private fun save(id: String, bytes: ByteArray, version: Long) {
        dir.mkdirs()
        val file = fileOf(id)
        val tmp = File(dir, "$id.jpg.tmp").apply { writeBytes(bytes) }
        if (!tmp.renameTo(file)) {
            tmp.delete()
            error("wallpaper: rename failed")
        }
        _all.update { it + (id to Wallpaper(file, version)) }
        writeIndex()
    }

    private fun drop(id: String) {
        fileOf(id).delete()
        _all.update { it - id }
        writeIndex()
    }

    private fun writeIndex() {
        runCatching {
            indexFile.writeText(JsonObject(_all.value.mapValues { JsonPrimitive(it.value.version) }).toString())
        }.onFailure { log.error("Wallpapers: index write failed: $it") }
    }
}
