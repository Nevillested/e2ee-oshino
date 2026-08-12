package com.oshinobu.call_ring_plugin

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log

/**
 * Foreground-сервис на всё время СОЕДИНЁННОГО разговора (не только пока
 * идёт рингтон — тем уже занимается CallRingService).
 *
 * Зачем: без активного foreground-сервиса Android не даёт процессу
 * приложения никакой защиты при закрытии его задачи из "недавних" —
 * система просто убивает процесс целиком, как обычное свёрнутое
 * приложение. Раньше во время уже ПРИНЯТОГО звонка никакого
 * foreground-сервиса не было (CallRingService останавливается сразу
 * после ответа — он был нужен только для рингтона), поэтому смахивание
 * задачи реально обрывало разговор: пропадал звук, хотя ни собеседник,
 * ни пользователь звонок не завершали.
 *
 * С этим сервисом процесс переживает смахивание — ровно так же, как
 * переживают его звонилки и плееры музыки, для которых foreground-сервис
 * с "вечным" уведомлением и есть официальный, документированный Android
 * механизм. Второй кусок той же задачи — чтобы Flutter-движок (а с ним
 * CallService/WebRTC) тоже не уничтожался вместе с Activity при этом же
 * смахивании — см. MainActivity.provideFlutterEngine/shouldDestroyEngineWithHost.
 *
 * Уведомление "Идёт разговор" и кнопка "Завершить звонок" — те же, что
 * строит OngoingCallNotifier; сервис просто передаёт их в startForeground()
 * вместо прямого NotificationManager.notify().
 */
class OngoingCallService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val peerLogin = intent?.getStringExtra(EXTRA_PEER_LOGIN) ?: "собеседником"
        Log.d(TAG, "onStartCommand: peerLogin=$peerLogin")

        val notification = OngoingCallNotifier.buildNotification(this, peerLogin)
        // startForeground(id, notification, type) — трёхаргументная версия
        // с типом сервиса появилась только в API 29; на более старых
        // устройствах такого метода в самой ОС физически нет (упало бы с
        // NoSuchMethodError), поэтому там — старая двухаргументная версия.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(OngoingCallNotifier.NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(OngoingCallNotifier.NOTIFICATION_ID, notification)
        }

        return START_NOT_STICKY
    }

    override fun onDestroy() {
        Log.d(TAG, "onDestroy")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?) = null

    companion object {
        private const val TAG = "OngoingCallService"
        private const val EXTRA_PEER_LOGIN = "oshinobu.PEER_LOGIN"

        fun start(context: Context, peerLogin: String) {
            Log.d(TAG, "start() requested, peerLogin=$peerLogin")
            val intent = Intent(context, OngoingCallService::class.java).apply {
                putExtra(EXTRA_PEER_LOGIN, peerLogin)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            Log.d(TAG, "stop() requested")
            context.stopService(Intent(context, OngoingCallService::class.java))
        }
    }
}
