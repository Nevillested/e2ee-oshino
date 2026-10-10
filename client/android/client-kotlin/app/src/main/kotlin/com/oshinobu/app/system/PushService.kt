package com.oshinobu.app.system

import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.oshinobu.app.app
import com.oshinobu.app.call.CallRingService
import com.oshinobu.core.OshinobuCore
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * Пуши FCM. Сервер шлёт только "разбудить": тип и служебные id, без
 * содержимого. "message" при свёрнутом приложении — общее уведомление
 * (само сообщение придёт по WebSocket при открытии); "call" — звонок
 * поверх всего, "call_cancel" — звонящий передумал.
 */
class PushService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        val core = app.core
        core.scope.launch { core.registerPushToken(token) }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val core = app.core
        core.logger.log("Push received type=${message.data["type"]}")
        when (message.data["type"]) {
            "message" -> if (!app.routerHost.isAppInForeground) app.routerHost.showBackgroundMessageNotification()
            // звонок, пока приложение не на связи: звоним сами; сам offer придёт по WebSocket после подключения
            "call" -> CallRingService.start(this, message.data["call_id"], message.data["caller_device_id"])
            "call_cancel" -> CallRingService.stop(this)
        }
    }

    companion object {
        /** Каждый запуск сессии — отдать серверу актуальный токен этого устройства. */
        fun registerOnSessionStart(core: OshinobuCore) {
            core.scope.launch {
                core.sessionActive.filter { it }.collect {
                    val token = currentToken() ?: return@collect
                    core.logger.log("Push token registered: ${core.registerPushToken(token)}")
                }
            }
        }

        private suspend fun currentToken(): String? = suspendCancellableCoroutine { cont ->
            FirebaseMessaging.getInstance().token
                .addOnSuccessListener { cont.resume(it) }
                .addOnFailureListener { cont.resume(null) }
        }
    }
}
