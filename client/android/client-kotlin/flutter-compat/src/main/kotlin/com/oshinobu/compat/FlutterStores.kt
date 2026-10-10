package com.oshinobu.compat

import android.content.Context
import android.content.SharedPreferences
import android.os.Handler
import android.os.HandlerThread
import com.it_nomads.fluttersecurestorage.FlutterSecureStorage
import com.it_nomads.fluttersecurestorage.FlutterSecureStorageConfig
import com.it_nomads.fluttersecurestorage.SecurePreferencesCallback
import com.oshinobu.core.storage.AppDirs
import com.oshinobu.core.storage.Prefs
import com.oshinobu.core.storage.SecureStore
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import java.io.ByteArrayInputStream
import java.io.ObjectInputStream
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * [SecureStore] поверх кода flutter_secure_storage (модуль :flutter-compat) с
 * ТЕМИ ЖЕ настройками, с какими его вызывает Flutter-клиент
 * (`const FlutterSecureStorage()` без AndroidOptions → AndroidOptions.toMap()
 * по умолчанию). Все операции — на одном рабочем потоке, как в плагине.
 */
class FlutterSecureStoreAdapter(context: Context) : SecureStore {
    private companion object {
        /** AndroidOptions() Flutter-клиента по умолчанию (android_options.dart → toMap). */
        val DEFAULT_OPTIONS: Map<String, Any> = mapOf(
            "encryptedSharedPreferences" to "false",
            "resetOnError" to "true",
            "migrateOnAlgorithmChange" to "true",
            "migrateWithBackup" to "false",
            "enforceBiometrics" to "false",
            "keyCipherAlgorithm" to "RSA_ECB_OAEPwithSHA_256andMGF1Padding",
            "storageCipherAlgorithm" to "AES_GCM_NoPadding",
            "biometricType" to "biometricOrDeviceCredential",
            "sharedPreferencesName" to "",
            "preferencesKeyPrefix" to "",
            "storageNamespace" to "",
            "biometricPromptTitle" to "Authenticate to access",
            "biometricPromptSubtitle" to "Use biometrics or device credentials",
            "biometricPromptNegativeButton" to "Cancel",
        )
    }

    private val storage = FlutterSecureStorage(context.applicationContext)
    private val config = FlutterSecureStorageConfig(DEFAULT_OPTIONS)
    private val worker = HandlerThread("oshinobu.securestorage").apply { start() }
    private val handler = Handler(worker.looper)

    /** Выполняет [op] на рабочем потоке после initialize(), как MethodRunner плагина. */
    private suspend fun <T> run(op: () -> T): T = suspendCancellableCoroutine { cont ->
        handler.post {
            storage.initialize(
                config,
                object : SecurePreferencesCallback<Void?> {
                    override fun onSuccess(result: Void?) {
                        try {
                            cont.resume(op())
                        } catch (e: Exception) {
                            cont.resumeWithException(e)
                        }
                    }

                    override fun onError(e: Exception) {
                        cont.resumeWithException(e)
                    }
                },
            )
        }
    }

    override suspend fun read(key: String): String? = run {
        val k = storage.addPrefixToKey(key)
        if (storage.containsKey(k)) storage.read(k) else null
    }

    override suspend fun write(key: String, value: String) = run { storage.write(storage.addPrefixToKey(key), value) }

    override suspend fun delete(key: String) = run { storage.delete(storage.addPrefixToKey(key)) }

    override suspend fun readAll(): Map<String, String> = run { storage.readAll() }

    override suspend fun deleteAll() = run { storage.deleteAll() }
}

/**
 * [Prefs] поверх файла shared_preferences Flutter-клиента: имя
 * FlutterSharedPreferences, ключи с префиксом "flutter.", int → Long,
 * double → строка с префиксом, список → JSON с префиксом (новый формат) или
 * сериализованный Java-список (старый, только чтение).
 */
class FlutterPrefsAdapter(context: Context) : Prefs {
    private companion object {
        const val FILE = "FlutterSharedPreferences"
        const val PREFIX = "flutter."
        const val LIST_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu"
        const val JSON_LIST_PREFIX = "$LIST_PREFIX!"
        const val DOUBLE_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu"
    }

    private val prefs: SharedPreferences = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    private fun raw(key: String): Any? = prefs.all[PREFIX + key]

    override fun getString(key: String): String? = (raw(key) as? String)?.takeUnless {
        it.startsWith(LIST_PREFIX) || it.startsWith(DOUBLE_PREFIX)
    }

    override fun getLong(key: String): Long? = when (val v = raw(key)) {
        is Long -> v
        is Int -> v.toLong()
        else -> null
    }

    override fun getDouble(key: String): Double? = (raw(key) as? String)
        ?.takeIf { it.startsWith(DOUBLE_PREFIX) }?.removePrefix(DOUBLE_PREFIX)?.toDoubleOrNull()

    override fun getBool(key: String): Boolean? = raw(key) as? Boolean

    override fun getStringList(key: String): List<String>? {
        val v = raw(key) as? String ?: return null
        return when {
            v.startsWith(JSON_LIST_PREFIX) ->
                Json.parseToJsonElement(v.removePrefix(JSON_LIST_PREFIX)).jsonArray.map { it.jsonPrimitive.content }
            v.startsWith(LIST_PREFIX) -> runCatching {
                val bytes = android.util.Base64.decode(v.removePrefix(LIST_PREFIX), 0)
                @Suppress("UNCHECKED_CAST")
                ObjectInputStream(ByteArrayInputStream(bytes)).readObject() as List<String>
            }.getOrNull()
            else -> null
        }
    }

    private fun edit(block: SharedPreferences.Editor.() -> Unit) = prefs.edit().apply(block).apply()

    override fun setString(key: String, value: String) = edit { putString(PREFIX + key, value) }
    override fun setLong(key: String, value: Long) = edit { putLong(PREFIX + key, value) }
    override fun setDouble(key: String, value: Double) = edit { putString(PREFIX + key, DOUBLE_PREFIX + value.toString()) }
    override fun setBool(key: String, value: Boolean) = edit { putBoolean(PREFIX + key, value) }
    override fun setStringList(key: String, value: List<String>) =
        edit { putString(PREFIX + key, JSON_LIST_PREFIX + JsonArray(value.map { JsonPrimitive(it) }).toString()) }

    override fun remove(key: String) = edit { remove(PREFIX + key) }

    override fun keys(): Set<String> = prefs.all.keys.filter { it.startsWith(PREFIX) }.map { it.removePrefix(PREFIX) }.toSet()
}

/** Каталоги path_provider: documents = app_flutter, support = files, temp = cache. */
fun flutterAppDirs(context: Context) = AppDirs(
    documents = context.getDir("flutter", Context.MODE_PRIVATE),
    support = context.filesDir,
    temp = context.cacheDir,
)
