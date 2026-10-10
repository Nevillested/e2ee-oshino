package com.oshinobu.core.service

import com.oshinobu.core.net.ApiClient
import com.oshinobu.core.net.ApiException
import com.oshinobu.core.optString
import com.oshinobu.core.protocol.InnerMessage
import com.oshinobu.core.storage.ChatStore
import com.oshinobu.core.storage.ChatSummary
import com.oshinobu.core.storage.Session
import kotlinx.coroutines.CancellationException

/**
 * Действия над чатом целиком — из списка чатов и из меню чата: мьют,
 * блокировка, очистка истории и удаление чата (у себя или у обоих).
 */
class ChatActions(
    private val api: ApiClient,
    private val session: Session,
    private val chats: ChatStore,
    private val messenger: PeerMessenger,
    private val router: MessageRouter,
    private val cleanup: MessageCleanup,
    /**
     * Сам заблокировал/разблокировал — сверить блокировки с сервером: событие
     * block_status_changed сервер шлёт только другой стороне, а скрытое/открытое
     * блокировкой (фото, профиль) надо перезапросить и у себя.
     */
    private val onBlockChanged: suspend () -> Unit = {},
) {
    /** Мьют локально сразу; сервер (глушит пуши) — по возможности, без отката. */
    suspend fun setMuted(chat: ChatSummary, muted: Boolean) {
        chats.setChatMuted(chat.peerLogin, muted)
        val accountId = chat.lastKnownAccountId ?: return
        val token = session.token ?: return
        try {
            if (muted) api.muteChat(token, accountId) else api.unmuteChat(token, accountId)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // пуши ещё придут, но в приложении чат уже беззвучный — как во Flutter
        }
    }

    /**
     * Блокировка действует на сервере (он не пропускает сообщения и звонки),
     * поэтому при ошибке локальная отметка откатывается и бросается [ApiException].
     */
    suspend fun setBlocked(chat: ChatSummary, blocked: Boolean) {
        chats.setChatBlockedByMe(chat.peerLogin, blocked)
        try {
            val accountId = chat.lastKnownAccountId ?: throw ApiException("error.blockFailed")
            val token = session.token ?: throw ApiException("error.blockFailed")
            if (blocked) api.blockContact(token, accountId) else api.unblockContact(token, accountId)
            onBlockChanged()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            chats.setChatBlockedByMe(chat.peerLogin, !blocked)
            throw if (e is ApiException) e else ApiException("error.blockFailed", cause = e)
        }
    }

    /** Актуальный device_id собеседника (мог переустановить приложение). */
    suspend fun currentDeviceId(chat: ChatSummary): String? =
        messenger.resolvePeerDeviceId(chat.peerLogin, chat.lastKnownDeviceId ?: "").ifEmpty { null }

    /**
     * Очистить историю ([deleteChat] = false) или удалить чат целиком. [forPeer] —
     * то же у собеседника: заодно сбрасывается сессия шифрования (раз всё стёрто
     * у обоих — начинаем и шифрование с чистого листа).
     */
    suspend fun clearOrDelete(chat: ChatSummary, deleteChat: Boolean, forPeer: Boolean) {
        if (forPeer) {
            currentDeviceId(chat)?.let { deviceId ->
                router.resetSessionWith(deviceId, if (deleteChat) "delete chat (both sides)" else "clear history (both sides)")
                messenger.sendControl(deviceId, if (deleteChat) InnerMessage.deleteChat() else InnerMessage.clearChat())
            }
        }
        val all = chats.getMessages(chat.peerLogin)
        if (deleteChat) chats.removeChat(chat.peerLogin) else chats.clearHistory(chat.peerLogin)
        cleanup.purgeAll(all)
    }

    /** Чат открыт: обновить device_id собеседника и отметку "аккаунт удалён". */
    suspend fun refreshPeer(peerLogin: String) {
        val token = session.token ?: return
        try {
            val devices = api.getDevicesByLogin(token, peerLogin).devices
            devices.firstOrNull()?.optString("device_id")?.let {
                chats.setLastKnownDeviceId(peerLogin, it)
                chats.setPeerDeletedStatus(peerLogin, false)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: ApiException) {
            chats.setPeerDeletedStatus(peerLogin, true)
        } catch (_: Exception) {
            // нет сети — оставляем как было
        }
    }
}
