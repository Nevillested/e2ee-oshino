package com.oshinobu.app.call

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import com.oshinobu.app.MainActivity
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.system.ForegroundGate
import com.oshinobu.core.service.CallState
import kotlinx.coroutines.launch

/** Что просит открывшаяся по уведомлению Activity. */
object CallIntents {
    const val EXTRA_SHOW_OVER_LOCKSCREEN = "oshinobu.SHOW_OVER_LOCKSCREEN"
    const val EXTRA_AUTO_ACCEPT = "oshinobu.AUTO_ACCEPT_CALL"
    const val EXTRA_OPEN_CALL_SCREEN = "oshinobu.OPEN_CALL_SCREEN"

    fun activity(context: Context, requestCode: Int, configure: Intent.() -> Unit): PendingIntent = PendingIntent.getActivity(
        context,
        requestCode,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP).apply(configure),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}

private fun Context.callIcon() = R.drawable.ic_notification

/**
 * Входящий звонок "как у звонилки": рингтон по кругу (или вибрация — по
 * режиму звонка телефона), полноэкранное уведомление поверх блокировки с
 * кнопками "ответить"/"отклонить". Поднимается и пушем при закрытом
 * приложении, и при звонке в открытом. Никто не ответил за 2 мин — сам
 * останавливается (столько же сервер держит отложенный звонок).
 *
 * На разблокированном телефоне Android показывает полноэкранное уведомление
 * лишь плашкой; с разрешением "поверх других приложений" экран входящего
 * открываем сами (как Telegram).
 */
