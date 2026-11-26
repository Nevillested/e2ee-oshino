package com.oshinobu.demobot

import com.oshinobu.core.storage.Prefs
import com.oshinobu.core.storage.SecureStore
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermissions

/**
 * JSON-файл со словарём, запись — целиком через временный файл (не оставит
 * полузаписанный файл при остановке процесса), права 600: внутри ключи
 * устройства бота и состояние сессий шифрования.
 */
internal class JsonFileMap(private val file: File) {
    private val lock = Any()
    private val map: MutableMap<String, JsonElement> = load()

    private fun load(): MutableMap<String, JsonElement> =
        if (file.exists()) HashMap((Json.parseToJsonElement(file.readText()) as JsonObject)) else HashMap()

    fun get(key: String): JsonElement? = synchronized(lock) { map[key] }

    fun all(): Map<String, JsonElement> = synchronized(lock) { HashMap(map) }

    fun keys(): Set<String> = synchronized(lock) { HashSet(map.keys) }

    fun put(key: String, value: JsonElement) = synchronized(lock) {
        map[key] = value
        save()
    }

    fun remove(key: String) = synchronized(lock) {
        if (map.remove(key) != null) save()
    }

    fun clear() = synchronized(lock) {
        map.clear()
        save()
    }

    private fun save() {
        file.parentFile?.mkdirs()
        val tmp = File(file.path + ".tmp")
        tmp.writeText(JsonObject(map).toString())
        restrict(tmp)
        Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }
}

/** Только владельцу (на системах без POSIX-прав — как есть). */
internal fun restrict(file: File) {
    runCatching { Files.setPosixFilePermissions(file.toPath(), PosixFilePermissions.fromString("rw-------")) }
}

/** [SecureStore] бота: ключи и сессии — в файле с правами 600 (на сервере его читает только root). */
class FileSecureStore(file: File) : SecureStore {
    private val data = JsonFileMap(file)

    override suspend fun read(key: String): String? = data.get(key)?.jsonPrimitive?.content

    override suspend fun write(key: String, value: String) = data.put(key, JsonPrimitive(value))

    override suspend fun delete(key: String) = data.remove(key)

    override suspend fun readAll(): Map<String, String> = data.all().mapValues { it.value.jsonPrimitive.content }

    override suspend fun deleteAll() = data.clear()
}

/** [Prefs] бота — тот же JSON-файл (типы хранятся как есть). */
class FilePrefs(file: File) : Prefs {
    private val data = JsonFileMap(file)

    private fun primitive(key: String) = data.get(key) as? JsonPrimitive

    override fun getString(key: String): String? = primitive(key)?.takeIf { it.isString }?.content

    override fun getLong(key: String): Long? = primitive(key)?.longOrNull

    override fun getDouble(key: String): Double? = primitive(key)?.doubleOrNull

    override fun getBool(key: String): Boolean? = primitive(key)?.booleanOrNull

    override fun getStringList(key: String): List<String>? = (data.get(key) as? JsonArray)?.map { it.jsonPrimitive.content }

    override fun setString(key: String, value: String) = data.put(key, JsonPrimitive(value))

    override fun setLong(key: String, value: Long) = data.put(key, JsonPrimitive(value))

    override fun setDouble(key: String, value: Double) = data.put(key, JsonPrimitive(value))

    override fun setBool(key: String, value: Boolean) = data.put(key, JsonPrimitive(value))

    override fun setStringList(key: String, value: List<String>) = data.put(key, JsonArray(value.map(::JsonPrimitive)))

    override fun remove(key: String) = data.remove(key)

    override fun keys(): Set<String> = data.keys()
}
