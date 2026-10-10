package com.oshinobu.app.ui.chat

import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.clearText
import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.oshinobu.app.AndroidRouterHost
import com.oshinobu.core.OshinobuCore
import com.oshinobu.core.net.ConnectionStatus
import com.oshinobu.core.optBool
import com.oshinobu.core.optLong
import com.oshinobu.core.optString
import com.oshinobu.core.service.ChatPeer
import com.oshinobu.core.service.DownloadSpec
import com.oshinobu.core.service.OutgoingFile
import com.oshinobu.core.service.RetryOutcome
import com.oshinobu.core.service.VideoThumbnailer
import com.oshinobu.core.storage.MessageStatus
import com.oshinobu.core.storage.StoredMessage
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch
import java.io.File

/** Длительность анимации "рассыпания" удаляемого сообщения. */
const val DISSOLVE_MS = 700L

/** Что показать пользователю коротким всплывающим сообщением (ключ строкового ресурса решает экран). */
sealed interface ChatNotice {
    data object Copied : ChatNotice
    data object RetryFailedPermanently : ChatNotice
    data object SessionResetDone : ChatNotice
    data class FilesTooLarge(val count: Int, val firstSize: Long) : ChatNotice
}

/**
 * Состояние и действия открытого чата. Логика сообщений — в ядре
 * ([com.oshinobu.core.service.ChatService]); здесь — то, что видит экран:
 * история, собеседник (имя, присутствие, "печатает", блокировки, закреп),
 * поле ввода (ответ, правка, пересылка), выделение и поиск.
 */