class CallRingService : Service() {
    companion object {
        private const val CHANNEL_ID = "call_ring_service"
        private const val NOTIFICATION_ID = 777
        private const val RING_TIMEOUT_MS = 120_000L
        const val EXTRA_CALL_ID = "oshinobu.CALL_ID"
        const val EXTRA_CALLER_DEVICE_ID = "oshinobu.CALLER_DEVICE_ID"

        private val gate = ForegroundGate(CallRingService::class.java)

        fun start(context: Context, callId: String?, callerDeviceId: String?) {
            val intent = Intent(context, CallRingService::class.java)
                .putExtra(EXTRA_CALL_ID, callId)
                .putExtra(EXTRA_CALLER_DEVICE_ID, callerDeviceId)
            if (!gate.start(context, intent)) context.app.core.logger.log("CallRingService start not allowed")
        }

        fun stop(context: Context) = gate.stop(context)
    }

    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var callId: String? = null
    private var callerDeviceId: String? = null
    private val stopHandler = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val incomingId = intent?.getStringExtra(EXTRA_CALL_ID)
        val ringing = callId != null
        if (ringing && incomingId != null && incomingId != callId) {
            // второй звонок поверх звонящего — сразу "занято"
            if (!enterForeground()) return START_NOT_STICKY
            declineOnServer(this, incomingId, busy = true)
            return START_NOT_STICKY
        }
        incomingId?.let { callId = it }
        intent?.getStringExtra(EXTRA_CALLER_DEVICE_ID)?.let { callerDeviceId = it }
        // звонок уже отменили/приняли, пока служба поднималась — показала уведомление (так требует Android) и ушла
        if (!enterForeground()) return START_NOT_STICKY
        if (!ringing) {
            showIncomingScreen()
            startAlerting()
            wakeLock = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "oshinobu:call_ring")
                .apply { acquire(RING_TIMEOUT_MS + 5_000) }
        }
        stopHandler.removeCallbacksAndMessages(null)
        stopHandler.postDelayed({ stopSelf() }, RING_TIMEOUT_MS)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        gate.onDestroy()
        stopHandler.removeCallbacksAndMessages(null)
        player?.release()
        player = null
        vibrator?.cancel()
        vibrator = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        callId = null
        super.onDestroy()
    }

    /** Приложение не на экране, а показывать поверх других разрешено — открываем экран входящего сразу. */
    private fun showIncomingScreen() {
        if (app.routerHost.isAppInForeground || !Settings.canDrawOverlays(this)) return
        runCatching {
            startActivity(
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    .putExtra(CallIntents.EXTRA_SHOW_OVER_LOCKSCREEN, true),
            )
        }.onFailure { app.core.logger.log("CallRingService incoming screen failed: $it") }
    }

    /** На передний план; false — остановку уже попросили, служба уходит. */
    private fun enterForeground(): Boolean {
        startForeground()
        if (!gate.onForeground()) return true
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        return false
    }

    private fun startForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    /** Режим звонка телефона: без звука — молчим, вибрация — только она, иначе — мелодия. */
    private fun startAlerting() {
        when (getSystemService(AudioManager::class.java).ringerMode) {
            AudioManager.RINGER_MODE_SILENT -> Unit
            AudioManager.RINGER_MODE_VIBRATE -> startVibration()
            else -> startRingtone()
        }
    }

    private fun startVibration() {
        val vib = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            getSystemService(VibratorManager::class.java).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Vibrator::class.java)
        }
        val pattern = longArrayOf(0, 800, 800)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) vib.vibrate(VibrationEffect.createWaveform(pattern, 0))
        else @Suppress("DEPRECATION") vib.vibrate(pattern, 0)
        vibrator = vib
    }

    /** Системная мелодия звонка; не вышло — своя. */
    private fun startRingtone() {
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        fun prepare(source: MediaPlayer.() -> Unit): MediaPlayer = MediaPlayer().apply {
            setAudioAttributes(attributes)
            source()
            isLooping = true
            setOnPreparedListener { it.start() }
            setOnErrorListener { _, _, _ -> true }
            prepareAsync()
        }
        player = runCatching {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE) ?: error("нет системной мелодии")
            prepare { setDataSource(this@CallRingService, uri) }
        }.getOrElse {
            runCatching {
                prepare {
                    val afd = resources.openRawResourceFd(R.raw.ringtone)
                    setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
                    afd.close()
                }
            }.getOrNull()
        }
    }

    private fun buildNotification(): Notification {
        val strings = app.localized()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, strings.getString(R.string.call_incomingChannelName), NotificationManager.IMPORTANCE_HIGH).apply {
                description = strings.getString(R.string.call_incomingChannelDescription)
                setSound(null, null)
                enableVibration(false)
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
        val fullScreen = CallIntents.activity(this, 10) { putExtra(CallIntents.EXTRA_SHOW_OVER_LOCKSCREEN, true) }
        val accept = CallIntents.activity(this, 11) {
            putExtra(CallIntents.EXTRA_SHOW_OVER_LOCKSCREEN, true)
            putExtra(CallIntents.EXTRA_AUTO_ACCEPT, true)
        }
        val decline = CallActionReceiver.intent(this, CallActionReceiver.ACTION_DECLINE, callId, callerDeviceId)
        val person = Person.Builder().setName("Oshinobu").setImportant(true).build()
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Oshinobu")
            .setContentText(strings.getString(R.string.call_incoming))
            .setSmallIcon(callIcon())
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setFullScreenIntent(fullScreen, true)
            .setContentIntent(fullScreen)
            .setStyle(NotificationCompat.CallStyle.forIncomingCall(person, decline, accept))
            .build()
    }
}

/**
 * Уведомление "идёт разговор" (foreground-сервис микрофона — чтобы звонок не
 * обрывался в фоне): тап — экран звонка, кнопка — завершить.
 */
class OngoingCallService : Service() {
    companion object {
        private const val CHANNEL_ID = "ongoing_call"
        private const val NOTIFICATION_ID = 900
        private const val EXTRA_PEER_NAME = "oshinobu.PEER_NAME"

        private val gate = ForegroundGate(OngoingCallService::class.java)

        fun start(context: Context, peerName: String?) {
            val intent = Intent(context, OngoingCallService::class.java).putExtra(EXTRA_PEER_NAME, peerName)
            if (!gate.start(context, intent)) context.app.core.logger.log("OngoingCallService start not allowed")
        }

        fun stop(context: Context) = gate.stop(context)
    }

