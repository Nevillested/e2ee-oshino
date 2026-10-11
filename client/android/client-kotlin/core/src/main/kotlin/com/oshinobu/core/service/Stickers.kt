package com.oshinobu.core.service

import com.oshinobu.core.net.ApiClient
import com.oshinobu.core.net.StickerInfo
import com.oshinobu.core.net.StickerPackInfo
import com.oshinobu.core.net.StickerUploadEvent
import com.oshinobu.core.optBool
import com.oshinobu.core.optObjects
import com.oshinobu.core.optString
import com.oshinobu.core.storage.AppDirs
import com.oshinobu.core.storage.SecureStore
import com.oshinobu.core.storage.Session
import com.oshinobu.core.string
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.zip.ZipInputStream

/** Что показать на месте стикера из переписки. */
sealed interface StickerFile {
    data class Ready(val file: File, val animated: Boolean) : StickerFile

    /** Пак удалён автором, а файла на устройстве нет. */
    data object PackDeleted : StickerFile

    /** Не скачался (нет сети) — попробуем при следующем показе. */
    data object Unavailable : StickerFile
}

/**
 * Стикеры: установленные паки (список живёт на сервере, здесь — копия для
 * показа без сети), недавние, файлы на устройстве. Стикер из переписки
 * несёт только свой id; файл берётся из пака, и пак скачивается ЦЕЛИКОМ —
 * сервер видит "скачан пак", а не какой стикер пришёл. Файлы лежат в кэше
 * (temp/stickers/<id>.<формат>) и после очистки кэша скачиваются заново.
 */
