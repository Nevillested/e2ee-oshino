package com.oshinobu.core.storage

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.concurrent.ConcurrentHashMap

/**
 * Локальная история переписки и список чатов — порт
 * client/lib/storage/chat_store.dart (те же ключи secure storage:
 * `messages:<login>`, `deleted_ids:<login>`, `known_peers`).
 *
 * Отличие от Flutter одно: чат «Заметки» (`__notes__`) убран — Kotlin-клиент
 * его не показывает и не создаёт. Сами данные не удаляются, чтобы откат на
 * Flutter-сборку их не потерял.
 */
class ChatStore(private val secure: SecureStore, private val now: () -> Long = System::currentTimeMillis) {
    companion object {
        /** Логин чата «Заметки» во Flutter-клиенте — в Kotlin скрыт. */
        const val LEGACY_NOTES_LOGIN = "__notes__"
        private const val PEERS_INDEX_KEY = "known_peers"
        private const val MAX_TOMBSTONES = 500
        private const val PREVIEW_MARK = ""

        private fun messagesKey(peerLogin: String) = "messages:$peerLogin"
        private fun deletedIdsKey(peerLogin: String) = "deleted_ids:$peerLogin"

        /**
         * Превью для списка чатов. Системные подписи (тип медиа, исход звонка)
         * хранятся маркером '<тип>[:<арг>]' и переводятся при показе
         * ([decodePreview]) — иначе смена языка не меняла бы старые превью.
         */
        fun previewMarker(m: StoredMessage): String {
            if (m.isCallLog) return "${PREVIEW_MARK}call:${m.callOutcome ?: "no_answer"}"
            if (m.isUndecryptable) return "${PREVIEW_MARK}undecryptable"
            if (m.isVoice) return "${PREVIEW_MARK}voice"
            if (m.isVideoNote) return "${PREVIEW_MARK}videoNote"
            if (m.isMedia) {
                val caption = m.text.trim()
                // старые превью, "замороженные" переведённой строкой с эмодзи
                val oldFrozen = listOf("📷", "🎬", "📎", "🎥", "🎤").any { caption.startsWith(it) }
                if (caption.isNotEmpty() && !oldFrozen) return caption
                if (m.isFile) return if (!m.fileName.isNullOrEmpty()) "${PREVIEW_MARK}file:${m.fileName}" else "${PREVIEW_MARK}file"
                if (m.isVideo) return "${PREVIEW_MARK}video"
                return "${PREVIEW_MARK}photo"
            }
            return m.text
        }

        /** Маркер → локализованная строка; [tr] — перевод по ключу Flutter-локализации. */
        fun decodePreview(raw: String, tr: (String) -> String): String {
            if (!raw.startsWith(PREVIEW_MARK)) return raw
            val body = raw.removePrefix(PREVIEW_MARK)
            val type = body.substringBefore(':')
            val arg = if (':' in body) body.substringAfter(':') else ""
            return when (type) {
                "voice" -> "🎤 ${tr("media.voiceNote")}"
                "videoNote" -> "🎥 ${tr("media.videoNote")}"
                "photo" -> "📷 ${tr("media.photo")}"
                "video" -> "🎬 ${tr("media.video")}"
                "file" -> arg.ifEmpty { "📎 ${tr("media.file")}" }
                "undecryptable" -> "🔒 ${tr("chat.undecryptablePreview")}"
                "call" -> "📞 " + when (arg) {
                    "answered" -> tr("call.answered")
                    "missed" -> tr("call.missed")
                    else -> tr("call.noAnswer")
                }
                else -> raw
            }
        }
    }

    private val _changes = MutableSharedFlow<Unit>(extraBufferCapacity = 64)
    /** Что-то в истории или списке чатов изменилось — повод перечитать. */
    val changes: SharedFlow<Unit> = _changes.asSharedFlow()

    private fun notifyChanged() {
        _changes.tryEmit(Unit)
    }

    private val peerLocks = ConcurrentHashMap<String, Mutex>()
    private val peersLock = Mutex()

    private suspend fun <T> withPeerLock(peerLogin: String, action: suspend () -> T): T =
        peerLocks.getOrPut(peerLogin) { Mutex() }.withLock { action() }

    private suspend fun <T> withPeersLock(action: suspend () -> T): T = peersLock.withLock { action() }

    // ---------------- история ----------------

    suspend fun getMessages(peerLogin: String): MutableList<StoredMessage> {
        val stored = secure.read(messagesKey(peerLogin)) ?: return mutableListOf()
        return Json.parseToJsonElement(stored).jsonArray.map { StoredMessage.fromJson(it.jsonObject) }.toMutableList()
    }

