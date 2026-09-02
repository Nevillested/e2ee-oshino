package com.oshinobu.oshinobu_client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Тонкий foreground-сервис: НИЧЕГО сам не качает, только держит процесс
 * приложения живым, пока идёт скачивание файла, которое пользователь
 * запросил сам (см. MediaDownloadManager на Dart-стороне — сам движок
 * скачивания живёт в основном изоляте, этот сервис просто не даёт Android
 * убить процесс, пока приложение свёрнуто).
 *
 * НЕ переживает смахивание приложения из "недавних" (задача удаляется →
 * процесс и Dart-изолят убиваются вместе с ним; START_NOT_STICKY —
 * воскрешать сервис в одиночку смысла нет, качать станет некому). Докачка
 * с места обрыва при следующем запуске это подхватит (PartialDownloadStore).
 */
class MediaDownloadForegroundService : Service() {

    companion object {
        private const val TAG = "MediaDlFgs"
        private const val CHANNEL_ID = "media_downloads"
        private const val NOTIFICATION_ID = 47110

        const val ACTION_START = "com.oshinobu.oshinobu_client.media_dl.START"
        const val ACTION_STOP = "com.oshinobu.oshinobu_client.media_dl.STOP"
        const val EXTRA_TEXT = "text"
        const val EXTRA_CHANNEL_NAME = "channelName"
        const val EXTRA_CHANNEL_DESC = "channelDescription"

        fun start(
            context: Context,
            text: String,
            channelName: String,
            channelDescription: String,
        ) {
            val intent = Intent(context, MediaDownloadForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TEXT, text)
                putExtra(EXTRA_CHANNEL_NAME, channelName)
                putExtra(EXTRA_CHANNEL_DESC, channelDescription)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Например, ForegroundServiceStartNotAllowedException, если
                // система решила, что стартуем из фона. Не критично —
                // скачивание всё равно идёт в основном изоляте, просто без
                // гарантии, что процесс не убьют при сворачивании.
                Log.w(TAG, "не удалось запустить foreground-сервис скачивания: $e")
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, MediaDownloadForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            try {
                context.startService(intent)
            } catch (e: Exception) {
                Log.w(TAG, "не удалось остановить foreground-сервис скачивания: $e")
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        // Тексты всегда приходят с Dart-стороны уже локализованными
        // (см. MediaDownloadForeground) — фолбэки тут только на случай
        // отсутствия extra, до пользователя доходить не должны.
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "File transfers"
        val channelName = intent?.getStringExtra(EXTRA_CHANNEL_NAME) ?: "File transfers"
        val channelDescription = intent?.getStringExtra(EXTRA_CHANNEL_DESC) ?: ""
        ensureChannel(channelName, channelDescription)
        val notification = buildNotification(text)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.w(TAG, "startForeground не удался: $e")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun buildNotification(text: String): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = launch?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .apply { if (contentIntent != null) setContentIntent(contentIntent) }
            .build()
    }

    private fun ensureChannel(name: String, description: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // createNotificationChannel с тем же ID обновляет имя/описание —
        // так канал в системных настройках переедет на язык, выбранный в
        // приложении, если пользователь его сменит.
        val channel = NotificationChannel(
            CHANNEL_ID,
            name,
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            setShowBadge(false)
            if (description.isNotEmpty()) this.description = description
        }
        mgr.createNotificationChannel(channel)
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    override fun onDestroy() {
        stopForegroundCompat()
        super.onDestroy()
    }
}
