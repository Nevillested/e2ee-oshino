package com.oshinobu.core.service

import com.oshinobu.core.net.ApiClient
import com.oshinobu.core.storage.AppDirs
import com.oshinobu.core.storage.Prefs
import com.oshinobu.core.storage.Session
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import java.io.File
import java.time.LocalDateTime
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Журнал в файл documents/debug_log.txt (тот же, что у Flutter-клиента) —
 * одна строка на событие с локальным временем, файл держится в пределах
 * 1 МБ (при переполнении остаётся вторая половина). Запись — по очереди в
 * одной корутине. [error] дополнительно будит [CrashReporter].
 *
 * Гарантия журнала: только состояния, коды, device_id, счётчики и стек —
 * никогда текст переписки, ключи, PIN и токены.
 */
class FileLogger(dirs: AppDirs, scope: CoroutineScope, private val maxBytes: Long = 1024 * 1024) : Logger {
    val file = File(dirs.documents, "debug_log.txt")
    private val lines = Channel<String>(Channel.UNLIMITED)
    @Volatile
    private var onError: (() -> Unit)? = null

    init {
        scope.launch {
            for (line in lines) append(line)
        }
    }

    fun setErrorHook(hook: () -> Unit) {
        onError = hook
    }

    override fun log(message: String) {
        lines.trySend("${LocalDateTime.now()} $message\n")
    }

    override fun error(message: String) {
        log(message)
        onError?.invoke()
    }

    private fun append(line: String) {
        try {
            file.appendText(line)
            if (file.length() > maxBytes) {
                val bytes = file.readBytes()
                file.writeBytes(bytes.copyOfRange(bytes.size - (maxBytes / 2).toInt(), bytes.size))
            }
        } catch (_: Exception) {
            // журнал не должен ронять приложение
        }
    }

    fun clear() {
        file.delete()
    }
}

/**
 * Автоотправка журнала при ошибках (порт crash_reporter.dart): не чаще раза
 * в 30 минут (отметка в prefs — переживает перезапуск посреди цикла ошибок),
 * последние 500 КБ, только при наличии сессии; после успеха журнал очищается.
 */
class CrashReporter(
    private val logger: FileLogger,
    private val api: ApiClient,
    private val session: Session,
    private val prefs: Prefs,
    private val scope: CoroutineScope,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private companion object {
        const val MIN_INTERVAL_MS = 30 * 60_000L
        const val LAST_SENT_KEY = "crash_reporter_last_sent_at_ms"
        const val MAX_UPLOAD_CHARS = 500_000
    }

    private val sending = AtomicBoolean(false)

    fun install() = logger.setErrorHook { if (sending.compareAndSet(false, true)) scope.launch { report() } }

    private suspend fun report() {
        try {
            val last = prefs.getLong(LAST_SENT_KEY)
            if (last != null && now() - last < MIN_INTERVAL_MS) return
            val token = session.token ?: return
            if (!logger.file.exists()) return
            val text = logger.file.readText().trim().takeLast(MAX_UPLOAD_CHARS)
            if (text.isEmpty()) return
            api.reportCrashLog(token, text)
            prefs.setLong(LAST_SENT_KEY, now())
            logger.clear()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // нет сети — журнал остаётся до следующей ошибки
        } finally {
            sending.set(false)
        }
    }
}
