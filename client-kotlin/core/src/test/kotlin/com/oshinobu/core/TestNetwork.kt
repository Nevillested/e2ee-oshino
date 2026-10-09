package com.oshinobu.core

import com.oshinobu.core.crypto.b64
import com.oshinobu.core.net.ApiClient
import com.oshinobu.core.net.ApiConfig
import com.oshinobu.core.net.CallSignaling
import com.oshinobu.core.net.ConnectionStatus
import com.oshinobu.core.net.IncomingEnvelope
import com.oshinobu.core.net.Transport
import com.oshinobu.core.protocol.InnerMessage
import com.oshinobu.core.service.AckRegistry
import com.oshinobu.core.service.CallManager
import com.oshinobu.core.service.ChatPeer
import com.oshinobu.core.service.ChatService
import com.oshinobu.core.service.KeyedMutex
import com.oshinobu.core.service.MediaDownloadManager
import com.oshinobu.core.service.MediaUploader
import com.oshinobu.core.service.MessageCleanup
import com.oshinobu.core.service.MessageRouter
import com.oshinobu.core.service.PeerMessenger
import com.oshinobu.core.service.PendingSendRetrier
import com.oshinobu.core.service.RouterHost
import com.oshinobu.core.service.SendQueueProcessor
import com.oshinobu.core.service.UploadCancellations
import com.oshinobu.core.storage.AppDirs
import com.oshinobu.core.storage.ChatStore
import com.oshinobu.core.storage.ChunkedUploadSessionStore
import com.oshinobu.core.storage.DownloadQueueStore
import com.oshinobu.core.storage.InMemoryPrefs
import com.oshinobu.core.storage.InMemorySecureStore
import com.oshinobu.core.storage.KeyStore
import com.oshinobu.core.storage.MediaFiles
import com.oshinobu.core.storage.MessageStatus
import com.oshinobu.core.storage.PeerAccountStore
import com.oshinobu.core.storage.PeerIdentityStore
import com.oshinobu.core.storage.PendingSendStore
import com.oshinobu.core.storage.SendQueueStore
import com.oshinobu.core.storage.Session
import com.oshinobu.core.storage.SessionStore
import com.oshinobu.core.storage.StoredMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.MultipartReader
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import java.io.File
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertTrue

/**
 * Стенд для сквозных тестов сервисов: фейковый сервер сообщений в памяти
 * (как websocket.go: ack отправителю при приёме, офлайн-очередь,
 * передоставка неподтверждённого) + MockWebServer с REST-эндпоинтами
 * ключей, владельца устройства и медиа (как upload_media*.go / download_media.go).
 */
class TestNetwork : AutoCloseable {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    var clock = 1_000_000L
    val relay = Relay()
    private val devices = ConcurrentHashMap<String, Device>()

    // ---------------- медиа на "сервере" ----------------

    /** media_id → шифротекст. */
    val mediaBlobs = ConcurrentHashMap<String, ByteArray>()
    private val chunkedUploads = ConcurrentHashMap<String, ConcurrentHashMap<Int, ByteArray>>()
    val receivedConfirmations = CopyOnWriteArrayList<String>()
    /** Сколько раз подряд ответить 500 на следующую загрузку части (проверка повторов). */
    val failNextParts = AtomicInteger(0)