    private suspend fun writeMessages(peerLogin: String, messages: List<StoredMessage>) {
        secure.write(messagesKey(peerLogin), JsonArray(messages.map { it.toJson() }).toString())
    }

    // "Надгробия" удалённых id: control-сообщение 'delete' может обогнать
    // само удаляемое сообщение — без этого addMessage вернул бы его обратно.
    private suspend fun getTombstones(peerLogin: String): LinkedHashSet<String> {
        val stored = secure.read(deletedIdsKey(peerLogin)) ?: return linkedSetOf()
        return Json.parseToJsonElement(stored).jsonArray.mapTo(LinkedHashSet()) { it.jsonPrimitive.content }
    }

    private suspend fun writeTombstones(peerLogin: String, ids: Collection<String>) {
        secure.write(deletedIdsKey(peerLogin), JsonArray(ids.map { JsonPrimitive(it) }).toString())
    }

    private suspend fun addTombstones(peerLogin: String, ids: Collection<String>) {
        if (ids.isEmpty()) return
        val set = getTombstones(peerLogin).apply { addAll(ids) }
        writeTombstones(peerLogin, if (set.size > MAX_TOMBSTONES) set.toList().takeLast(MAX_TOMBSTONES) else set)
    }

    private suspend fun consumeTombstone(peerLogin: String, messageId: String): Boolean {
        val set = getTombstones(peerLogin)
        if (!set.remove(messageId)) return false
        writeTombstones(peerLogin, set)
        return true
    }

    /**
     * Добавляет сообщение. Дубль по messageId (повторная доставка) и уже
     * удалённое (tombstone) молча гасятся — это единственная точка, куда
     * стекаются все входящие.
     */
    suspend fun addMessage(peerLogin: String, message: StoredMessage, accountId: String? = null, incrementUnread: Boolean = false) {
        val added = withPeerLock(peerLogin) {
            val messages = getMessages(peerLogin)
            if (messages.any { it.messageId == message.messageId }) return@withPeerLock false
            if (consumeTombstone(peerLogin, message.messageId)) return@withPeerLock false
            messages += message
            writeMessages(peerLogin, messages)
            true
        }
        if (!added) return
        touchPeer(peerLogin, previewMarker(message), message.timestamp, accountId, incrementUnread, message.isMine, message.status == MessageStatus.READ)
    }

    /** Несколько сообщений одной записью и одним уведомлением (группа файлов). */
    suspend fun addMessages(peerLogin: String, newMessages: List<StoredMessage>, accountId: String? = null, incrementUnread: Boolean = false) {
        if (newMessages.isEmpty()) return
        val added = withPeerLock(peerLogin) {
            val messages = getMessages(peerLogin)
            val existing = messages.mapTo(HashSet()) { it.messageId }
            val candidates = newMessages.filter { it.messageId !in existing }
            val tombstones = getTombstones(peerLogin)
            val actuallyAdded = candidates.filter { it.messageId !in tombstones }
            val consumed = candidates.filter { it.messageId in tombstones }.map { it.messageId }
            if (consumed.isNotEmpty()) {
                tombstones.removeAll(consumed.toSet())
                writeTombstones(peerLogin, tombstones)
            }
            if (actuallyAdded.isNotEmpty()) {
                messages += actuallyAdded
                writeMessages(peerLogin, messages)
            }
            actuallyAdded
        }
        if (added.isEmpty()) return
        val last = added.maxBy { it.timestamp }
        touchPeer(peerLogin, previewMarker(last), last.timestamp, accountId, incrementUnread, last.isMine, last.status == MessageStatus.READ)
    }

    /**
     * Запись о звонке. [callId] — общий для обеих сторон UUID звонка: тогда у
     * записи одинаковый id на обоих устройствах и "удалить у обоих" её находит.
     * Ответили — сразу считается прочитанным (живое синхронное подтверждение).
     */
    suspend fun addCallLog(
        peerLogin: String,
        direction: String,
        outcome: String,
        timestamp: Long,
        durationSeconds: Long? = null,
        accountId: String? = null,
        incrementUnread: Boolean = false,
        callId: String? = null,
    ) {
        val answered = outcome == "answered"
        addMessage(
            peerLogin,
            StoredMessage(
                messageId = if (callId != null) "call_$callId" else "call_${timestamp}_$direction",
                // у звонка нет текста: пузырь рисуется по callOutcome, превью — маркером
                text = "",
                isMine = direction == "outgoing",
                timestamp = timestamp,
                isCallLog = true,
                callDirection = direction,
                callOutcome = outcome,
                callDurationSeconds = durationSeconds,
                status = if (answered) MessageStatus.READ else MessageStatus.SENT,
                readReceiptSent = answered,
            ),
            accountId, incrementUnread,
        )
    }

