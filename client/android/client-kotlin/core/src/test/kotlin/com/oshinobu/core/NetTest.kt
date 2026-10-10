package com.oshinobu.core

import com.oshinobu.core.net.ApiClient
import com.oshinobu.core.net.ApiConfig
import com.oshinobu.core.net.ApiException
import com.oshinobu.core.net.ConnectionStatus
import com.oshinobu.core.net.WebSocketClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class NetTest {
    private lateinit var server: MockWebServer
    private lateinit var api: ApiClient

    @BeforeTest
    fun setUp() {
        server = MockWebServer()
        server.start()
        api = ApiClient(ApiConfig(server.url("/").toString().trimEnd('/')))
    }

    @AfterTest
    fun tearDown() = server.shutdown()

    private fun RecordedRequest.json() = Json.parseToJsonElement(body.readUtf8()).jsonObject

    @Test
    fun `login — тело запроса и разбор ответа`() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"token":"tok","language":"ru"}"""))
        val r = api.login("alice", "pw", "123456")
        assertEquals("tok", r.token)
        assertEquals("ru", r.language)
        val req = server.takeRequest()
        assertEquals("/login", req.path)
        assertEquals(
            mapOf("login" to "alice", "password" to "pw", "totp_code" to "123456"),
            req.json().mapValues { it.value.jsonPrimitive.content },
        )
    }

    @Test
    fun `сессию отменяет только 401 — устаревшая версия и сбои сервера не выход`() = runBlocking {
        for ((code, expected) in listOf(200 to true, 401 to false, 426 to null, 502 to null, 500 to null)) {
            server.enqueue(MockResponse().setResponseCode(code).setBody("{}"))
            assertEquals(expected, api.checkSession("tok"), "HTTP $code")
        }
    }

    @Test
    fun `коды ошибок превращаются в ключи локализации`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(429))
        assertEquals("error.tooManyLoginAttempts", assertFailsWith<ApiException> { api.login("a", "b", "c") }.errorKey)
        server.enqueue(MockResponse().setResponseCode(409))
        assertEquals("error.loginTaken", assertFailsWith<ApiException> { api.register("a", "b", "c") }.errorKey)
        server.enqueue(MockResponse().setResponseCode(422))
        assertEquals("error.inviteCodeInvalid", assertFailsWith<ApiException> { api.register("a", "b", "c") }.errorKey)
    }

    @Test
    fun `загрузка файла — multipart как во Flutter и прогресс до 100`() = runBlocking {
        server.enqueue(MockResponse().setBody("media-123"))
        val tmp = Files.createTempFile("enc", ".bin").toFile().apply { writeBytes(ByteArray(300_000) { it.toByte() }) }
        val progress = CopyOnWriteArrayList<Double>()
        val id = api.uploadEncryptedMediaFile("tok", tmp, "acc-1") { progress += it }
        assertEquals("media-123", id)
        val req = server.takeRequest()
        assertEquals("Bearer tok", req.getHeader("Authorization"))
        val body = req.body.readUtf8()
        assertTrue("name=\"recipient_account_id\"" in body && "acc-1" in body)
        assertTrue("filename=\"encrypted.bin\"" in body)
        assertEquals(100.0, progress.last(), 0.001)
        tmp.delete()
        Unit
    }

    @Test
    fun `скачивание с докачкой по Range`() = runBlocking {
        val full = ByteArray(10_000) { (it * 13).toByte() }
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val range = request.getHeader("Range") ?: return MockResponse().setBody(Buffer().write(full))
                val start = range.removePrefix("bytes=").removeSuffix("-").toInt()
                return MockResponse().setResponseCode(206)
                    .setHeader("Content-Range", "bytes $start-${full.size - 1}/${full.size}")
                    .setBody(Buffer().write(full.copyOfRange(start, full.size)))
            }
        }
        val dest = Files.createTempFile("part", ".bin").toFile().apply { writeBytes(full.copyOfRange(0, 4000)) }
        val total = api.downloadEncryptedMediaResumable("tok", "m1", dest, knownTotalBytes = full.size.toLong())
        assertEquals(full.size.toLong(), total)
        assertContentEquals(full, dest.readBytes())
        assertEquals("bytes=4000-", server.takeRequest().getHeader("Range"))
        dest.delete()
        Unit
    }

    /** Фейковый сервер для WebSocket: /ws апгрейдится, /session/check отвечает [sessionCode]. */
    private inner class FakeWsServer(var sessionCode: Int = 200) {
        val serverSockets = LinkedBlockingQueue<WebSocket>()
        val received = LinkedBlockingQueue<String>()
        val upgrades = AtomicInteger()
        val wsRequests = CopyOnWriteArrayList<RecordedRequest>()

        init {
            server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = when {
                    request.path!!.startsWith("/ws") -> {
                        upgrades.incrementAndGet()
                        wsRequests += request
                        MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                            override fun onOpen(webSocket: WebSocket, response: Response) {
                                serverSockets.put(webSocket)
                            }

                            override fun onMessage(webSocket: WebSocket, text: String) {
                                received.put(text)
                            }
                        })
                    }
                    request.path == "/session/check" -> MockResponse().setResponseCode(sessionCode)
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }

        fun nextSocket(): WebSocket = serverSockets.poll(5, TimeUnit.SECONDS)!!

        /** Следующий кадр от клиента, кроме служебного presence_foreground. */
        fun nextFrame(): JsonObject {
            while (true) {
                val text = received.poll(5, TimeUnit.SECONDS)!!
                val o = Json.parseToJsonElement(text).jsonObject
                if (o["Type"]?.jsonPrimitive?.content != "presence_foreground") return o
            }
        }
    }

    private fun newWs(scope: CoroutineScope) = WebSocketClient(api, scope, reconnectDelayMs = 200, readyTimeoutMs = 3_000)

    @Test
    fun `WebSocket — подключение, входящие кадры, отправка`() = runBlocking {
        val fake = FakeWsServer()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val ws = newWs(scope)
        try {
            ws.connect("tok", "dev-1")
            val serverSide = fake.nextSocket()
            withTimeout(5_000) { ws.status.first { it == ConnectionStatus.CONNECTED } }
            val req = fake.wsRequests.first()
            assertEquals("/ws?device_id=dev-1", req.path)
            assertEquals("Bearer tok", req.getHeader("Authorization"))

            // ack на наш конверт
            val ackWait = async(start = CoroutineStart.UNDISPATCHED) { withTimeout(5_000) { ws.acks.first() } }
            serverSide.send("""{"Type":"ack","DeliveryId":"d-1"}""")
            assertEquals("d-1", ackWait.await())

            // входящий конверт — DeliveryId рядом, без авто-ack
            val msgWait = async(start = CoroutineStart.UNDISPATCHED) { withTimeout(5_000) { ws.messages.first() } }
            serverSide.send("""{"Type":"message","DeliveryId":"in-1","Ciphertext":"{\"nonce\":\"x\"}"}""")
            val incoming = msgWait.await()
            assertEquals("in-1", incoming.deliveryId)
            assertEquals("x", incoming.envelope["nonce"]!!.jsonPrimitive.content)

            // сигнал звонка — ack уходит сразу
            val callWait = async(start = CoroutineStart.UNDISPATCHED) { withTimeout(5_000) { ws.callSignals.first() } }
            serverSide.send("""{"Type":"call_offer","DeliveryId":"c-1","Ciphertext":"{\"call_id\":\"42\"}"}""")
            val signal = callWait.await()
            assertEquals("call_offer", signal["type"]!!.jsonPrimitive.content)
            assertEquals("42", signal["call_id"]!!.jsonPrimitive.content)
            val ack = fake.nextFrame()
            assertEquals("ack", ack["Type"]!!.jsonPrimitive.content)
            assertEquals("c-1", ack["DeliveryId"]!!.jsonPrimitive.content)

            // отправка конверта — формат как во Flutter
            ws.sendEnvelope("dev-2", JsonObject(mapOf("nonce" to JsonPrimitive("n"))), "out-1", silent = true)
            val sent = fake.nextFrame()
            assertEquals("message", sent["Type"]!!.jsonPrimitive.content)
            assertEquals("dev-2", sent["ToDeviceId"]!!.jsonPrimitive.content)
            assertEquals("out-1", sent["DeliveryId"]!!.jsonPrimitive.content)
            assertEquals("true", sent["Silent"]!!.jsonPrimitive.content)
            assertEquals("""{"nonce":"n"}""", sent["Ciphertext"]!!.jsonPrimitive.content)
        } finally {
            ws.disconnect()
            scope.cancel()
        }
    }

    @Test
    fun `WebSocket — переподключение после обрыва`() = runBlocking {
        val fake = FakeWsServer(sessionCode = 200)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val ws = newWs(scope)
        try {
            ws.connect("tok", "dev-1")
            fake.nextSocket().close(1001, "bye")
            fake.nextSocket() // второе соединение
            withTimeout(5_000) { ws.status.first { it == ConnectionStatus.CONNECTED } }
            assertEquals(2, fake.upgrades.get())
        } finally {
            ws.disconnect()
            scope.cancel()
        }
    }

    @Test
    fun `WebSocket — сессия недействительна, переподключения нет`() = runBlocking {
        val fake = FakeWsServer(sessionCode = 401)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val ws = newWs(scope)
        try {
            val invalidWait = async(start = CoroutineStart.UNDISPATCHED) { withTimeout(5_000) { ws.sessionInvalidated.first() } }
            ws.connect("tok", "dev-1")
            fake.nextSocket().close(1001, "bye")
            invalidWait.await()
            Thread.sleep(600)
            assertEquals(1, fake.upgrades.get())
        } finally {
            ws.disconnect()
            scope.cancel()
        }
    }

    @Suppress("unused")
    private fun File.cleanup() = delete()
}
