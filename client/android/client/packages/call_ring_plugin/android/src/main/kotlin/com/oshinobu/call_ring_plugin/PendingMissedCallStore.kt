package com.oshinobu.call_ring_plugin

import android.content.Context

/**
 * Один "отложенный пропущенный звонок" — на случай, если его отклонили
 * кнопкой в уведомлении, ПОКА приложение было полностью закрыто (нет
 * живого движка, см. CallDeclineReceiver). В этом сценарии некому сразу
 * записать звонок в локальную историю чата (это делает Dart-код,
 * ChatStore.addCallLog, а движка нет) — вместо этого здесь остаётся
 * маленькая заметка "от кого был звонок и когда", а при следующем
 * запуске приложение сама её заберёт (см. consumePendingMissedCall в
 * CallRingPlugin.kt) и допишет запись в историю.
 *
 * Хранится ровно один — если отклонить несколько звонков подряд, пока
 * приложение закрыто (маловероятный, но возможный случай), в истории
 * появится запись только про последний. Это сознательный компромисс ради
 * простоты — потерять один пропущенный звонок из истории заметно
 * безобиднее, чем городить очередь ради редкого края.
 */
object PendingMissedCallStore {
    private const val PREFS_NAME = "oshinobu_pending_missed_call"
    private const val KEY_CALLER_DEVICE_ID = "caller_device_id"
    private const val KEY_TIMESTAMP = "timestamp"

    fun save(context: Context, callerDeviceId: String, timestampMillis: Long) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_CALLER_DEVICE_ID, callerDeviceId)
            .putLong(KEY_TIMESTAMP, timestampMillis)
            .apply()
    }

    /** Читает и сразу стирает — однократно, как и consumeAutoAccept(). */
    fun consume(context: Context): Pair<String, Long>? {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val callerDeviceId = prefs.getString(KEY_CALLER_DEVICE_ID, null) ?: return null
        val timestamp = prefs.getLong(KEY_TIMESTAMP, 0L)
        prefs.edit().clear().apply()
        return callerDeviceId to timestamp
    }
}