    private val server = MockWebServer().apply {
        dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = runBlocking { route(request) }
        }
        start()
    }
    val api = ApiClient(ApiConfig(server.url("/").toString().trimEnd('/')))

    private suspend fun route(request: RecordedRequest): MockResponse {
        val path = request.path!!.substringBefore('?')
        val query = request.requestUrl!!
        return when {
            path.startsWith("/devices/") -> deviceRoute(path)
            path == "/upload-media" && request.method == "POST" -> {
                val bytes = multipartFile(request)
                val id = UUID.randomUUID().toString()
                mediaBlobs[id] = bytes
                MockResponse().setBody(id)
            }
            path == "/upload-media/init" -> {
                val id = UUID.randomUUID().toString()
                chunkedUploads[id] = ConcurrentHashMap()
                MockResponse().setBody(
                    buildJsonObject { put("media_id", id); put("upload_id", "local-$id"); put("part_size", 8 * 1024 * 1024) }.toString(),
                )
            }
            path.matches(Regex("/upload-media/[^/]+/part/\\d+")) -> {
                if (failNextParts.getAndUpdate { if (it > 0) it - 1 else 0 } > 0) return MockResponse().setResponseCode(500)
                val id = path.split('/')[2]
                chunkedUploads.getValue(id)[path.substringAfterLast('/').toInt()] = request.body.readByteArray()
                MockResponse()
            }
            path.endsWith("/parts") -> {
                val parts = chunkedUploads.getValue(path.split('/')[2])
                MockResponse().setBody(
                    JsonArray(parts.map { (n, b) -> buildJsonObject { put("part_number", n); put("size", b.size) } }).toString(),
                )
            }
            path.endsWith("/complete") -> {
                val id = path.split('/')[2]
                val parts = chunkedUploads.remove(id)!!
                mediaBlobs[id] = parts.toSortedMap().values.fold(ByteArray(0)) { acc, b -> acc + b }
                check(query.queryParameter("upload_id") == "local-$id")
                MockResponse().setBody(id)
            }
            path.matches(Regex("/media/[^/]+/received")) -> {
                receivedConfirmations += path.split('/')[2]
                MockResponse().setResponseCode(204)
            }
            path.startsWith("/media/") -> {
                val blob = mediaBlobs[path.removePrefix("/media/")] ?: return MockResponse().setResponseCode(404)
                if (request.method == "HEAD") return MockResponse().setHeader("Content-Length", blob.size)
                val range = request.getHeader("Range")?.removePrefix("bytes=")?.removeSuffix("-")?.toInt()
                if (range == null) {
                    MockResponse().setBody(Buffer().write(blob))
                } else {
                    MockResponse().setResponseCode(206)
                        .setHeader("Content-Range", "bytes $range-${blob.size - 1}/${blob.size}")
                        .setBody(Buffer().write(blob.copyOfRange(range, blob.size)))
                }
            }
            else -> MockResponse().setResponseCode(404)
        }
    }

    private fun multipartFile(request: RecordedRequest): ByteArray {
        val boundary = request.getHeader("Content-Type")!!.substringAfter("boundary=")
        MultipartReader(request.body, boundary).use { reader ->
            while (true) {
                val part = reader.nextPart() ?: error("в multipart нет файла")
                if ("filename=" in (part.headers["Content-Disposition"] ?: "")) return part.body.readByteArray()
            }
        }
    }

    private suspend fun deviceRoute(path: String): MockResponse {
        val deviceId = path.removePrefix("/devices/").substringBefore('/')
        val d = devices.values.firstOrNull { it.deviceId == deviceId } ?: return MockResponse().setResponseCode(404)
        return when {
            path.endsWith("/prekey-bundle") -> {
                val identity = d.keys.loadIdentity()!!
                val otp = identity.oneTimePrekeys.firstOrNull { b64(it.publicKey) !in d.handedOut }
                otp?.let { d.handedOut += b64(it.publicKey) }
                MockResponse().setBody(JsonObject(identity.bundle(otp) + ("account_id" to JsonPrimitive(d.accountId))).toString())
            }
            path.endsWith("/owner") -> MockResponse().setBody(
                buildJsonObject { put("account_id", d.accountId); put("login", d.login); put("display_name", d.login) }.toString(),
            )
            else -> MockResponse().setResponseCode(404)
        }
    }

    // ---------------- сервер сообщений ----------------

    class Relay {
        val clients = ConcurrentHashMap<String, FakeTransport>()
        /** deliveryId → (кому, кадр) — пока получатель не подтвердил. */
        val pending = ConcurrentHashMap<String, Pair<String, IncomingEnvelope>>()
        /** Все кадры, когда-либо разосланные получателям. */
        val delivered = CopyOnWriteArrayList<Pair<String, IncomingEnvelope>>()
        private val serverDelivery = AtomicInteger()

        fun send(from: FakeTransport, to: String, envelope: JsonObject, deliveryId: String) {
            from.acksFlow.tryEmit(deliveryId) // сервер принял — ack отправителю
            val frame = IncomingEnvelope(envelope, "srv-${serverDelivery.incrementAndGet()}")
            pending[frame.deliveryId!!] = to to frame
            delivered += to to frame
            clients[to]?.takeIf { it.isConnected }?.messagesFlow?.tryEmit(frame)
        }

        fun ack(deliveryId: String) {
            pending.remove(deliveryId)
        }

        /** Реконнект клиента: сервер досылает всё неподтверждённое. */
        fun flush(deviceId: String) {
            val c = clients[deviceId] ?: return
            pending.values.filter { it.first == deviceId }.forEach { c.messagesFlow.tryEmit(it.second) }
        }
    }

    class FakeTransport(private val relay: Relay) : Transport, CallSignaling {
        val callSignalsFlow = MutableSharedFlow<JsonObject>(extraBufferCapacity = 256)
        override val callSignals = callSignalsFlow

        /** Как сервер: Ciphertext → JSON + "type" (см. WebSocketClient). */
        override suspend fun sendCallSignal(toDeviceId: String, type: String, payload: JsonObject): Boolean {
            val to = relay.clients[toDeviceId]?.takeIf { it.isConnected } ?: return false
            return to.callSignalsFlow.tryEmit(JsonObject(payload + ("type" to JsonPrimitive(type))))
        }

        val statusFlow = MutableStateFlow(ConnectionStatus.CONNECTED)
        val messagesFlow = MutableSharedFlow<IncomingEnvelope>(extraBufferCapacity = 256)
        val acksFlow = MutableSharedFlow<String>(extraBufferCapacity = 256)
        override val status = statusFlow
        override val messages = messagesFlow
        override val acks = acksFlow
        override val isConnected get() = statusFlow.value == ConnectionStatus.CONNECTED

        override fun sendEnvelope(toDeviceId: String, envelope: JsonObject, deliveryId: String, silent: Boolean) {
            check(isConnected) { "WebSocket не подключен" }
            relay.send(this, toDeviceId, envelope, deliveryId)
        }

        override fun ackDelivery(deliveryId: String) = relay.ack(deliveryId)
    }

    class TestHost : RouterHost {
        override var openChatPeerLogin: String? = null
        override val isAppInForeground = true
        val sounds = AtomicInteger()
        override fun playMessageSound() {
            sounds.incrementAndGet()
        }
        override fun showBackgroundMessageNotification() = Unit
        override fun vibrate() = Unit
    }

    /** Клиент со всеми сервисами на хранилищах в памяти. */
    inner class Device(val login: String) {
        val accountId = "acc-$login"
        val deviceId = "dev-$login"
        val secure = InMemorySecureStore()
        val prefs = InMemoryPrefs()
        val dirs = Files.createTempDirectory("oshinobu-$login").toFile().let { root ->
            AppDirs(File(root, "documents").apply { mkdirs() }, File(root, "files").apply { mkdirs() }, File(root, "cache").apply { mkdirs() })
        }
        val keys = KeyStore(secure)
        val chats = ChatStore(secure, now = { clock })
        val sessions = SessionStore(secure)
        val transport = FakeTransport(relay)
        val host = TestHost()
        val sendLock = KeyedMutex()
        val acks = AckRegistry(transport, scope)
        val sendQueueStore = SendQueueStore(secure)
        val queue = SendQueueProcessor(sendQueueStore, transport, acks, chats, scope, ackTimeoutMs = 2_000)
        val session = Session(prefs).apply { token = "token-$login"; accountId = this@Device.accountId }
        val media = MediaFiles(dirs)
        val chunkedSessions = ChunkedUploadSessionStore(secure)
        val pendingStore = PendingSendStore(secure, dirs)
        val cancellations = UploadCancellations()
        val cleanup = MessageCleanup(chats, media, dirs, chunkedSessions, pendingStore, sendQueueStore, acks, cancellations::cancel)
        val messenger = PeerMessenger(api, session, keys, sessions, PeerAccountStore(secure), PeerIdentityStore(secure), chats, queue, sendLock)
        val router = MessageRouter(
            transport, api, session, keys, sessions, PeerAccountStore(secure), PeerIdentityStore(secure), chats, prefs, queue, cleanup,
            sendLock, host, scope, now = { clock },
        )
        val uploader = MediaUploader(api, chats, dirs, chunkedSessions, media, firstRetryDelayMs = 50)
        val retrier = PendingSendRetrier(
            pendingStore, chats, session, PeerAccountStore(secure), chunkedSessions, uploader, messenger, cleanup, cancellations, scope,
        )
        val chatService = ChatService(chats, messenger, router, cleanup, pendingStore, retrier)
        val rtc = FakeRtcEngine()
        val calls = CallManager(transport, messenger, router, api, session, chats, rtc, scope, now = { clock }, endReasonDelayMs = 50)
        fun peerOf(other: Device) = ChatPeer(other.login, other.accountId, other.deviceId)
        val downloads = MediaDownloadManager(api, session, media, DownloadQueueStore(secure), scope, now = { clock }, firstRetryDelayMs = 50)
        /** Публичные части одноразовых ключей, уже выданных сервером в бандлах. */
        val handedOut: MutableSet<String> = ConcurrentHashMap.newKeySet()

        suspend fun start() {
            val me = keys.getOrCreateIdentity()
            keys.createSignedPrekey(me.identity)
            keys.createOneTimePrekeys(5)
            keys.saveDeviceId(deviceId)
            relay.clients[deviceId] = transport
            queue.start()
            router.start()
            retrier.start()
            downloads.init()
            calls.start()
        }

        /** Отправить текст так же, как это делает экран чата. */
        suspend fun sendText(to: Device, text: String): InnerMessage {
            val inner = InnerMessage.text(text)
            chats.addMessage(to.login, StoredMessage(inner.messageId, text, true, inner.sentAt, status = MessageStatus.SENDING))
            messenger.send(to.deviceId, inner, peerLogin = to.login)
            return inner
        }

        fun tempFile(name: String, bytes: ByteArray): File = File(dirs.temp, name).apply { writeBytes(bytes) }
    }

    suspend fun device(login: String): Device = Device(login).also {
        devices[login] = it
        it.start()
    }

    suspend fun eventually(what: String, check: suspend () -> Boolean) {
        withTimeout(20_000) {
            while (!check()) delay(20)
        }
        assertTrue(check(), what)
    }

    override fun close() {
        scope.cancel()
        server.shutdown()
    }
}
