package com.oshinobu.demobot

import com.oshinobu.core.OshinobuCore
import com.oshinobu.core.service.ChatPeer
import com.oshinobu.core.storage.ChatSummary
import com.oshinobu.core.storage.StoredMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Учётные данные бота и кого приветствовать (data/bot.json). */
data class BotConfig(val login: String, val password: String, val totpSecret: String, val greetLogins: List<String>)

/**
 * Бот-собеседник для проверяющих App Store / Google Play. Переписка
 * зашифрована на устройствах, на сервере её нет, поэтому у проверяющего,
 * вошедшего с нового устройства, чатов нет — и проверить нечего. Бот:
 *  - сам пишет демо-аккаунту ([BotConfig.greetLogins]), как только тот вошёл
 *    с нового устройства — чат с содержимым появляется сразу;
 *  - отвечает на каждое сообщение (цитатой, с реакцией и прочтением), на
 *    фото, файлы, голосовые и стикеры — своим текстом;
 *  - звонок отклоняет и объясняет, что звонки — между двумя людьми.
 * Шифрование, протокол и хранилища — общее ядро клиентов (:core).
 */
class DemoBot(private val core: OshinobuCore, private val config: BotConfig, private val log: (String) -> Unit) {
    private companion object {
        const val HANDLED_KEY = "demo_bot_handled"
        const val GREETED_PREFIX = "demo_bot_greeted:"
        const val MAX_HANDLED = 2000
        const val GREET_POLL_MS = 5_000L
        const val SESSION_CHECK_MS = 60_000L
    }

    private val answering = Mutex()

    suspend fun run(): Unit = coroutineScope {
        signIn()
        // уже лежащее в истории (прошлые запуски) — не отвечаем повторно
        handled(markAllExisting = true)
        launch { core.chats.changes.conflate().collect { answerNew() } }
        launch { core.calls.incomingCalls.collect { call -> declineCall(call.peer.login, call.peer.accountId, call.peer.deviceId) } }
        launch {
            core.ws.sessionInvalidated.collect {
                log("session invalidated (signed in elsewhere?) — signing in again")
                core.signOutLocally()
                signIn()
            }
        }
        launch {
            while (true) {
                guarded("greet") { greetNewDevices() }
                delay(GREET_POLL_MS)
            }
        }
        launch {
            while (true) {
                delay(SESSION_CHECK_MS)
                guarded("session") { if (core.session.token == null) signIn() }
                guarded("answer") { answerNew() }
            }
        }
    }

    /** Сохранённая сессия, если сервер её признаёт, иначе — вход заново (новое устройство). */
    private suspend fun signIn() {
        val token = core.session.token
        if (token != null && core.keys.deviceId() != null && core.api.checkSession(token) != false) {
            core.startSession()
            log("session resumed as ${config.login}")
            return
        }
        if (token != null) core.signOutLocally()
        val result = core.api.login(config.login, config.password, Totp.code(config.totpSecret))
        core.session.token = result.token
        core.session.login = config.login
        core.startSession()
        log("signed in as ${config.login}")
    }

    // ---------------- ответы ----------------

    private fun handledIds(): MutableList<String> = core.prefs.getStringList(HANDLED_KEY).orEmpty().toMutableList()

    private suspend fun handled(markAllExisting: Boolean) {
        if (!markAllExisting || core.prefs.getStringList(HANDLED_KEY) != null) return
        val ids = core.chats.getKnownPeers().flatMap { peer -> core.chats.getMessages(peer.peerLogin).filter { !it.isMine }.map { it.messageId } }
        core.prefs.setStringList(HANDLED_KEY, ids.takeLast(MAX_HANDLED))
    }

    private suspend fun answerNew() = answering.withLock {
        val done = handledIds()
        for (summary in core.chats.getKnownPeers()) {
            val peer = resolvePeer(summary) ?: continue
            val messages = core.chats.getMessages(summary.peerLogin)
            val fresh = messages.filter { !it.isMine && !it.isCallLog && !it.isUndecryptable && it.messageId !in done }
            if (fresh.isEmpty()) continue
            core.chatService.sendReadReceipts(peer, messages)
            for (m in fresh) {
                done += m.messageId
                core.prefs.setStringList(HANDLED_KEY, done.takeLast(MAX_HANDLED))
                guarded("reply") { reply(peer, m) }
            }
        }
    }