class ChatViewModel(
    private val core: OshinobuCore,
    private val routerHost: AndroidRouterHost,
    login: String,
    accountId: String,
    deviceId: String,
    forwardedTexts: List<String>,
    /** Подписи вложений для панели передач. */
    labels: MediaLabels,
) : ViewModel() {
    private val media = MediaResolver(core, login, labels)

    var peer by mutableStateOf(ChatPeer(login, accountId, deviceId))
        private set
    var messages by mutableStateOf<List<StoredMessage>>(emptyList())
        private set
    var loaded by mutableStateOf(false)
        private set

    // собеседник
    var peerOnline by mutableStateOf<Boolean?>(null)
        private set
    var peerLastSeenMs by mutableStateOf<Long?>(null)
        private set
    var peerTyping by mutableStateOf(false)
        private set
    var peerDeleted by mutableStateOf(false)
        private set
    var blockedByMe by mutableStateOf(false)
        private set
    var blockingMe by mutableStateOf(false)
        private set
    var pinnedId by mutableStateOf<String?>(null)
        private set
    var muted by mutableStateOf(false)
        private set

    // поле ввода
    /** Текст в поле ввода. */
    val input = TextFieldState()
    private val draft: String get() = input.text.toString()
    var replyTo by mutableStateOf<StoredMessage?>(null)
        private set
    var editing by mutableStateOf<StoredMessage?>(null)
        private set
    var forwarding by mutableStateOf(forwardedTexts.takeIf { it.isNotEmpty() })
        private set

    // выделение и поиск
    val selected = mutableStateListOf<String>()
    var searchQuery by mutableStateOf<String?>(null)
        private set

    /** Сообщения с только что поставленной чужой реакцией — для анимации. */
    val justReacted = mutableStateListOf<String>()

    /**
     * Сообщения, которые сейчас "рассыпаются" (анимация удаления): экран
     * продолжает их показывать, даже когда в хранилище их уже нет.
     */
    var dissolving by mutableStateOf<Map<String, StoredMessage>>(emptyMap())
        private set

    private val _notices = MutableSharedFlow<ChatNotice>(extraBufferCapacity = 8)
    val notices: SharedFlow<ChatNotice> = _notices.asSharedFlow()

    // медиа: прогресс отправки (по messageId) и скачивания (по mediaId), 0..100
    val uploadProgress = core.pendingSender.progress
    val downloadProgress = core.downloads.progress
    val downloads = core.downloads.snapshot

    /** Растёт с каждым скачанным файлом — пузыри перечитывают картинки с диска. */
    var mediaVersion by mutableIntStateOf(0)
        private set

    /** Вложения, чьё скачивание сорвалось (повтор — по тапу). */
    val failedDownloads = mutableStateListOf<String>()

    private var typingClear: Job? = null
    private var lastTypingSentAt = 0L

    init {
        routerHost.openChatPeerLogin = login
        viewModelScope.launch { core.chats.clearUnread(login) }
        viewModelScope.launch {
            reload()
            core.chats.changes.collect { reload() }
        }
        viewModelScope.launch { snapshotFlow { input.text.toString() }.drop(1).collect(::notifyTyping) }
        viewModelScope.launch { core.downloads.done.collect { mediaVersion++ } }
        viewModelScope.launch {
            core.downloads.failed.collect { if (it !in failedDownloads) failedDownloads += it }
        }
        viewModelScope.launch {
            core.router.incomingDeletes.filter { it.peerLogin == login }.collect { event ->
                val gone = messages.filter { it.messageId in event.targetIds }
                if (gone.isNotEmpty()) dissolve(gone) {}
            }
        }
        viewModelScope.launch {
            core.router.incomingReactions.filter { it.peerLogin == login }.collect { markJustReacted(it.messageId) }
        }
        viewModelScope.launch { refreshPeerDevice() }
        viewModelScope.launch {
            // переподключились — заново подписаться на присутствие и проверить устройство
            core.ws.status.collect {
                if (it == ConnectionStatus.CONNECTED) {
                    subscribePresence()
                    refreshPeerDevice()
                }
            }
        }
        viewModelScope.launch {
            core.ws.presenceEvents.collect { event ->
                if (event.optString("FromDeviceId") != peer.deviceId) return@collect
                when (event.optString("Type")) {
                    "presence" -> {
                        peerOnline = event.optBool("Online") ?: false
                        peerLastSeenMs = event.optLong("LastSeenMs") ?: 0
                        if (peerOnline == true) peerTyping = false
                    }
                    "typing" -> {
                        peerTyping = true
                        typingClear?.cancel()
                        typingClear = viewModelScope.launch {
                            delay(4_000)
                            peerTyping = false
                        }
                    }
                }
            }
        }
        viewModelScope.launch {
            core.ws.blockStatusEvents.collect { refreshBlockStatus() }
        }
        viewModelScope.launch { refreshBlockStatus() }
    }

    override fun onCleared() {
        if (routerHost.openChatPeerLogin == peer.login) routerHost.openChatPeerLogin = null
        if (peer.deviceId.isNotEmpty()) core.ws.unsubscribePresence(peer.deviceId)
    }

    private suspend fun reload() {
        messages = withGhosts(core.chats.getMessages(peer.login))
        core.chats.getKnownPeers().firstOrNull { it.peerLogin == peer.login }?.let {
            peerDeleted = it.isDeleted
            pinnedId = it.pinnedMessageId
            blockedByMe = it.blockedByMe
            blockingMe = it.blockingMe
            muted = it.muted
        }
        loaded = true
        core.chatService.sendReadReceipts(peer, messages)
    }

    /** Рассыпающиеся сообщения остаются на своих местах (по времени), пока идёт анимация. */
    private fun withGhosts(stored: List<StoredMessage>): List<StoredMessage> {
        val ghosts = dissolving.values.filter { g -> stored.none { it.messageId == g.messageId } }
        if (ghosts.isEmpty()) return stored
        return (stored + ghosts).sortedBy { it.timestamp }
    }

    /** Анимация удаления, затем [then] и уборка призраков. */
    private fun dissolve(gone: List<StoredMessage>, then: suspend () -> Unit) {
        dissolving = dissolving + gone.associateBy { it.messageId }
        viewModelScope.launch {
            delay(DISSOLVE_MS)
            then()
            dissolving = dissolving - gone.map { it.messageId }.toSet()
            reload()
        }
    }

    private fun subscribePresence() {
        if (peer.deviceId.isNotEmpty()) core.ws.subscribePresence(peer.deviceId)
    }

    /** Актуальный device_id собеседника (переустановил приложение — сменился). */
    private suspend fun refreshPeerDevice() {
        core.chatActions.refreshPeer(peer.login)
        val known = core.chats.getKnownPeers().firstOrNull { it.peerLogin == peer.login }
        val fresh = known?.lastKnownDeviceId
        if (!fresh.isNullOrEmpty() && fresh != peer.deviceId) {
            if (peer.deviceId.isNotEmpty()) core.ws.unsubscribePresence(peer.deviceId)
            peer = peer.copy(deviceId = fresh, accountId = known.lastKnownAccountId ?: peer.accountId)
        }
        subscribePresence()
    }

    private suspend fun refreshBlockStatus() {
        val token = core.session.token ?: return
        val blocked = core.api.getBlockedContacts(token) ?: return
        blockedByMe = peer.accountId in blocked.blockedByMe
        blockingMe = peer.accountId in blocked.blockingMe
        core.chats.syncBlockedFromServer(blocked.blockedByMe.toSet(), blocked.blockingMe.toSet())
    }

    private fun markJustReacted(messageId: String) {
        justReacted += messageId
        viewModelScope.launch {
            delay(900)
            justReacted -= messageId
        }
    }

    // ---------------- ввод ----------------

    /** Не чаще раза в 3 с — собеседнику "печатает…". */
    private fun notifyTyping(text: CharSequence) {
        val now = System.currentTimeMillis()
        if (text.isNotBlank() && peer.deviceId.isNotEmpty() && now - lastTypingSentAt > 3_000) {
            lastTypingSentAt = now
            core.ws.sendTyping(peer.deviceId)
        }
    }

    /** Эмодзи из панели — на место курсора. */
    fun insertEmoji(emoji: String) {
        input.edit { replace(selection.min, selection.max, emoji) }
    }

    fun startReply(msg: StoredMessage) {
        replyTo = msg
        editing = null
    }

    fun cancelReply() {
        replyTo = null
    }

    fun startEdit(msg: StoredMessage) {
        editing = msg
        replyTo = null
        input.setTextAndPlaceCursorAtEnd(msg.text)
    }

    fun cancelEdit() {
        editing = null
        input.clearText()
    }

    fun cancelForward() {
        forwarding = null
    }

    /** Кнопка "отправить": правка, пересылка (+ свой текст) или новое сообщение. */
    fun send() {
        val text = draft.trim()
        val edit = editing
        val forward = forwarding
        when {
            edit != null -> {
                if (text.isEmpty()) return
                input.clearText()
                editing = null
                viewModelScope.launch { core.chatService.editText(peer, edit.messageId, text) }
            }
            !forward.isNullOrEmpty() -> {
                input.clearText()
                forwarding = null
                viewModelScope.launch { core.chatService.sendTexts(peer, forward + listOfNotNull(text.takeIf { it.isNotEmpty() })) }
            }
            text.isNotEmpty() -> {
                input.clearText()
                val reply = replyTo
                replyTo = null
                viewModelScope.launch { core.chatService.sendText(peer, text, reply) }
            }
        }
    }

    fun sendMedia(files: List<OutgoingFile>, caption: String, thumbnailer: VideoThumbnailer) {
        viewModelScope.launch {
            val rejected = core.chatService.sendMedia(peer, files, caption, thumbnailer)
            if (rejected.isNotEmpty()) _notices.tryEmit(ChatNotice.FilesTooLarge(rejected.size, rejected.first().file.length()))
        }
    }

    /** Документы уходят по одному, не альбомом. */
    fun sendFiles(files: List<OutgoingFile>, thumbnailer: VideoThumbnailer) {
        viewModelScope.launch {
            val rejected = files.flatMap { core.chatService.sendMedia(peer, listOf(it), "", thumbnailer) }
            if (rejected.isNotEmpty()) _notices.tryEmit(ChatNotice.FilesTooLarge(rejected.size, rejected.first().file.length()))
        }
    }

    fun sendRecorded(file: File, durationMs: Long, videoNote: Boolean, thumbnailer: VideoThumbnailer) {
        viewModelScope.launch { core.chatService.sendRecorded(peer, file, durationMs, videoNote, thumbnailer) }
    }

    // ---------------- действия с сообщениями ----------------

    fun react(msg: StoredMessage, emoji: String?) {
        if (emoji != null) markJustReacted(msg.messageId)
        viewModelScope.launch { core.chatService.react(peer, msg.messageId, emoji) }
    }

    /** Выбор в панели реакций: повторный тап по своей реакции снимает её; частота — для сортировки. */
    fun pickReaction(msg: StoredMessage, emoji: String) {
        viewModelScope.launch { core.settings.recordReactionUse(emoji) }
        react(msg, if (emoji == msg.myReaction) null else emoji)
    }

    /** Все реакции, частые — первыми. */
    suspend fun sortedReactions(all: List<String>): List<String> = core.settings.sortedReactions(all)

    /** Двойной тап: реакция по умолчанию; если она уже стоит — снять. */
    fun applyDefaultReaction(msg: StoredMessage) {
        viewModelScope.launch {
            val emoji = core.settings.defaultReaction()
            react(msg, if (msg.myReaction == emoji) null else emoji)
        }
    }

    fun setPinned(msg: StoredMessage, pinned: Boolean) {
        pinnedId = if (pinned) msg.messageId else null
        viewModelScope.launch { core.chatService.setPinned(peer, msg.messageId, pinned) }
    }

    fun delete(ids: List<String>, forPeer: Boolean) {
        val pinned = pinnedId
        if (pinned != null && pinned in ids) pinnedId = null
        selected.clear()
        dissolve(messages.filter { it.messageId in ids }) { core.chatService.deleteMessages(peer, ids, forPeer, pinned) }
    }

    fun report(msg: StoredMessage, comment: String, onDone: (Throwable?) -> Unit) {
        viewModelScope.launch {
            val error = runCatching {
                val token = core.session.token ?: error("no session")
                core.api.reportMessage(token, peer.deviceId, msg.text, comment)
            }.exceptionOrNull()
            onDone(error)
        }
    }

    fun cancelSend(ids: List<String>) {
        viewModelScope.launch { core.chatService.cancelSend(peer, ids) }
    }

    fun retrySend(jobId: String) {
        viewModelScope.launch {
            if (core.chatService.retrySend(jobId) == RetryOutcome.NOT_FOUND) _notices.tryEmit(ChatNotice.RetryFailedPermanently)
        }
    }

    fun resetSession() {
        viewModelScope.launch {
            core.chatService.resetSession(peer)
            _notices.tryEmit(ChatNotice.SessionResetDone)
        }
    }

    fun notifyCopied() {
        _notices.tryEmit(ChatNotice.Copied)
    }

    // ---------------- медиа ----------------

    fun localMediaFile(msg: StoredMessage): File? = media.localFile(msg)

    fun downloadSpec(msg: StoredMessage): DownloadSpec? = media.spec(msg)

    /** Файл для показа: с устройства или дождавшись скачивания. */
    suspend fun mediaFile(msg: StoredMessage, userInitiated: Boolean): File = media.file(msg, userInitiated)

    fun requestDownload(msg: StoredMessage) {
        val spec = downloadSpec(msg) ?: return
        failedDownloads -= spec.mediaId
        viewModelScope.launch { core.downloads.requestUserDownload(spec) }
    }

    fun cancelDownload(msg: StoredMessage) {
        val id = msg.mediaId ?: return
        viewModelScope.launch { core.downloads.cancelUserDownload(id) }
    }

    /** Видимые на экране вложения — мелкие докачиваются сами. */
    fun onMediaVisible(visible: List<StoredMessage>) {
        val specs = visible.filter { it.isMedia && !it.isMine }.mapNotNull(::downloadSpec)
        if (specs.isNotEmpty()) viewModelScope.launch { core.downloads.setVisible(specs) }
    }

    // ---------------- выделение ----------------

    val selectionMode: Boolean get() = selected.isNotEmpty()

    fun toggleSelected(ids: List<String>) {
        if (ids.all { it in selected }) selected.removeAll(ids) else ids.forEach { if (it !in selected) selected += it }
    }

    fun clearSelection() = selected.clear()

    /** Тексты выделенных сообщений (без медиа и звонков) — для копирования и пересылки. */
    fun selectedTexts(): List<String> = messages.filter { it.messageId in selected && !it.isMedia && !it.isCallLog && !it.isUndecryptable }.map { it.text }

    // ---------------- поиск ----------------

    fun openSearch() {
        searchQuery = ""
    }

    fun closeSearch() {
        searchQuery = null
    }

    fun setSearch(query: String) {
        searchQuery = query
    }

    /** Совпадения поиска — от новых к старым (как переход "вверх" по чату). */
    fun searchMatches(): List<StoredMessage> {
        val q = searchQuery?.trim()?.lowercase().orEmpty()
        if (q.isEmpty()) return emptyList()
        return messages.filter { !it.isCallLog && !it.isUndecryptable && !it.isMedia && it.text.lowercase().contains(q) }.reversed()
    }

    fun findMessage(id: String?): StoredMessage? = id?.let { mid -> messages.firstOrNull { it.messageId == mid } }

    /** Свои отправляющиеся/упавшие — статус группы для меню (как во Flutter). */
    fun groupStatus(ids: List<String>): String? {
        val group = messages.filter { it.messageId in ids && it.isMine }
        return when {
            group.any { it.status == MessageStatus.FAILED } -> MessageStatus.FAILED
            group.any { it.status == MessageStatus.SENDING || it.status == MessageStatus.QUEUED } -> MessageStatus.SENDING
            else -> null
        }
    }
}
