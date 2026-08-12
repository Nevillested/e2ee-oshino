package com.oshinobu.call_ring_plugin

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Уведомление "Идёт разговор с <имя>" — собрано полностью нативно, а не
 * через flutter_local_notifications. Причина: у flutter_local_notifications
 * ЛЮБОЕ действие кнопки с showsUserInterface=false (как раз наш случай —
 * кнопка не должна открывать приложение) всегда обрабатывается через
 * ActionBroadcastReceiver, который поднимает СОВЕРШЕННО ОТДЕЛЬНЫЙ,
 * изолированный FlutterEngine (см. исходники плагина) — со своим пустым
 * CallService, никак не связанным с реальным идущим звонком в уже живом
 * приложении. Поэтому кнопка "Завершить звонок" молча ничего не делала:
 * вызывался endCall() у звонка-призрака в изоляте, которого никто не видит.
 *
 * Здесь вместо этого — своя нативная кнопка/интент, а обработчик
 * (EndCallReceiver) явно достаёт из FlutterEngineCache ИМЕННО живой
 * движок главной Activity и зовёт его напрямую.
 */
object OngoingCallNotifier {
    private const val TAG = "OngoingCallNotifier"
    private const val CHANNEL_ID = "ongoing_call"
    private const val CHANNEL_NAME = "Активный звонок"
    private const val NOTIFICATION_ID = 900

    // Тот же ключ, что и EXTRA_OPEN_CALL_SCREEN в MainActivity.kt (отдельный
    // Gradle-модуль, поэтому не общая константа).
    private const val EXTRA_OPEN_CALL_SCREEN = "oshinobu.OPEN_CALL_SCREEN"

    fun show(context: Context, peerLogin: String) {
        Log.d(TAG, "show: peerLogin=$peerLogin")
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW).apply {
                description = "Показывается, пока идёт разговор"
            }
            nm.createNotificationChannel(channel)
        }

        val contentIntent = (
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent().setClassName(context.packageName, "${context.packageName}.MainActivity")
        ).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EXTRA_OPEN_CALL_SCREEN, true)
        }
        val contentPendingIntent = PendingIntent.getActivity(
            context,
            0,
            contentIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val endCallPendingIntent = PendingIntent.getBroadcast(
            context,
            1,
            Intent(context, EndCallReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle("Oshinobu")
            .setContentText("Идёт разговор с $peerLogin")
            .setSmallIcon(context.applicationInfo.icon)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setAutoCancel(false)
            .setContentIntent(contentPendingIntent)
            .addAction(0, "Завершить звонок", endCallPendingIntent)
            .build()

        nm.notify(NOTIFICATION_ID, notification)
        Log.d(TAG, "show: уведомление id=$NOTIFICATION_ID показано")
    }

    fun hide(context: Context) {
        Log.d(TAG, "hide: скрываю уведомление id=$NOTIFICATION_ID")
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(NOTIFICATION_ID)
    }
}