    private suspend fun reply(peer: ChatPeer, m: StoredMessage) {
        core.chatService.react(peer, m.messageId, "👍")
        val text = when {
            m.isSticker -> "Nice sticker! Stickers are sent end-to-end encrypted too."
            m.isVoice -> "Got your voice message. Only you and I can listen to it."
            m.isVideoNote -> "Got your video message. Only you and I can watch it."
            m.isVideo -> "Got your video. It was encrypted on your device before upload."
            m.isFile -> "Got your file \"${m.fileName ?: "file"}\". It was encrypted on your device before upload."
            m.isMedia -> "Got your photo. It was encrypted on your device before upload."
            else -> "You wrote: \"${m.text.take(200)}\". I answer every message automatically. " +
                "Try a photo, a file, a voice message, a reply or a reaction."
        }
        core.chatService.sendText(peer, text, replyTo = m, replyPreview = m.text.ifEmpty { null })
        log("replied to ${peer.login}")
    }

    // ---------------- приветствие ----------------

    /** Демо-аккаунт вошёл с нового устройства — пишем ему первыми, чтобы чат был не пустой. */
    private suspend fun greetNewDevices() {
        val token = core.session.token ?: return
        for (login in config.greetLogins) {
            val devices = core.api.getDevicesByLogin(token, login)
            val deviceId = devices.devices.firstOrNull()?.get("device_id")?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content } ?: continue
            val key = GREETED_PREFIX + login
            if (core.prefs.getString(key) == deviceId) continue
            val peer = ChatPeer(login, devices.accountId, deviceId)
            core.chats.setLastKnownDeviceId(login, deviceId)
            val messages = listOf(
                "Hi! I'm the Oshinobu demo bot. This chat is end-to-end encrypted: only you and I can read it, the server only relays ciphertext.",
                "Try anything here: send a message, a photo, a file or a voice message, reply to a message, react with an emoji. I answer every message automatically.",
                "You can also report a message (open its menu: tap it on iPhone, long press on Android), block me (long press this chat in the chat list) and delete your account in Settings.",
                "Calls are peer-to-peer between two people, and I'm a bot, so I can't pick up. If you call me, I'll decline.",
            )
            for (text in messages) core.chatService.sendText(peer, text)
            core.chats.setLastKnownDeviceId(login, deviceId) // чат появился с первым сообщением — запомнить устройство
            core.prefs.setString(key, deviceId)
            log("greeted $login on a new device")
        }
    }

    // ---------------- звонки ----------------

    private suspend fun declineCall(login: String?, accountId: String?, deviceId: String) {
        guarded("call") {
            core.calls.declineCall()
            val peerLogin = login ?: core.router.resolveOwner(deviceId)?.login ?: return@guarded
            val account = accountId ?: core.router.resolveOwner(deviceId)?.accountId ?: return@guarded
            core.chatService.sendText(
                ChatPeer(peerLogin, account, deviceId),
                "I'm a bot, so I can't answer calls. Calls work between two people: audio and video, peer-to-peer and encrypted.",
            )
            log("declined a call from $peerLogin")
        }
    }

    /**
     * Собеседник для ответа. Чат, начатый входящим сообщением, устройства
     * собеседника не знает (приложение берёт его из сети, когда чат открывают) —
     * спрашиваем сервер и запоминаем.
     */
    private suspend fun resolvePeer(summary: ChatSummary): ChatPeer? {
        val accountId = summary.lastKnownAccountId
        val deviceId = summary.lastKnownDeviceId
        if (accountId != null && deviceId != null) return ChatPeer(summary.peerLogin, accountId, deviceId)
        val token = core.session.token ?: return null
        val devices = core.api.getDevicesByLogin(token, summary.peerLogin)
        val current = devices.devices.firstOrNull()?.get("device_id")?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content } ?: return null
        core.chats.setLastKnownDeviceId(summary.peerLogin, current)
        return ChatPeer(summary.peerLogin, devices.accountId, current)
    }

    private suspend fun guarded(what: String, block: suspend () -> Unit) {
        try {
            block()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log("$what failed: $e")
        }
    }
}
