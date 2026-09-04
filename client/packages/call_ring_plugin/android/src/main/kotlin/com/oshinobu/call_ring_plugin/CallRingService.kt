package com.oshinobu.call_ring_plugin

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.Person

/**
 * Настоящий "звонок" в фоне/при полностью закрытом приложении — обычное
 * Android-уведомление физически не умеет ни зациклить рингтон, ни надёжно
 * поднять полноэкранный вызов поверх блокировки. Поэтому по push-у типа
 * "call" поднимается этот foreground-service: он сам крутит рингтон по
 * кругу и сам показывает full-screen intent уведомление — так же, как
 * обычная звонилка. Если никто не отреагировал — самостоятельно
 * останавливается через RING_TIMEOUT_MS (совпадает с TTL отложенного
 * звонка на сервере), чтобы не звонить и не держать foreground вечно.
 */
class CallRingService : Service() {

    private var mediaPlayer: MediaPlayer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var isRinging = false
    private var currentCallId: String? = null

    // Нужен только для того, чтобы при отклонении звонка из ПОЛНОСТЬЮ
    // закрытого приложения (см. CallDeclineReceiver, ветка без живого
    // движка) было о ком записать пропущенный звонок в локальную историю
    // чата — сама Dart-сторона в этот момент не поднята и ничего сама
    // сделать не может.
    private var currentCallerDeviceId: String? = null
    private val stopHandler = Handler(Looper.getMainLooper())
    private val stopRunnable = Runnable { stopSelf() }

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "onCreate, instance=$this")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand, isRinging=$isRinging, instance=$this")

        val incomingCallId = intent?.getStringExtra(EXTRA_CALL_ID)

        // Второй параллельный звонок, пока мы уже звоним по первому: живого
        // Dart-слоя нет (иначе call_busy по WebSocket послал бы сам
        // CallService), поэтому нативно говорим второму звонящему "занят" и
        // НЕ перебиваем текущий рингтон. startForeground обязателен — нас
        // подняли через startForegroundService.
        if (isRinging &&
            incomingCallId != null &&
            currentCallId != null &&
            incomingCallId != currentCallId
        ) {
            Log.d(TAG, "onStartCommand: второй звонок $incomingCallId поверх активного $currentCallId — авто-busy")
            startForeground(NOTIFICATION_ID, buildNotification(), foregroundServiceType())
            CallBusyResponder.sendBusy(applicationContext, incomingCallId)
            return START_NOT_STICKY
        }

        // Может прийти без call_id (например повторный вызов из другого
        // источника push) — тогда просто сохраняем уже известный.
        incomingCallId?.let { currentCallId = it }
        intent?.getStringExtra(EXTRA_CALLER_DEVICE_ID)?.let { currentCallerDeviceId = it }
        startForeground(NOTIFICATION_ID, buildNotification(), foregroundServiceType())

        // startRinging() может прийти повторно за один и тот же звонок —
        // например Android иногда доставляет один и тот же push и в живой
        // процесс (onMessage), и в фоновый обработчик одновременно. Не
        // должно обрывать уже играющий рингтон и запускать его заново.
        if (!isRinging) {
            isRinging = true
            startRingtone()
            acquireWakeLock()
        }

        stopHandler.removeCallbacks(stopRunnable)
        stopHandler.postDelayed(stopRunnable, RING_TIMEOUT_MS)

        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // По умолчанию ничего не делаем (не даём системе убить сервис
        // вместе с задачей) — но логируем, чтобы видеть, действительно ли
        // именно это происходит при "смахивании" приложения из недавних.
        Log.d(TAG, "onTaskRemoved")
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        Log.d(TAG, "onDestroy, instance=$this")
        isRinging = false
        currentCallId = null
        currentCallerDeviceId = null
        stopHandler.removeCallbacks(stopRunnable)
        mediaPlayer?.let {
            try {
                it.stop()
            } catch (_: Exception) {
            }
            it.release()
        }
        mediaPlayer = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?) = null

    private fun startRingtone() {
        // Звоним тем рингтоном, что выбран у пользователя в настройках
        // самого Android (Settings > Sound > Phone ringtone) — как и любая
        // обычная звонилка, а не своей "зашитой" мелодией. content://
        // settings/system/ringtone — это не файл конкретного трека, а
        // указатель, который система сама разрешает в АКТУАЛЬНО выбранный
        // пользователем рингтон (в т.ч. если он его потом сменит).
        try {
            val player = MediaPlayer()
            val systemRingtoneUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            if (systemRingtoneUri != null) {
                player.setDataSource(this, systemRingtoneUri)
            } else {
                setBundledRingtoneSource(player)
            }
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            player.isLooping = true
            player.setOnPreparedListener {
                Log.d(TAG, "ringtone prepared, starting playback")
                it.start()
            }
            player.setOnErrorListener { _, what, extra ->
                Log.e(TAG, "MediaPlayer error: what=$what extra=$extra")
                true
            }
            player.setOnCompletionListener {
                // Не должно случаться при isLooping=true — если сработало,
                // значит плеер сам решил остановиться (полезно для диагностики).
                Log.d(TAG, "ringtone onCompletion fired unexpectedly")
            }
            player.prepareAsync()
            mediaPlayer = player
            Log.d(TAG, "startRingtone: MediaPlayer created (system ringtone=${systemRingtoneUri != null}), preparing")
        } catch (e: Exception) {
            // Системный URI по какой-то причине не сыграл (редкий случай на
            // некоторых прошивках) — пробуем зашитый запасной звук вместо
            // того, чтобы звонок остался вообще без звука.
            Log.e(TAG, "startRingtone with system ringtone failed, falling back to bundled sound", e)
            startBundledRingtoneFallback()
        }
    }

    private fun setBundledRingtoneSource(player: MediaPlayer) {
        val afd = resources.openRawResourceFd(R.raw.incoming_call)
        player.setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
        afd.close()
    }

    private fun startBundledRingtoneFallback() {
        try {
            val player = MediaPlayer()
            setBundledRingtoneSource(player)
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            player.isLooping = true
            player.setOnPreparedListener { it.start() }
            player.setOnErrorListener { _, what, extra ->
                Log.e(TAG, "fallback MediaPlayer error: what=$what extra=$extra")
                true
            }
            player.prepareAsync()
            mediaPlayer = player
        } catch (e: Exception) {
            // Нет звука вообще — не должно ронять сам сервис/уведомление.
            Log.e(TAG, "startBundledRingtoneFallback failed", e)
        }
    }

    private fun acquireWakeLock() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "oshinobu:call_ring")
            wakeLock?.acquire(RING_TIMEOUT_MS + 5_000)
        } catch (_: Exception) {
        }
    }

    // "phoneCall" на Android 14+ требует полноценной интеграции с системным
    // Telecom API (роль диалера/ConnectionService) — этого у нас нет и не
    // планировалось. Сервис реально проигрывает рингтон по кругу, поэтому
    // честно (и без дополнительных прав) заявляем тип "mediaPlayback".
    private fun foregroundServiceType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
        } else {
            0
        }

    private fun buildNotification(): Notification {
        Log.d(TAG, "buildNotification: currentCallId=$currentCallId")
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ru = AppLocale.isRussian(this)
            val channel = NotificationChannel(
                CHANNEL_ID,
                if (ru) "Входящие звонки" else "Incoming calls",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = if (ru) {
                    "Уведомление о входящем звонке, даже если приложение закрыто"
                } else {
                    "Incoming call notification, even when the app is closed"
                }
                // Звук крутит сам сервис через MediaPlayer (по кругу) —
                // системный одноразовый звук канала тут не нужен.
                setSound(null, null)
            }
            nm.createNotificationChannel(channel)
        }

        val fullScreenPendingIntent = PendingIntent.getActivity(
            this,
            0,
            buildLaunchIntent(autoAccept = false),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        // "Ответить" — тот же запуск приложения, что и обычный тап, только
        // с пометкой для Dart-стороны сразу принять звонок, как только он
        // дойдёт, вместо повторного тапа уже на экране входящего вызова.
        val acceptLaunchIntent = buildLaunchIntent(autoAccept = true)
        Log.d(
            TAG,
            "buildNotification: acceptLaunchIntent flags=${acceptLaunchIntent.flags} " +
                "extras=${acceptLaunchIntent.extras?.keySet()?.joinToString()} " +
                "autoAccept=${acceptLaunchIntent.getBooleanExtra(EXTRA_AUTO_ACCEPT, false)}",
        )
        val acceptPendingIntent = PendingIntent.getActivity(
            this,
            1,
            acceptLaunchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        // "Отклонить" — НЕ открывает приложение вообще, просто гасит рингтон
        // локально и просит CallDeclineReceiver сообщить звонящему через
        // сервер (см. call_id ниже) — тот получает отбой мгновенно, а не
        // по TTL.
        val declineIntent = Intent(this, CallDeclineReceiver::class.java).apply {
            putExtra(EXTRA_CALL_ID, currentCallId)
            putExtra(EXTRA_CALLER_DEVICE_ID, currentCallerDeviceId)
        }
        val declinePendingIntent = PendingIntent.getBroadcast(
            this,
            2,
            declineIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        // CallStyle — официальный шаблон Android для входящего звонка:
        // помимо прочего, он даёт зелёную кнопку ответа и красную кнопку
        // отклонения "из коробки" (Android 12+; на более старых версиях
        // аккуратно откатится к обычным кнопкам без цвета).
        val person = Person.Builder().setName("Oshinobu").setImportant(true).build()

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Oshinobu")
            .setContentText(if (AppLocale.isRussian(this)) "Входящий звонок" else "Incoming call")
            .setSmallIcon(applicationInfo.icon)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setAutoCancel(false)
            .setFullScreenIntent(fullScreenPendingIntent, true)
            .setContentIntent(fullScreenPendingIntent)
            .setStyle(
                NotificationCompat.CallStyle.forIncomingCall(person, declinePendingIntent, acceptPendingIntent),
            )
            .build()
    }

    private fun buildLaunchIntent(autoAccept: Boolean): Intent =
        (packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent().setClassName(packageName, "$packageName.MainActivity"))
            .apply {
                // ВАЖНО: раньше здесь был ещё и FLAG_ACTIVITY_CLEAR_TOP. На части
                // устройств/версий Android это в сочетании с уже запущенной
                // Activity приводило не к onNewIntent() поверх уже живой
                // MainActivity (как рассчитывал launchMode="singleTop"), а к
                // полному пересозданию — новый onCreate(), новый Flutter engine,
                // новый Dart-изолят. В итоге CallService терял ВЕСЬ своё
                // состояние (звонок всё ещё "звонит", но _state уже не
                // incomingRinging) прямо в момент нажатия "Ответить", и
                // автопринятие тихо проваливалось. FLAG_ACTIVITY_SINGLE_TOP
                // добавлен явно (дублирует то, что уже даёт launchMode в
                // манифесте) — чтобы не полагаться только на манифест.
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                // MainActivity проверяет этот флаг и явно просит систему
                // показать себя ПОВЕРХ экрана блокировки — без него
                // fullScreenIntent лишь запускает Activity позади keyguard,
                // и она становится видна только после свайпа/разблокировки
                // вручную.
                putExtra(EXTRA_SHOW_OVER_LOCKSCREEN, true)
                if (autoAccept) putExtra(EXTRA_AUTO_ACCEPT, true)
            }

    companion object {
        private const val TAG = "CallRingService"
        private const val CHANNEL_ID = "call_ring_service"
        private const val NOTIFICATION_ID = 777
        private const val RING_TIMEOUT_MS = 45_000L

        // Тот же ключ, что и в MainActivity.kt (отдельный Gradle-модуль, не
        // общая константа).
        const val EXTRA_SHOW_OVER_LOCKSCREEN = "oshinobu.SHOW_OVER_LOCKSCREEN"
        const val EXTRA_AUTO_ACCEPT = "oshinobu.AUTO_ACCEPT_CALL"
        const val EXTRA_CALL_ID = "oshinobu.CALL_ID"
        const val EXTRA_CALLER_DEVICE_ID = "oshinobu.CALLER_DEVICE_ID"

        fun start(context: Context, callId: String?, callerDeviceId: String? = null) {
            Log.d(TAG, "start() requested, callId=$callId, callerDeviceId=$callerDeviceId")
            val intent = Intent(context, CallRingService::class.java).apply {
                if (callId != null) putExtra(EXTRA_CALL_ID, callId)
                if (callerDeviceId != null) putExtra(EXTRA_CALLER_DEVICE_ID, callerDeviceId)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            Log.d(TAG, "stop() requested")
            context.stopService(Intent(context, CallRingService::class.java))
        }
    }
}
