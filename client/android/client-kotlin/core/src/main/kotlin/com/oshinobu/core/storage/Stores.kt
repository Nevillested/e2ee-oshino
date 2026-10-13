package com.oshinobu.core.storage

import java.io.File
import java.util.concurrent.ConcurrentHashMap

// Хранилища ключ-значение, в которых приложение держит всё состояние.
//
// ФОРМАТ ХРАНЕНИЯ УНАСЛЕДОВАН от первой версии клиента (Flutter) и менять
// его нельзя: на нём лежат ключи шифрования и переписка всех установленных
// копий. Отсюда и "flutter" в именах файлов и модуля :flutter-compat — это
// названия форматов на диске, а не зависимость от Flutter (его в проекте нет):
//  - [SecureStore] — зашифрованное хранилище в формате flutter_secure_storage
//    (на Android — вендорный Java-код этой библиотеки, модуль :flutter-compat);
//  - [Prefs] — файл FlutterSharedPreferences, ключи с префиксом "flutter.",
//    int хранится как Long, список — JSON с префиксом;
//  - [AppDirs] — каталоги приложения.

/** Зашифрованное хранилище строк. */
interface SecureStore {
    suspend fun read(key: String): String?
    suspend fun write(key: String, value: String)
    suspend fun delete(key: String)
    suspend fun readAll(): Map<String, String>
    suspend fun deleteAll()
}

/** Незашифрованные настройки. Ключи — БЕЗ префикса "flutter." (его добавляет реализация). */
interface Prefs {
    fun getString(key: String): String?
    fun getLong(key: String): Long?
    fun getDouble(key: String): Double?
    fun getBool(key: String): Boolean?
    fun getStringList(key: String): List<String>?
    fun setString(key: String, value: String)
    fun setLong(key: String, value: Long)
    fun setDouble(key: String, value: Double)
    fun setBool(key: String, value: Boolean)
    fun setStringList(key: String, value: List<String>)
    fun remove(key: String)
    fun keys(): Set<String>
}

/**
 * Каталоги приложения на Android (имена — унаследованный формат):
 * documents = app_flutter, support = files, temp = cache.
 */
class AppDirs(val documents: File, val support: File, val temp: File)

class InMemorySecureStore(initial: Map<String, String> = emptyMap()) : SecureStore {
    private val map = ConcurrentHashMap(initial)
    override suspend fun read(key: String) = map[key]
    override suspend fun write(key: String, value: String) {
        map[key] = value
    }
    override suspend fun delete(key: String) {
        map.remove(key)
    }
    override suspend fun readAll(): Map<String, String> = HashMap(map)
    override suspend fun deleteAll() = map.clear()
}

class InMemoryPrefs : Prefs {
    private val map = ConcurrentHashMap<String, Any>()
    override fun getString(key: String) = map[key] as? String
    override fun getLong(key: String) = map[key] as? Long
    override fun getDouble(key: String) = map[key] as? Double
    override fun getBool(key: String) = map[key] as? Boolean
    @Suppress("UNCHECKED_CAST")
    override fun getStringList(key: String) = map[key] as? List<String>
    override fun setString(key: String, value: String) { map[key] = value }
    override fun setLong(key: String, value: Long) { map[key] = value }
    override fun setDouble(key: String, value: Double) { map[key] = value }
    override fun setBool(key: String, value: Boolean) { map[key] = value }
    override fun setStringList(key: String, value: List<String>) { map[key] = value.toList() }
    override fun remove(key: String) { map.remove(key) }
    override fun keys(): Set<String> = map.keys.toSet()
}