class Stickers(
    private val api: ApiClient,
    private val session: Session,
    private val secure: SecureStore,
    private val dirs: AppDirs,
    private val log: Logger = NoopLogger,
) {
    private val _installed = MutableStateFlow<List<StickerPackInfo>>(emptyList())

    /** Установленные паки, новые первыми. */
    val installed: StateFlow<List<StickerPackInfo>> = _installed.asStateFlow()

    private val _recent = MutableStateFlow<List<StickerInfo>>(emptyList())

    /** Недавно отправленные, последний — первым. */
    val recent: StateFlow<List<StickerInfo>> = _recent.asStateFlow()

    private val _changes = MutableSharedFlow<Unit>(extraBufferCapacity = 16)

    /** Файлы на устройстве появились или пропали — показанные стикеры перечитываются. */
    val changes: SharedFlow<Unit> = _changes.asSharedFlow()

    /** Пак стикера: из установленных и уже открытых паков — без запроса к серверу. */
    private val packOfSticker = ConcurrentHashMap<String, StickerPackInfo>()
    private val packLocks = KeyedMutex()
    private val stateLock = Mutex()
    @Volatile
    private var loaded = false

    private val dir: File get() = File(dirs.temp, STICKER_DIR).apply { mkdirs() }

    private fun token() = session.token ?: error("not logged in")

    private fun remember(pack: StickerPackInfo) {
        pack.stickers.forEach { packOfSticker[it.id] = pack }
    }

    // ---------------- списки ----------------

    /** Сохранённые на устройстве списки — в память (один раз за сессию). */
    suspend fun load() = stateLock.withLock {
        if (loaded) return@withLock
        loaded = true
        runCatching {
            secure.read(KEY_INSTALLED)?.let { raw -> _installed.value = Json.parseToJsonElement(raw).jsonArray.map { packFromJson(it.jsonObject) } }
            secure.read(KEY_RECENT)?.let { raw -> _recent.value = Json.parseToJsonElement(raw).jsonArray.map { stickerFromJson(it.jsonObject) } }
        }.onFailure { log.error("Stickers load failed: $it") }
        _installed.value.forEach(::remember)
    }

    /** Установленные паки с сервера (после входа на новом устройстве — тоже оттуда). */
    suspend fun sync() {
        load()
        val packs = try {
            api.getMyStickerPacks(token())
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log.error("Stickers sync failed: $e")
            return
        }
        packs.forEach(::remember)
        setInstalled(packs)
    }

    private suspend fun setInstalled(packs: List<StickerPackInfo>) {
        _installed.value = packs
        runCatching { secure.write(KEY_INSTALLED, JsonArray(packs.map(::packToJson)).toString()) }
    }

    private suspend fun setRecent(stickers: List<StickerInfo>) {
        _recent.value = stickers
        runCatching { secure.write(KEY_RECENT, JsonArray(stickers.map(::stickerToJson)).toString()) }
    }

    /** Стикер отправлен — в начало недавних. */
    suspend fun recordRecent(sticker: StickerInfo) = stateLock.withLock {
        setRecent((listOf(sticker) + _recent.value.filter { it.id != sticker.id }).take(MAX_RECENT))
    }

    private suspend fun dropRecentOf(packId: String) = stateLock.withLock {
        if (_recent.value.any { it.packId == packId }) setRecent(_recent.value.filter { it.packId != packId })
    }

    /** Выход из аккаунта: списки — чужие для следующего входа. */
    fun reset() {
        loaded = false
        _installed.value = emptyList()
        _recent.value = emptyList()
        packOfSticker.clear()
    }

    // ---------------- паки ----------------

    /** Пак стикера из переписки — свежий, с сервера (установлен ли, автор ли); null — нет такого. */
    suspend fun fetchPackOf(stickerId: String): StickerPackInfo? =
        api.getStickerPackBySticker(token(), stickerId)?.also(::remember)

    suspend fun install(pack: StickerPackInfo) {
        api.installStickerPack(token(), pack.id)
        remember(pack)
        stateLock.withLock { setInstalled(listOf(pack.copy(installed = true)) + _installed.value.filter { it.id != pack.id }) }
    }

    suspend fun uninstall(packId: String) {
        api.uninstallStickerPack(token(), packId)
        stateLock.withLock { setInstalled(_installed.value.filter { it.id != packId }) }
    }

    /** Удалить навсегда (только автор): у всех пропадает из панели, у кого не скачан — "удалён автором". */
    suspend fun deleteForever(packId: String) {
        api.deleteStickerPack(token(), packId)
        stateLock.withLock { setInstalled(_installed.value.filter { it.id != packId }) }
        dropRecentOf(packId)
    }

    /** Загрузка своего пака; готовый — первым в панели. */
    suspend fun upload(title: String, archive: File, onProgress: (Double) -> Unit, onEvent: (StickerUploadEvent) -> Unit): StickerPackInfo {
        val pack = api.uploadStickerPack(token(), title, archive, onProgress, onEvent)
        remember(pack)
        stateLock.withLock { setInstalled(listOf(pack) + _installed.value.filter { it.id != pack.id }) }
        return pack
    }

    // ---------------- файлы ----------------

    private fun fileOf(sticker: StickerInfo) = File(dir, "${sticker.id}.${sticker.format}")

    /** Файл стикера, если он уже на устройстве. */
    fun cachedFile(stickerId: String): File? = FORMATS.map { File(dir, "$stickerId.$it") }.firstOrNull { it.exists() }

    /** Файл стикера из панели: с устройства или скачав его пак; null — не вышло. */
    suspend fun file(sticker: StickerInfo): File? {
        fileOf(sticker).takeIf { it.exists() }?.let { return it }
        val pack = packOfSticker[sticker.id] ?: runCatching { fetchPackOf(sticker.id) }.getOrNull() ?: return null
        if (pack.deleted) {
            dropRecentOf(pack.id)
            return null
        }
        if (!ensurePack(pack)) return null
        return fileOf(sticker).takeIf { it.exists() }
    }

    /** Стикер из переписки по id: с устройства, иначе — скачав весь его пак. */
    suspend fun resolve(stickerId: String): StickerFile {
        cachedFile(stickerId)?.let { return StickerFile.Ready(it, it.extension == "tgs") }
        val pack = try {
            packOfSticker[stickerId] ?: fetchPackOf(stickerId) ?: return StickerFile.PackDeleted
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log.error("Stickers pack lookup failed sticker=$stickerId: $e")
            return StickerFile.Unavailable
        }
        if (pack.deleted) return StickerFile.PackDeleted
        val ok = try {
            ensurePack(pack)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log.error("Stickers pack download failed pack=${pack.id}: $e")
            return StickerFile.Unavailable
        }
        if (!ok) return StickerFile.PackDeleted
        return cachedFile(stickerId)?.let { StickerFile.Ready(it, it.extension == "tgs") } ?: StickerFile.Unavailable
    }

    /** Все файлы пака на устройстве (скачивает недостающие одним архивом); false — пак удалён автором. */
    suspend fun ensurePack(pack: StickerPackInfo): Boolean = packLocks.run(pack.id) {
        if (pack.stickers.all { fileOf(it).exists() }) return@run true
        val zip = File(dir, ".pack-${pack.id}.zip")
        try {
            if (!api.downloadStickerPack(token(), pack.id, zip)) {
                packOfSticker.values.removeAll { it.id == pack.id }
                dropRecentOf(pack.id)
                return@run false
            }
            extract(pack, zip)
        } finally {
            zip.delete()
        }
        _changes.tryEmit(Unit)
        true
    }

    /** Из архива берутся только файлы этого пака (<id>.<формат>), с пределом размера. */
    private fun extract(pack: StickerPackInfo, zip: File) {
        val wanted = pack.stickers.associateBy { "${it.id}.${it.format}" }
        ZipInputStream(zip.inputStream().buffered()).use { zin ->
            while (true) {
                val entry = zin.nextEntry ?: break
                val sticker = wanted[entry.name] ?: continue
                val data = zin.readAtMost(MAX_STICKER_BYTES + 1)
                if (data.size > MAX_STICKER_BYTES) continue
                val tmp = File(dir, ".${entry.name}.tmp")
                tmp.writeBytes(data)
                if (!tmp.renameTo(fileOf(sticker))) tmp.delete()
            }
        }
    }

    // readNBytes — только с Android 13
    private fun ZipInputStream.readAtMost(limit: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buf = ByteArray(16 * 1024)
        while (out.size() < limit) {
            val n = read(buf, 0, minOf(buf.size, limit - out.size()))
            if (n < 0) break
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }

    /** Очистка кэша: все стикеры с устройства (потом скачаются заново). */
    fun clearCache(): Int {
        val count = dir.listFiles()?.count { it.isFile && it.delete() } ?: 0
        _changes.tryEmit(Unit)
        return count
    }

    fun cacheSize(): Long = dir.listFiles()?.filter { it.isFile }?.sumOf { it.length() } ?: 0

    companion object {
        const val MAX_RECENT = 15
        private const val STICKER_DIR = "stickers"
        private const val KEY_INSTALLED = "sticker_packs_installed"
        private const val KEY_RECENT = "sticker_recent"
        private val FORMATS = listOf("webp", "png", "tgs")

        /** Самый большой допустимый файл (статичный — 512 КБ; TGS меньше). */
        private const val MAX_STICKER_BYTES = 512 * 1024

        private fun stickerToJson(s: StickerInfo) = buildJsonObject {
            put("id", s.id)
            put("format", s.format)
            put("pack_id", s.packId)
        }

        private fun stickerFromJson(j: JsonObject) = StickerInfo(j.string("id"), j.string("format"), j.string("pack_id"))

        private fun packToJson(p: StickerPackInfo) = buildJsonObject {
            put("id", p.id)
            put("title", p.title)
            put("is_owner", p.isOwner)
            put("stickers", JsonArray(p.stickers.map(::stickerToJson)))
        }

        private fun packFromJson(j: JsonObject) = StickerPackInfo(
            id = j.string("id"),
            title = j.optString("title").orEmpty(),
            isOwner = j.optBool("is_owner") ?: false,
            installed = true,
            deleted = false,
            stickers = j.optObjects("stickers").map(::stickerFromJson),
        )
    }
}
