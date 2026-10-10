package com.oshinobu.app

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.SoundPool
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import com.oshinobu.core.service.RouterHost

/** Побочные эффекты входящих сообщений на Android: звук, уведомление, вибрация. */
class AndroidRouterHost(private val context: Context) : RouterHost {
    private companion object {
        const val MESSAGES_CHANNEL = "messages"
        const val MESSAGE_NOTIFICATION_ID = 0
    }

    /** Логин чата, открытого сейчас на экране — выставляет экран чата. */
    @Volatile
    override var openChatPeerLogin: String? = null

    override val isAppInForeground: Boolean
        get() = ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)

    private val sounds = SoundPool.Builder()
        .setMaxStreams(1)
        .setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build(),
        )
        .build()
    private val messageSound = sounds.load(context, R.raw.msg_sound, 1)

    override fun playMessageSound() {
        sounds.play(messageSound, 1f, 1f, 1, 0, 1f)
    }

    /** Общий текст без содержимого: само сообщение уведомление не раскрывает. */
    override fun showBackgroundMessageNotification() {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ensureMessagesChannel()
        val notification = NotificationCompat.Builder(context, MESSAGES_CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Oshinobu")
            .setContentText(context.app.localized().getString(R.string.push_newMessageBody))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(MainActivity.openAppIntent(context))
            .build()
        NotificationManagerCompat.from(context).notify(MESSAGE_NOTIFICATION_ID, notification)
    }

    private fun ensureMessagesChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = context.getSystemService(NotificationManager::class.java)
        val strings = context.app.localized()
        val channel = NotificationChannel(MESSAGES_CHANNEL, strings.getString(R.string.push_messagesChannelName), NotificationManager.IMPORTANCE_HIGH)
        channel.description = strings.getString(R.string.push_messagesChannelDescription)
        manager.createNotificationChannel(channel)
    }

    override fun vibrate() {
        val vibrator = if (Build.VERSION.SDK_INT >= 31) {
            context.getSystemService(VibratorManager::class.java).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        if (Build.VERSION.SDK_INT >= 26) {
            vibrator.vibrate(VibrationEffect.createOneShot(40, VibrationEffect.DEFAULT_AMPLITUDE))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(40)
        }
    }
}
