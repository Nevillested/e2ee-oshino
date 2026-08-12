package com.oshinobu.call_ring_plugin

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/**
 * Обрабатывает "Завершить звонок" из уведомления "Идёт разговор" —
 * НАПРЯМУЮ дотягивается до живого движка главного приложения (см.
 * MainActivity.configureFlutterEngine, кладёт себя в FlutterEngineCache под
 * MAIN_ENGINE_ID) и зовёт его CallService.endCall(), а не поднимает свой
 * отдельный движок, как это сделал бы обычный action у
 * flutter_local_notifications (см. подробности в OngoingCallNotifier).
 *
 * Звонок может быть "идущим" (а значит, это уведомление вообще может
 * существовать) только пока живо приложение — аудио WebRTC физически не
 * может идти без работающего Flutter engine, поэтому движок в кэше
 * гарантированно должен быть на месте; null-ветка — просто подстраховка.
 */
class EndCallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.d(TAG, "onReceive: получено нажатие 'Завершить звонок', action=${intent.action}")
        // Гасим уведомление сразу и безусловно — даже если по какой-то
        // причине не получится достучаться до движка, висящая кнопка "жми
        // сколько угодно, ничего не происходит" хуже, чем просто пропавшее
        // уведомление.
        OngoingCallNotifier.hide(context)
        Log.d(TAG, "onReceive: уведомление 'Идёт разговор' скрыто")

        val cachedEngines = FlutterEngineCache.getInstance()
        val engine = cachedEngines.get(MAIN_ENGINE_ID)
        if (engine == null) {
            Log.e(
                TAG,
                "onReceive: живой движок '$MAIN_ENGINE_ID' НЕ найден в FlutterEngineCache — " +
                    "endCallRequested некому передать, звонок на этом устройстве НЕ завершится " +
                    "(должно быть невозможно, пока идёт звонок — приложение обязано быть живо)",
            )
            return
        }
        Log.d(TAG, "onReceive: движок найден ($engine), отправляю endCallRequested по каналу '$CHANNEL'")
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).invokeMethod(
            "endCallRequested",
            null,
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    Log.d(TAG, "onReceive: endCallRequested доставлен и обработан Dart-стороной")
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                    Log.e(TAG, "onReceive: endCallRequested провалился: $errorCode $errorMessage")
                }

                override fun notImplemented() {
                    Log.e(TAG, "onReceive: endCallRequested — Dart не слушает канал '$CHANNEL' (notImplemented)")
                }
            },
        )
    }

    companion object {
        private const val TAG = "EndCallReceiver"
        private const val CHANNEL = "oshinobu/call_ring"

        // Тот же ключ, что и MAIN_ENGINE_ID в MainActivity.kt (отдельный
        // Gradle-модуль, поэтому не общая константа).
        private const val MAIN_ENGINE_ID = "main_engine"
    }
}
