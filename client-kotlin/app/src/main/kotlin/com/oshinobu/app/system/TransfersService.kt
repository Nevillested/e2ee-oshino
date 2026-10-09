package com.oshinobu.app.system

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.oshinobu.app.MainActivity
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.core.OshinobuCore
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

/**
 * Foreground-сервис "передача файлов": сам ничего не качает, только не даёт
 * системе убить процесс, пока идёт ручное скачивание или выгрузка файла
 * (движок — в ядре). Смахнули приложение — сервис уходит вместе с ним,
 * недокачанное продолжится при следующем запуске.
 */
class TransfersService : Service() {
    companion object {
        private const val CHANNEL_ID = "media_downloads"
        private const val NOTIFICATION_ID = 47110
        private const val EXTRA_TEXT = "text"

        /** Включать/выключать сервис по состоянию очередей ядра. */
        fun follow(context: Context, core: OshinobuCore) {
            core.scope.launch {
                combine(core.downloads.downloadingManually, core.pendingSender.activeJobId) { down, upJob ->
                    val up = upJob != null
                    when {
                        down && up -> R.string.notification_downloadingAndUploadingFiles
                        up -> R.string.notification_uploadingFiles
                        down -> R.string.notification_downloadingFiles
                        else -> null
                    }
                }.distinctUntilChanged().collect { text ->
                    val intent = Intent(context, TransfersService::class.java)
                    if (text == null) {
                        context.stopService(intent)
                    } else {
                        runCatching { ContextCompat.startForegroundService(context, intent.putExtra(EXTRA_TEXT, context.app.localized().getString(text))) }
                            .onFailure { core.logger.log("TransfersService start failed: $it") }
                    }
                }
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val strings = app.localized()
        ensureChannel(strings)
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(intent?.getStringExtra(EXTRA_TEXT) ?: strings.getString(R.string.notification_transfersChannelName))
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(MainActivity.openAppIntent(this))
            .build()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun ensureChannel(strings: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val channel = NotificationChannel(CHANNEL_ID, strings.getString(R.string.notification_transfersChannelName), NotificationManager.IMPORTANCE_LOW)
        channel.description = strings.getString(R.string.notification_transfersChannelDescription)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }
}