    /**
     * Заглушка на месте окончательно нерасшифрованного входящего сообщения
     * ([id] стабилен для одного конверта — повторы гасит addMessage).
     * Квитанцию о прочтении за неё слать незачем — id наш, локальный.
     */
    suspend fun addUndecryptableNotice(peerLogin: String, id: String, timestamp: Long, accountId: String? = null, incrementUnread: Boolean = false) =
        addMessage(peerLogin, StoredMessage(id, "", false, timestamp, isUndecryptable = true, readReceiptSent = true), accountId, incrementUnread)

    private suspend fun replace(peerLogin: String, messageId: String, update: (StoredMessage) -> StoredMessage) {
        withPeerLock(peerLogin) {
            val messages = getMessages(peerLogin)
            val i = messages.indexOfFirst { it.messageId == messageId }
            if (i == -1) return@withPeerLock
            messages[i] = update(messages[i])
            writeMessages(peerLogin, messages)
        }
        notifyChanged()
    }

    suspend fun updateMessageStatus(peerLogin: String, messageId: String, newStatus: String) = replace(peerLogin, messageId) {
        val clearStep = newStatus == MessageStatus.SENT || newStatus == MessageStatus.FAILED || newStatus == MessageStatus.QUEUED
        it.copy(status = newStatus, processingStep = if (clearStep) null else it.processingStep)
    }

    suspend fun markRetrying(peerLogin: String, messageId: String, processingStep: String) =
        replace(peerLogin, messageId) { it.copy(status = MessageStatus.SENDING, processingStep = processingStep) }

    suspend fun updateProcessingStep(peerLogin: String, messageId: String, step: String) =
        replace(peerLogin, messageId) { it.copy(processingStep = step) }

    suspend fun updateMediaInfo(peerLogin: String, messageId: String, mediaId: String, keyBase64: String, nonceBase64: String?, macBase64: String?) =
        replace(peerLogin, messageId) {
            it.copy(
                mediaId = mediaId,
                mediaKeyBase64 = keyBase64,
                // как copyWith во Flutter: null значит "не менять"
                mediaNonceBase64 = nonceBase64 ?: it.mediaNonceBase64,
                mediaMacBase64 = macBase64 ?: it.mediaMacBase64,
            )
        }

    /** emoji = null — снять реакцию. До одной реакции на сторону. */
    suspend fun setReaction(peerLogin: String, messageId: String, isMine: Boolean, emoji: String?) =
        replace(peerLogin, messageId) { if (isMine) it.copy(myReaction = emoji) else it.copy(peerReaction = emoji) }

    suspend fun editMessageText(peerLogin: String, messageId: String, newText: String) =
        replace(peerLogin, messageId) { it.copy(text = newText, edited = true) }

    /** Собеседник прочитал наши сообщения [messageIds]. */
    suspend fun markMessagesRead(peerLogin: String, messageIds: List<String>) {
        if (messageIds.isEmpty()) return
        val ids = messageIds.toSet()
        val after = withPeerLock(peerLogin) {
            val messages = getMessages(peerLogin)
            var changed = false
            for (i in messages.indices) {
                if (messages[i].messageId in ids && messages[i].status != MessageStatus.READ) {
                    messages[i] = messages[i].copy(status = MessageStatus.READ)
                    changed = true
                }
            }
            if (changed) writeMessages(peerLogin, messages)
            messages
        }
        if (after.isNotEmpty()) {
            val last = after.maxBy { it.timestamp }
            withPeersLock {
                val peers = readPeers()
                val p = peers.firstOrNull { it.peerLogin == peerLogin }
                val isRead = last.isMine && last.status == MessageStatus.READ
                if (p != null && (p.lastMessageIsMine != last.isMine || p.lastMessageIsRead != isRead)) {
                    p.lastMessageIsMine = last.isMine
                    p.lastMessageIsRead = isRead
                    writePeers(peers)
                }
            }
        }
        notifyChanged()
    }

    /** Квитанции за эти (чужие) сообщения уже отправлены — не слать повторно. */
    suspend fun markReadReceiptsSent(peerLogin: String, messageIds: List<String>) {
        if (messageIds.isEmpty()) return
        val ids = messageIds.toSet()
        withPeerLock(peerLogin) {
            val messages = getMessages(peerLogin)
            var changed = false
            for (i in messages.indices) {
                if (messages[i].messageId in ids && !messages[i].readReceiptSent) {
                    messages[i] = messages[i].copy(readReceiptSent = true)
                    changed = true
                }
            }
            if (changed) writeMessages(peerLogin, messages)
        }
    }

