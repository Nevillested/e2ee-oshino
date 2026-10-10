package com.oshinobu.app

import android.Manifest
import android.app.KeyguardManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.Rational
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.oshinobu.app.call.CallIntents
import com.oshinobu.app.ui.AppNavigation
import com.oshinobu.app.ui.call.CallWindow
import com.oshinobu.app.ui.call.PipCallView
import com.oshinobu.app.ui.lock.AppLockGate
import com.oshinobu.app.ui.theme.OshinobuTheme
import com.oshinobu.app.ui.update.UpdateGate
import com.oshinobu.core.service.CallState
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * Единственная Activity; всё приложение — Compose-навигация внутри неё.
 * Для звонков: показ поверх блокировки (открыли из уведомления звонка),
 * "картинка в картинке" при видео собеседника, запросы открыть экран звонка.
 */
class MainActivity : AppCompatActivity(), CallWindow {
    private var inPip by mutableStateOf(false)

    /** Открыть экран звонка (уведомление "идёт разговор", раскрытие окошка PiP). */
    private val callScreenRequests = MutableSharedFlow<Unit>(extraBufferCapacity = 4)

    /** Приложение открыли из лаунчера, пока оно было в окошке PiP, — экран звонка не навязываем. */
    private var launcherReopen = false

    /** Окно приложения на экране (между onStart и onStop). */
    private var visible = false

    /** Разблокировали телефон, пока приложение на экране (например, поверх блокировки шёл звонок). */
    private val unlockReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = reportPresence()
    }

    override fun onStart() {
        super.onStart()
        visible = true
        ContextCompat.registerReceiver(this, unlockReceiver, IntentFilter(Intent.ACTION_USER_PRESENT), ContextCompat.RECEIVER_NOT_EXPORTED)
        reportPresence()
    }

    override fun onStop() {
        super.onStop()
        visible = false
        runCatching { unregisterReceiver(unlockReceiver) }
        reportPresence()
    }

    /**
     * "В сети" — только пока человек видит приложение: окно на экране (любой
     * экран приложения) и телефон разблокирован. Экран звонка, который
     * включился поверх блокировки, пуш, фоновая работа — не "видел". Ушло с
     * экрана — сервер с этого момента считает "был(а) в сети".
     */
    private fun reportPresence() {
        val seen = visible && !getSystemService(KeyguardManager::class.java).isKeyguardLocked
        app.core.ws.sendForegroundState(seen)
        // человек смотрит в приложение — уведомления о новых сообщениях уже ни к чему
        if (seen) NotificationManagerCompat.from(this).cancelAll()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        handleCallIntent(intent)
        setContent {
            val dark by app.darkTheme.collectAsState()
            val textScale by app.textScale.collectAsState()
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, density.fontScale * textScale.toFloat())) {
                OshinobuTheme(dark = dark) {
                    if (inPip) PipCallView() else UpdateGate { AppLockGate { AppNavigation(callScreenRequests) } }
                }
            }
        }
        lifecycleScope.launch { app.calls.pipAllowed.collect(::updatePipParams) }
        lifecycleScope.launch {
            app.core.calls.state.collect { if (it == CallState.IDLE) onCallEnded() }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val ownIntent = intent.hasExtra(CallIntents.EXTRA_AUTO_ACCEPT) || intent.hasExtra(CallIntents.EXTRA_OPEN_CALL_SCREEN)
        if (intent.action == Intent.ACTION_MAIN && intent.hasCategory(Intent.CATEGORY_LAUNCHER) && !ownIntent) launcherReopen = true
        handleCallIntent(intent)
    }

    private fun handleCallIntent(intent: Intent?) {
        intent ?: return
        if (intent.getBooleanExtra(CallIntents.EXTRA_SHOW_OVER_LOCKSCREEN, false)) setShowOverLockscreen(true)
        if (intent.getBooleanExtra(CallIntents.EXTRA_AUTO_ACCEPT, false)) {
            intent.removeExtra(CallIntents.EXTRA_AUTO_ACCEPT)
            // без микрофона принять нельзя — тогда звонок придёт обычным входящим, где спросим разрешение
            val micGranted = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
            if (micGranted) lifecycleScope.launch { app.core.calls.requestAutoAccept() }
        }
        if (intent.getBooleanExtra(CallIntents.EXTRA_OPEN_CALL_SCREEN, false)) {
            intent.removeExtra(CallIntents.EXTRA_OPEN_CALL_SCREEN)
            callScreenRequests.tryEmit(Unit)
        }
    }

    private fun setShowOverLockscreen(show: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(show)
            setTurnScreenOn(show)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (show) window.addFlags(flags) else window.clearFlags(flags)
        }
    }

    /** Звонок закончился: больше не поверх блокировки; окошко PiP — обратно в обычное окно. */
    private fun onCallEnded() {
        setShowOverLockscreen(false)
        if (inPip) startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP))
    }

    private fun pipParams(autoEnter: Boolean): PictureInPictureParams? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val builder = PictureInPictureParams.Builder().setAspectRatio(Rational(9, 16))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) builder.setAutoEnterEnabled(autoEnter)
        return builder.build()
    }

    private fun updatePipParams(allowed: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) pipParams(allowed)?.let(::setPictureInPictureParams)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // до Android 12 автоматического входа в PiP нет — входим сами при уходе на домашний экран
        if (app.calls.pipAllowed.value && Build.VERSION.SDK_INT in Build.VERSION_CODES.O until Build.VERSION_CODES.S) enterCallPip()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        inPip = isInPictureInPictureMode
        if (!isInPictureInPictureMode && !launcherReopen && app.core.calls.state.value != CallState.IDLE) callScreenRequests.tryEmit(Unit)
        launcherReopen = false
    }

    override fun enterCallPip() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) pipParams(app.calls.pipAllowed.value)?.let(::enterPictureInPictureMode)
    }

    override suspend fun unlockIfLocked(): Boolean {
        val keyguard = getSystemService(KeyguardManager::class.java)
        if (!keyguard.isKeyguardLocked) return true
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return suspendCancellableCoroutine { cont ->
            keyguard.requestDismissKeyguard(
                this,
                object : KeyguardManager.KeyguardDismissCallback() {
                    override fun onDismissSucceeded() {
                        setShowOverLockscreen(false)
                        cont.resume(true)
                    }
                    override fun onDismissCancelled() = cont.resume(false)
                    override fun onDismissError() = cont.resume(false)
                },
            )
        }
    }

    companion object {
        /** Открыть приложение из уведомления. */
        fun openAppIntent(context: Context): PendingIntent = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}
