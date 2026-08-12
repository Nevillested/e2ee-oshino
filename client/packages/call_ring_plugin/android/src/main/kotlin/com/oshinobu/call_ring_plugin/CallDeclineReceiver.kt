package com.oshinobu.call_ring_plugin

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * Обрабатывает нажатие "Отклонить" прямо в уведомлении, без открытия
 * приложения. Гасит рингтон/уведомление на этом устройстве сразу же.
 *
 * Дальше — ДВА разных пути уведомить звонящего, в зависимости от того, жив
 * ли сейчас Flutter engine главного приложения:
 *
 * 1. Приложение ЖИВО (движок закэширован в FlutterEngineCache, см.
 *    MainActivity.configureFlutterEngine) — значит, звонок пришёл через уже
 *    подключённый WebSocket, а не через push. В этом случае никакой записи
 *    в серверном PendingCallRegistry НЕ существует (она заводится только
 *    для звонков, доставленных офлайн-путём через push, см.
 *    server/internal/api/pending_call.go) — HTTP-запрос на /calls/decline
 *    в этом случае находит "нечего отклонять" и молча отвечает 200 OK, а
 *    звонящий так и не узнаёт об отказе (именно этот баг здесь и чинится).
 *    Поэтому вместо HTTP просим ЖИВОЙ CallService самому позвать
 *    declineCall() — тот отправит call_reject через уже установленное
 *    соединение, что работает всегда, независимо от PendingCallRegistry.
 *
 * 2. Приложения нет в памяти (движка в кэше нет) — тогда звонок пришёл
 *    именно офлайн-путём через push, запись в PendingCallRegistry
 *    существует, и старый HTTP-путь (единственно возможный без движка)
 *    отрабатывает как и раньше.
 */
class CallDeclineReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        CallRingService.stop(context)

        val callId = intent.getStringExtra(CallRingService.EXTRA_CALL_ID)
        Log.d(TAG, "onReceive: decline, callId=$callId")

        val engine = FlutterEngineCache.getInstance().get(MAIN_ENGINE_ID)
        if (engine != null) {
            Log.d(TAG, "onReceive: живой движок найден ($engine) — прошу CallService самому отклонить звонок")
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).invokeMethod(
                "declineCallRequested",
                null,
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        Log.d(TAG, "onReceive: declineCallRequested доставлен и обработан Dart-стороной")
                    }

                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                        Log.e(TAG, "onReceive: declineCallRequested провалился: $errorCode $errorMessage")
                    }

                    override fun notImplemented() {
                        Log.e(TAG, "onReceive: declineCallRequested — Dart не слушает канал '$CHANNEL' (notImplemented)")
                    }
                },
            )
            return
        }

        Log.d(TAG, "onReceive: живого движка нет — отклоняю через HTTP (офлайн-путь, PendingCallRegistry)")
        if (callId == null) {
            Log.e(TAG, "decline: нет call_id, некого уведомлять")
            return
        }

        val creds = CallCredentials.read(context)
        if (creds == null) {
            Log.e(TAG, "decline: нет сохранённых учётных данных, звонящий узнает по таймауту")
            return
        }

        val pendingResult = goAsync()
        EXECUTOR.execute {
            try {
                sendDecline(creds, callId)
            } catch (e: Exception) {
                Log.e(TAG, "decline: сетевой запрос не удался", e)
            } finally {
                pendingResult.finish()
            }
        }
    }

    private fun sendDecline(creds: CallCredentials.Snapshot, callId: String) {
        val url = URL("${creds.baseUrl}/calls/decline")
        val connection = url.openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.connectTimeout = 5_000
            connection.readTimeout = 5_000
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Authorization", "Bearer ${creds.token}")

            val body = """{"device_id":"${creds.deviceId}","call_id":"$callId"}"""
            OutputStreamWriter(connection.outputStream).use { it.write(body) }

            val code = connection.responseCode
            Log.d(TAG, "decline: сервер ответил $code")
        } finally {
            connection.disconnect()
        }
    }

    companion object {
        private const val TAG = "CallDeclineReceiver"
        private const val CHANNEL = "oshinobu/call_ring"

        // Тот же ключ, что и MAIN_ENGINE_ID в MainActivity.kt (отдельный
        // Gradle-модуль, поэтому не общая константа).
        private const val MAIN_ENGINE_ID = "main_engine"

        private val EXECUTOR = Executors.newSingleThreadExecutor()
    }
}