    /** Удаляет локально и ставит "надгробия" (на случай, если удаляемое ещё в пути). */
    suspend fun deleteMessages(peerLogin: String, messageIds: List<String>) {
        if (messageIds.isEmpty()) return
        val ids = messageIds.toSet()
        val remaining = withPeerLock(peerLogin) {
            val messages = getMessages(peerLogin)
            messages.removeAll { it.messageId in ids }
            writeMessages(peerLogin, messages)
            addTombstones(peerLogin, ids)
            messages
        }
        withPeersLock {
            val peers = readPeers()
            val p = peers.firstOrNull { it.peerLogin == peerLogin }
            if (p == null) {
                notifyChanged()
                return@withPeersLock
            }
            if (remaining.isEmpty()) {
                p.lastMessage = ""
                p.lastTimestamp = 0
                p.lastMessageIsMine = false
                p.lastMessageIsRead = false
            } else {
                val last = remaining.maxBy { it.timestamp }
                p.lastMessage = previewMarker(last)
                p.lastTimestamp = last.timestamp
                p.lastMessageIsMine = last.isMine
                p.lastMessageIsRead = last.status == MessageStatus.READ
            }
            writePeers(peers)
        }
    }

    /** "Очистить историю" — сообщения и надгробия, сам чат остаётся. */
    suspend fun clearHistory(peerLogin: String) {
        withPeerLock(peerLogin) {
            writeMessages(peerLogin, emptyList())
            secure.delete(deletedIdsKey(peerLogin))
        }
        withPeersLock {
            val peers = readPeers()
            val p = peers.firstOrNull { it.peerLogin == peerLogin }
            if (p != null) {
                p.lastMessage = ""
                p.lastTimestamp = 0
                p.pinnedMessageId = null
                writePeers(peers)
            } else {
                notifyChanged()
            }
        }
    }

    /** "Удалить чат" — вместе с записью в списке. */
    suspend fun removeChat(peerLogin: String) {
        withPeerLock(peerLogin) {
            secure.delete(messagesKey(peerLogin))
            secure.delete(deletedIdsKey(peerLogin))
        }
        withPeersLock {
            val peers = readPeers()
            peers.removeAll { it.peerLogin == peerLogin }
            writePeers(peers)
        }
    }

    // ---------------- список чатов ----------------

    private suspend fun readPeers(): MutableList<ChatSummary> {
        val stored = secure.read(PEERS_INDEX_KEY) ?: return mutableListOf()
        return Json.parseToJsonElement(stored).jsonArray.map { ChatSummary.fromJson(it.jsonObject) }.toMutableList()
    }

    private suspend fun writePeers(peers: List<ChatSummary>) {
        secure.write(PEERS_INDEX_KEY, JsonArray(peers.map { it.toJson() }).toString())
        notifyChanged()
    }

    /** Список чатов в порядке показа, без чата «Заметки». */
    suspend fun getKnownPeers(): List<ChatSummary> =
        readPeers().filter { it.peerLogin != LEGACY_NOTES_LOGIN }.sortedWith(ChatSummary.listOrder)

    private suspend fun updatePeer(peerLogin: String, update: (ChatSummary) -> Boolean) = withPeersLock {
        val peers = readPeers()
        val p = peers.firstOrNull { it.peerLogin == peerLogin } ?: return@withPeersLock
        if (update(p)) writePeers(peers)
    }

    private suspend fun touchPeer(
        peerLogin: String,
        lastMessage: String,
        timestamp: Long,
        accountId: String?,
        incrementUnread: Boolean,
        isMine: Boolean,
        isRead: Boolean,
    ) = withPeersLock {
        val peers = readPeers()
        val p = peers.firstOrNull { it.peerLogin == peerLogin }
        if (p != null) {
            p.lastMessage = lastMessage
            p.lastTimestamp = timestamp
            p.lastMessageIsMine = isMine
            p.lastMessageIsRead = isMine && isRead
            if (accountId != null) p.lastKnownAccountId = accountId
            if (incrementUnread) p.unreadCount += 1
        } else {
            peers += ChatSummary(
                peerLogin, lastMessage, timestamp,
                lastKnownAccountId = accountId,
                unreadCount = if (incrementUnread) 1 else 0,
                lastMessageIsMine = isMine,
                lastMessageIsRead = isMine && isRead,
            )
        }
        writePeers(peers)
    }