    override fun onDestroy() {
        gate.onDestroy()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val strings = app.localized()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, strings.getString(R.string.call_ongoingChannelName), NotificationManager.IMPORTANCE_LOW)
            channel.description = strings.getString(R.string.call_ongoingChannelDescription)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
        val peer = intent?.getStringExtra(EXTRA_PEER_NAME) ?: strings.getString(R.string.call_otherParty)
        val open = CallIntents.activity(this, 20) { putExtra(CallIntents.EXTRA_OPEN_CALL_SCREEN, true) }
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Oshinobu")
            .setContentText(strings.getString(R.string.call_ongoingWith, peer))
            .setSmallIcon(callIcon())
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(0, strings.getString(R.string.call_endAction), CallActionReceiver.intent(this, CallActionReceiver.ACTION_END, null, null))
            .build()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            app.core.logger.error("OngoingCallService startForeground failed: $e")
            stopSelf()
            return START_NOT_STICKY
        }
        // разговор уже закончился, пока служба поднималась — уведомление показано (так требует Android), уходим
        if (gate.onForeground()) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
        return START_NOT_STICKY
    }
}

/**
 * Кнопки уведомлений звонка. "Отклонить": если приложение на связи и звонок
 * уже пришёл — обычный call_reject; иначе — через сервер (/calls/decline) и
 * запись о пропущенном звонке. "Завершить" — конец разговора.
 */
class CallActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_DECLINE = "com.oshinobu.app.call.DECLINE"
        const val ACTION_END = "com.oshinobu.app.call.END"

        fun intent(context: Context, action: String, callId: String?, callerDeviceId: String?): PendingIntent = PendingIntent.getBroadcast(
            context,
            if (action == ACTION_DECLINE) 30 else 31,
            Intent(context, CallActionReceiver::class.java).setAction(action)
                .putExtra(CallRingService.EXTRA_CALL_ID, callId)
                .putExtra(CallRingService.EXTRA_CALLER_DEVICE_ID, callerDeviceId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    override fun onReceive(context: Context, intent: Intent) {
        val core = context.app.core
        val pending = goAsync()
        core.scope.launch {
            try {
                when (intent.action) {
                    ACTION_DECLINE -> {
                        CallRingService.stop(context)
                        if (core.calls.state.value == CallState.INCOMING_RINGING) {
                            core.calls.declineCall()
                        } else {
                            val callId = intent.getStringExtra(CallRingService.EXTRA_CALL_ID)
                            if (callId != null) declineOnServer(context, callId, busy = false)
                            intent.getStringExtra(CallRingService.EXTRA_CALLER_DEVICE_ID)?.let { recordMissedCall(context, it) }
                        }
                    }
                    ACTION_END -> {
                        OngoingCallService.stop(context)
                        core.calls.endCall()
                    }
                }
            } finally {
                pending.finish()
            }
        }
    }

    /** Звонок отклонён, пока приложение было не на связи, — всё равно записать его в чат. */
    private suspend fun recordMissedCall(context: Context, callerDeviceId: String) {
        val core = context.app.core
        val token = core.session.token ?: return
        val owner = core.api.getDeviceOwnerInfo(token, callerDeviceId) ?: return
        core.chats.addCallLog(owner.login, "incoming", "missed", System.currentTimeMillis(), accountId = owner.accountId)
    }
}

/** Отклонить через сервер звонок, который он держит до подключения этого устройства. */
private fun declineOnServer(context: Context, callId: String, busy: Boolean) {
    val core = context.app.core
    core.scope.launch {
        val token = core.session.token ?: return@launch
        val deviceId = core.keys.deviceId() ?: return@launch
        core.logger.log("Call decline via server callId=$callId busy=$busy -> ${core.api.declineCall(token, deviceId, callId, busy)}")
    }
}
