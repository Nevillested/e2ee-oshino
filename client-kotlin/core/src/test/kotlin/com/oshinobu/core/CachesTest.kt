package com.oshinobu.core

import com.oshinobu.core.net.ApiClient
import com.oshinobu.core.net.ApiConfig
import com.oshinobu.core.service.CrashReporter
import com.oshinobu.core.service.FileLogger
import com.oshinobu.core.service.RemoteCache
import com.oshinobu.core.storage.AppDirs
import com.oshinobu.core.storage.InMemoryPrefs
import com.oshinobu.core.storage.Session
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class CachesTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val dir: File = Files.createTempDirectory("caches").toFile()
    private var clock = 0L

    @AfterTest
    fun tearDown() = scope.cancel()

    private fun cache(fetch: suspend (String) -> String?) = RemoteCache(
        scope = scope,
        diskFile = { File(dir, "c_$it") },
        encode = { it.toByteArray() },
        decode = { it.decodeToString() },
        fetch = fetch,
        now = { clock },
    )

    @Test
    fun `свежее из памяти, просроченное — в сеть, сбой сети не затирает значение`() = runBlocking {
        val calls = AtomicInteger()
        var fail = false
        val c = cache { calls.incrementAndGet(); if (fail) throw IOException("нет сети") else "v${calls.get()}" }
        assertEquals("v1", c.get("a"))
        assertEquals("v1", c.get("a"))
        assertEquals(1, calls.get())
        clock += 4 * 60_000
        fail = true
        assertEquals("v1", c.get("a"), "при сбое — последнее известное")
        fail = false
        assertEquals("v3", c.get("a"))
    }

    @Test
    fun `холодный старт — сразу копия с диска, свежее фоном с уведомлением`() = runBlocking {
        File(dir, "c_b").writeText("с диска")
        val c = cache { "с сервера" }
        val changed = async(start = CoroutineStart.UNDISPATCHED) { withTimeout(5_000) { c.changes.first() } }
        assertEquals("с диска", c.get("b"))
        assertEquals("b", changed.await())
        assertEquals("с сервера", c.peek("b"))
        assertEquals("с сервера", File(dir, "c_b").readText())
    }

    @Test
    fun `одновременные запросы — один поход в сеть, invalidate отбрасывает устаревший ответ`() = runBlocking {
        val calls = AtomicInteger()
        val gate = CompletableDeferred<Unit>()
        val c = cache { calls.incrementAndGet(); gate.await(); "старое" }
        val a = async { c.get("k") }
        val b = async { c.get("k") }
        delay(100)
        c.invalidate("k") // пока запрос летит, значение на сервере сменилось
        gate.complete(Unit)
        assertEquals("старое", a.await())
        assertEquals("старое", b.await())
        assertEquals(1, calls.get())
        assertEquals(null, c.peek("k"), "устаревший ответ в кэш не попал")
    }

    @Test
    fun `журнал держит размер, ошибка отправляет его не чаще раза в 30 минут`() = runBlocking {
        val server = MockWebServer().apply { start() }
        try {
            val dirs = AppDirs(dir, dir, dir)
            val logger = FileLogger(dirs, scope, maxBytes = 2_000)
            repeat(200) { logger.log("строка номер $it без секретов") }
            withTimeout(5_000) { while (!logger.file.exists() || logger.file.length() == 0L) delay(10) }
            delay(200)
            assertTrue(logger.file.length() <= 2_000)

            val prefs = InMemoryPrefs()
            val api = ApiClient(ApiConfig(server.url("/").toString().trimEnd('/')))
            CrashReporter(logger, api, Session(prefs).apply { token = "t" }, prefs, scope, now = { clock }).install()
            server.enqueue(MockResponse())
            logger.error("сбой расшифровки")
            val first = server.takeRequest(5, TimeUnit.SECONDS)!!
            assertEquals("/feedback", first.path)
            assertTrue("auto_crash" in first.body.readUtf8())
            withTimeout(5_000) { while (logger.file.exists()) delay(10) }

            logger.error("ещё один сбой через минуту")
            clock += 60_000
            delay(300)
            assertEquals(1, server.requestCount, "второй отчёт раньше 30 минут не уходит")
        } finally {
            server.shutdown()
        }
    }
}
