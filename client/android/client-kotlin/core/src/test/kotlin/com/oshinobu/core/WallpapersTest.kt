package com.oshinobu.core

import com.oshinobu.core.net.ApiClient
import com.oshinobu.core.net.ApiConfig
import com.oshinobu.core.service.Wallpapers
import com.oshinobu.core.storage.AppDirs
import com.oshinobu.core.storage.InMemoryPrefs
import com.oshinobu.core.storage.Session
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import java.io.File
import java.nio.file.Files
import java.util.concurrent.ConcurrentHashMap
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WallpapersTest {
    private lateinit var server: MockWebServer
    private lateinit var api: ApiClient
    private lateinit var root: File
    private val session = Session(InMemoryPrefs()).apply { token = "tok" }

    /** "Сервер": account_id собеседника → (версия, JPEG). */
    private val remote = ConcurrentHashMap<String, Pair<Long, ByteArray>>()
    private var version = 100L
    private var lastForPeer: String? = null
    @Volatile
    private var offline = false

    @BeforeTest
    fun setUp() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (offline) return MockResponse().setResponseCode(503)
                val path = request.path!!
                val peer = path.removePrefix("/chats/wallpapers").removePrefix("/")
                return when {
                    request.method == "GET" && peer.isEmpty() -> MockResponse().setBody(
                        remote.entries.joinToString(",", "{\"wallpapers\":[", "]}") { (id, v) -> "{\"peer_account_id\":\"$id\",\"version\":${v.first}}" },
                    )
                    request.method == "GET" -> remote[peer]?.let { MockResponse().setBody(Buffer().write(it.second)) } ?: MockResponse().setResponseCode(404)
                    request.method == "PUT" -> {
                        val body = request.body.readByteArray()
                        val text = body.decodeToString()
                        lastForPeer = Regex("name=\"for_peer\"\\r\\n(?:[^\\r\\n]*\\r\\n)*\\r\\n(\\d)").find(text)?.groupValues?.get(1)
                        // картинка — последняя часть multipart: между пустой строкой и границей
                        val start = text.indexOf("filename=\"wallpaper.jpg\"").let { text.indexOf("\r\n\r\n", it) + 4 }
                        val end = text.lastIndexOf("\r\n--")
                        val jpeg = body.copyOfRange(start, end)
                        version++
                        remote[peer] = version to jpeg
                        MockResponse().setBody("{\"peer_account_id\":\"$peer\",\"version\":$version}")
                    }
                    request.method == "DELETE" -> {
                        remote.remove(peer)
                        MockResponse()
                    }
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }
        server.start()
        api = ApiClient(ApiConfig(server.url("/").toString().trimEnd('/')))
        root = Files.createTempDirectory("wallpapers").toFile()
    }

    @AfterTest
    fun tearDown() {
        server.shutdown()
        root.deleteRecursively()
    }

    private fun wallpapers() = Wallpapers(api, session, AppDirs(File(root, "docs"), File(root, "support"), File(root, "temp")))

    private val jpegA = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 1, 2, 3)
    private val jpegB = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 9, 9)

    @Test
    fun `установка — на сервер (и собеседнику по галочке) и сразу на устройство`() = runBlocking {
        val w = wallpapers()
        w.set("peer-1", jpegA, forPeer = true)
        assertEquals("1", lastForPeer)
        assertContentEquals(jpegA, remote.getValue("peer-1").second)
        val local = w.all.value.getValue("peer-1")
        assertEquals(remote.getValue("peer-1").first, local.version)
        assertContentEquals(jpegA, local.file.readBytes())

        w.set("peer-2", jpegB, forPeer = false)
        assertEquals("0", lastForPeer)

        w.remove("peer-1")
        assertNull(w.all.value["peer-1"])
        assertTrue(!remote.containsKey("peer-1"))
    }

    @Test
    fun `после переустановки — всё с сервера, сверка докачивает новое и убирает снятое`() = runBlocking {
        remote["peer-1"] = 1L to jpegA
        remote["peer-2"] = 2L to jpegB
        val w = wallpapers()
        w.sync()
        assertEquals(setOf("peer-1", "peer-2"), w.all.value.keys)
        assertContentEquals(jpegB, w.all.value.getValue("peer-2").file.readBytes())

        // собеседник поставил новые, peer-2 снял
        remote["peer-1"] = 5L to jpegB
        remote.remove("peer-2")
        w.sync()
        assertEquals(setOf("peer-1"), w.all.value.keys)
        assertEquals(5L, w.all.value.getValue("peer-1").version)
        assertContentEquals(jpegB, w.all.value.getValue("peer-1").file.readBytes())
    }

    @Test
    fun `без сети — остаётся копия на устройстве, перезапуск читает её с диска`() = runBlocking {
        remote["peer-1"] = 1L to jpegA
        wallpapers().sync()

        offline = true
        val restarted = wallpapers()
        restarted.load()
        restarted.sync()
        assertContentEquals(jpegA, restarted.all.value.getValue("peer-1").file.readBytes())
        assertFailsWith<Exception> { restarted.set("peer-2", jpegB, forPeer = false) }
        assertNull(restarted.all.value["peer-2"])

        restarted.reset()
        assertTrue(restarted.all.value.isEmpty())
        wallpapers().apply { load() }.let { assertTrue(it.all.value.isEmpty()) }
    }
}
