package com.oshinobu.app.call

import android.Manifest
import android.app.ActivityManager
import android.app.KeyguardManager
import android.app.NotificationManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.oshinobu.app.app

/**
 * Состояние телефона, от которого зависит звонок, — одной строкой для журнала
 * и отчёта о проблеме звонка: разрешения (уведомления, полноэкранный звонок,
 * поверх других приложений, микрофон), блокировка и экран, ограничения
 * батареи, «не беспокоить», связь с сервером. Без личных данных.
 */
object CallDiagnostics {
    fun snapshot(context: Context): String {
        val app = context.app
        val notifications = context.getSystemService(NotificationManager::class.java)
        val power = context.getSystemService(PowerManager::class.java)
        val keyguard = context.getSystemService(KeyguardManager::class.java)
        val audio = context.getSystemService(AudioManager::class.java)
        val parts = linkedMapOf<String, Any?>(
            "device" to "${Build.MANUFACTURER} ${Build.MODEL} Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})",
            "notifications" to NotificationManagerCompat.from(context).areNotificationsEnabled(),
            "ringChannel" to notifications.getNotificationChannel(CallRingService.CHANNEL_ID)?.importance.let { importanceName(it) },
            "fullScreenIntent" to if (Build.VERSION.SDK_INT >= 34) notifications.canUseFullScreenIntent() else "n/a",
            "overlay" to Settings.canDrawOverlays(context),
            "mic" to (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED),
            "locked" to keyguard.isKeyguardLocked,
            "screenOn" to power.isInteractive,
            "appForeground" to app.routerHost.isAppInForeground,
            "appLock" to app.core.appLock.state.value?.enabled,
            "batteryOptimized" to !power.isIgnoringBatteryOptimizations(context.packageName),
            "powerSave" to power.isPowerSaveMode,
            "backgroundRestricted" to if (Build.VERSION.SDK_INT >= 28) context.getSystemService(ActivityManager::class.java).isBackgroundRestricted else "n/a",
            "standbyBucket" to if (Build.VERSION.SDK_INT >= 28) context.getSystemService(UsageStatsManager::class.java).appStandbyBucket else "n/a",
            "dnd" to notifications.currentInterruptionFilter,
            "ringer" to audio.ringerMode,
            "ws" to app.core.ws.status.value,
        )
        return parts.entries.joinToString(" ") { "${it.key}=${it.value}" }
    }

    private fun importanceName(importance: Int?): String = when (importance) {
        null -> "missing"
        NotificationManager.IMPORTANCE_NONE -> "off"
        NotificationManager.IMPORTANCE_MIN -> "min"
        NotificationManager.IMPORTANCE_LOW -> "low"
        NotificationManager.IMPORTANCE_DEFAULT -> "default"
        NotificationManager.IMPORTANCE_HIGH -> "high"
        else -> importance.toString()
    }

    /**
     * Каким путём экран входящего должен был появиться при таком состоянии —
     * чтобы по отчёту сразу видеть, какое звено не сработало.
     */
    fun expectedIncomingPath(context: Context): String {
        val app = context.app
        val locked = context.getSystemService(KeyguardManager::class.java).isKeyguardLocked
        val screenOn = context.getSystemService(PowerManager::class.java).isInteractive
        return when {
            app.routerHost.isAppInForeground -> "in-app navigation (app on screen)"
            locked || !screenOn -> "full-screen intent (locked or screen off)"
            Settings.canDrawOverlays(context) -> "activity start over other apps (overlay granted)"
            else -> "heads-up notification only (unlocked, no overlay permission) — screen is not expected"
        }
    }
}
