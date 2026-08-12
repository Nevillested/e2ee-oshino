package com.oshinobu.call_ring_plugin

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Мост Dart -> нативный CallRingService. Специально зарегистрирован как
 * настоящий Flutter-плагин (а не ad-hoc MethodChannel в MainActivity),
 * потому что именно так его подхватывает GeneratedPluginRegistrant в
 * ФОНОВОМ движке firebase_messaging — том самом, что поднимается, когда
 * push приходит при полностью закрытом приложении. Обычный канал,
 * зарегистрированный только в MainActivity, там был бы недоступен.
 */
class CallRingPlugin :
    FlutterPlugin,
    MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "oshinobu/call_ring")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "startRinging" -> {
                val callId = call.argument<String>("callId")
                val callerDeviceId = call.argument<String>("callerDeviceId")
                Log.d(TAG, "startRinging() called, callId=$callId, callerDeviceId=$callerDeviceId")
                CallRingService.start(appContext, callId, callerDeviceId)
                result.success(null)
            }
            "stopRinging" -> {
                Log.d(TAG, "stopRinging() called")
                CallRingService.stop(appContext)
                result.success(null)
            }
            "ensureFullScreenIntentPermission" -> {
                ensureFullScreenIntentPermission()
                result.success(null)
            }
            "cacheCredentials" -> {
                val token = call.argument<String>("token")
                val deviceId = call.argument<String>("deviceId")
                val baseUrl = call.argument<String>("baseUrl")
                if (token != null && deviceId != null && baseUrl != null) {
                    CallCredentials.save(appContext, token, deviceId, baseUrl)
                }
                result.success(null)
            }
            "clearCredentials" -> {
                CallCredentials.clear(appContext)
                result.success(null)
            }
            "showOngoingCall" -> {
                val peerLogin = call.argument<String>("peerLogin") ?: "собеседником"
                Log.d(TAG, "showOngoingCall() called, peerLogin=$peerLogin")
                // Через foreground-сервис, а не прямой notify() — иначе
                // процесс ничем не защищён от смахивания задачи из
                // "недавних" во время разговора (см. OngoingCallService).
                OngoingCallService.start(appContext, peerLogin)
                result.success(null)
            }
            "hideOngoingCall" -> {
                Log.d(TAG, "hideOngoingCall() called")
                OngoingCallService.stop(appContext)
                result.success(null)
            }
            "consumePendingMissedCall" -> {
                // Читаем и сразу стираем — см. PendingMissedCallStore. Пусто,
                // если ничего не отклоняли, пока приложение было закрыто.
                val pending = PendingMissedCallStore.consume(appContext)
                Log.d(TAG, "consumePendingMissedCall() -> $pending")
                if (pending != null) {
                    val (callerDeviceId, timestamp) = pending
                    result.success(mapOf("callerDeviceId" to callerDeviceId, "timestamp" to timestamp))
                } else {
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    /**
     * На Android 14+ USE_FULL_SCREEN_INTENT — не обычное manifest-разрешение,
     * а отзываемое системой "специальное" разрешение: даже объявленное в
     * манифесте, оно может быть выключено по умолчанию, и тогда
     * setFullScreenIntent() в уведомлении просто молча игнорируется (вместо
     * полноэкранного звонка — обычный тихий пункт в шторке). Программно
     * включить его нельзя — можно только открыть системный экран настроек,
     * где пользователь включает его сам.
     */
    private fun ensureFullScreenIntentPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
        val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.canUseFullScreenIntent()) {
            Log.d(TAG, "full-screen intent permission already granted")
            return
        }
        Log.d(TAG, "full-screen intent permission NOT granted, opening settings")
        try {
            val intent = Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
                data = Uri.parse("package:${appContext.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            appContext.startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "failed to open full-screen intent settings", e)
        }
    }

    companion object {
        private const val TAG = "CallRingPlugin"
    }
}
