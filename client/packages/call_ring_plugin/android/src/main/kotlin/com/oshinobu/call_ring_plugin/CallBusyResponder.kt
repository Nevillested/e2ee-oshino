package com.oshinobu.call_ring_plugin

import android.content.Context
import android.util.Log
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * Авто-«занято» для второго параллельного звонка, пришедшего пока приложение
 * полностью закрыто (живого Dart-слоя нет, поэтому call_busy по WebSocket,
 * как это делает CallService в работающем приложении, послать некому).
 *
 * CallRingService уже крутит рингтон по первому звонку; когда push приносит
 * ВТОРОЙ звонок с другим call_id, мы не перебиваем текущий рингтон, а сразу
 * говорим второму звонящему «занят» тем же HTTP-путём, что и кнопка
 * «Отклонить» (POST /calls/decline), но с reason=busy — сервер тогда шлёт
 * звонящему call_busy вместо call_reject.
 *
 * Если сохранённых учётных данных нет (не залогинен / очищены) — молчим,
 * второй звонящий узнает об отказе по обычному TTL-таймауту.
 */
object CallBusyResponder {

    private const val TAG = "CallBusyResponder"
    private val EXECUTOR = Executors.newSingleThreadExecutor()

    fun sendBusy(context: Context, callId: String) {
        val creds = CallCredentials.read(context)
        if (creds == null) {
            Log.e(TAG, "sendBusy: нет учётных данных, второй звонящий узнает по таймауту")
            return
        }
        EXECUTOR.execute {
            try {
                post(creds, callId)
            } catch (e: Exception) {
                Log.e(TAG, "sendBusy: сетевой запрос не удался", e)
            }
        }
    }

    private fun post(creds: CallCredentials.Snapshot, callId: String) {
        val url = URL("${creds.baseUrl}/calls/decline")
        val connection = url.openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.connectTimeout = 5_000
            connection.readTimeout = 5_000
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Authorization", "Bearer ${creds.token}")

            val body = """{"device_id":"${creds.deviceId}","call_id":"$callId","reason":"busy"}"""
            OutputStreamWriter(connection.outputStream).use { it.write(body) }

            val code = connection.responseCode
            Log.d(TAG, "sendBusy: сервер ответил $code (call_id=$callId)")
        } finally {
            connection.disconnect()
        }
    }
}