    /** Закреплённое сообщение в шапке чата (null — открепить). */
    suspend fun setPinned(peerLogin: String, messageId: String?) = withPeersLock {
        val peers = readPeers()
        val p = peers.firstOrNull { it.peerLogin == peerLogin }
        if (p == null) {
            if (messageId == null) return@withPeersLock
            peers += ChatSummary(peerLogin, "", 0, pinnedMessageId = messageId)
        } else {
            p.pinnedMessageId = messageId
        }
        writePeers(peers)
    }

    /** Закрепить чат вверху списка. */
    suspend fun setChatPinned(peerLogin: String, pinned: Boolean) = withPeersLock {
        val peers = readPeers()
        val p = peers.firstOrNull { it.peerLogin == peerLogin }
        if (p == null) {
            if (!pinned) return@withPeersLock
            peers += ChatSummary(peerLogin, "", 0, chatPinnedAt = now())
        } else {
            p.chatPinnedAt = if (pinned) now() else null
        }
        writePeers(peers)
    }

    suspend fun isChatMuted(peerLogin: String): Boolean = readPeers().firstOrNull { it.peerLogin == peerLogin }?.muted ?: false

    suspend fun setChatMuted(peerLogin: String, muted: Boolean) = updatePeer(peerLogin) { it.muted = muted; true }

    suspend fun syncMutedFromServer(mutedAccountIds: Set<String>) = withPeersLock {
        val peers = readPeers()
        var changed = false
        for (p in peers) {
            val should = p.lastKnownAccountId != null && p.lastKnownAccountId in mutedAccountIds
            if (p.muted != should) {
                p.muted = should
                changed = true
            }
        }
        if (changed) writePeers(peers)
    }

    suspend fun setChatBlockedByMe(peerLogin: String, blocked: Boolean) = updatePeer(peerLogin) { it.blockedByMe = blocked; true }

    suspend fun syncBlockedFromServer(blockedByMe: Set<String>, blockingMe: Set<String>) = withPeersLock {
        val peers = readPeers()
        var changed = false
        for (p in peers) {
            val id = p.lastKnownAccountId
            val byMe = id != null && id in blockedByMe
            val me = id != null && id in blockingMe
            if (p.blockedByMe != byMe) { p.blockedByMe = byMe; changed = true }
            if (p.blockingMe != me) { p.blockingMe = me; changed = true }
        }
        if (changed) writePeers(peers)
    }

    suspend fun clearUnread(peerLogin: String) = updatePeer(peerLogin) {
        if (it.unreadCount == 0) false else { it.unreadCount = 0; true }
    }

    suspend fun setPeerDeletedStatus(peerLogin: String, isDeleted: Boolean) = updatePeer(peerLogin) { it.isDeleted = isDeleted; true }

    suspend fun setLastKnownDeviceId(peerLogin: String, deviceId: String) = updatePeer(peerLogin) { it.lastKnownDeviceId = deviceId; true }

    /** Разовая досчитка lastMessageIsMine/IsRead у списков, созданных до появления этих полей. */
    suspend fun backfillLastMessageMeta() = withPeersLock {
        val peers = readPeers()
        var changed = false
        for (p in peers) {
            val messages = getMessages(p.peerLogin)
            if (messages.isEmpty()) continue
            val last = messages.maxBy { it.timestamp }
            val isRead = last.isMine && last.status == MessageStatus.READ
            if (p.lastMessageIsMine != last.isMine || p.lastMessageIsRead != isRead) {
                p.lastMessageIsMine = last.isMine
                p.lastMessageIsRead = isRead
                changed = true
            }
        }
        if (changed) writePeers(peers)
    }

    data class SendingText(val peerLogin: String, val messageId: String, val text: String)

    /** Свои текстовые сообщения, застрявшие в 'sending' (переотправка при старте). */
    suspend fun getSendingTextMessages(): List<SendingText> = getKnownPeers().flatMap { p ->
        getMessages(p.peerLogin).filter { it.isMine && !it.isMedia && it.status == MessageStatus.SENDING }
            .map { SendingText(p.peerLogin, it.messageId, it.text) }
    }

    /** Свои медиа в 'sending' без живого задания на загрузку — помечаем 'failed'. */
    suspend fun failOrphanedSendingMedia(knownJobIds: Set<String>) {
        for (p in getKnownPeers()) {
            for (m in getMessages(p.peerLogin)) {
                if (!m.isMine || !m.isMedia || m.status != MessageStatus.SENDING) continue
                if (m.messageId in knownJobIds) continue
                if (m.groupId != null && m.groupId in knownJobIds) continue
                updateMessageStatus(p.peerLogin, m.messageId, MessageStatus.FAILED)
            }
        }
    }
}
