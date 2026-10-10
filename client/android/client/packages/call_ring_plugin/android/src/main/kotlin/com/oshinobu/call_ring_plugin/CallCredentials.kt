package com.oshinobu.call_ring_plugin

import android.content.Context

/**
 * Небольшой кэш токена сессии/device_id/адреса сервера в обычных
 * SharedPreferences. Нужен, чтобы кнопка "Отклонить" в уведомлении о
 * звонке могла сделать авторизованный запрос к серверу напрямую из
 * BroadcastReceiver, не поднимая Flutter-движок — а без движка обычное
 * хранилище сессии (flutter_secure_storage, Dart-side) нативному коду не
 * видно. Dart-сторона сама обновляет этот кэш при каждом подключении (см.
 * PushService) и очищает при выходе из аккаунта.
 *
 * Компромисс осознанный: токен дублируется в обычных (не keystore-шифрованных)
 * SharedPreferences этого приложения — они по-прежнему недоступны другим
 * приложениям (песочница Android), но не так надёжно защищены, как
 * flutter_secure_storage. Токен сессии живёт ограниченное время и не
 * является ключом шифрования переписки — цена за возможность мгновенного
 * отклика без открытия приложения.
 */
object CallCredentials {
    private const val PREFS_NAME = "oshinobu_call_credentials"
    private const val KEY_TOKEN = "token"
    private const val KEY_DEVICE_ID = "device_id"
    private const val KEY_BASE_URL = "base_url"

    data class Snapshot(val token: String, val deviceId: String, val baseUrl: String)

    fun save(context: Context, token: String, deviceId: String, baseUrl: String) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_TOKEN, token)
            .putString(KEY_DEVICE_ID, deviceId)
            .putString(KEY_BASE_URL, baseUrl)
            .apply()
    }

    fun clear(context: Context) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit().clear().apply()
    }

    fun read(context: Context): Snapshot? {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val token = prefs.getString(KEY_TOKEN, null) ?: return null
        val deviceId = prefs.getString(KEY_DEVICE_ID, null) ?: return null
        val baseUrl = prefs.getString(KEY_BASE_URL, null) ?: return null
        return Snapshot(token, deviceId, baseUrl)
    }
}
