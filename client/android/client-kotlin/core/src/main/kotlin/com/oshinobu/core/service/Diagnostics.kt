package com.oshinobu.core.service

import com.oshinobu.core.net.ApiClient
import com.oshinobu.core.storage.AppDirs
import com.oshinobu.core.storage.Prefs
import com.oshinobu.core.storage.Session
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
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
    private val queue = Channel<Entry>(Channel.UNLIMITED)
    @Volatile
    private var onError: (() -> Unit)? = null

    private sealed interface Entry {
        class Line(val text: String) : Entry

        /** Всё, что встало в очередь раньше, уже в файле. */
        class Flushed(val done: CompletableDeferred<Unit>) : Entry
    }

    init {
        scope.launch {
            for (entry in queue) {
                when (entry) {
                    is Entry.Line -> append(entry.text)
                    is Entry.Flushed -> entry.done.complete(Unit)
                }
            }
        }
    }

    /** Дождаться, пока всё уже записанное в журнал ляжет в файл (перед отправкой журнала). */
    suspend fun flush() {
        val done = CompletableDeferred<Unit>()
        queue.send(Entry.Flushed(done))
        done.await()
    }

    fun setErrorHook(hook: () -> Unit) {
        onError = hook
    }

    override fun log(message: String) {
        queue.trySend(Entry.Line("${LocalDateTime.now()} $message\n"))
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
 * Отчёт о падении приложения, который обязан дойти до сервера. Пишется
 * синхронно — прямо из обработчика падения, пока процесс ещё жив (журнал
 * [FileLogger] пишет в фоне, и последние строки перед смертью процесса
 * теряет), или при следующем запуске — о нативном падении, которое Java не
 * ловит. Отправляет [CrashReporter]; удаляется только после ответа сервера.
 */
class CrashStore(dirs: AppDirs, private val maxBytes: Long = 512 * 1024) {
    val file = File(dirs.documents, "pending_crash.txt")

    @Synchronized
    fun record(report: String) {
        try {
            file.appendText(report.trimEnd() + "\n\n")
            if (file.length() > maxBytes) {
                val bytes = file.readBytes()
                file.writeBytes(bytes.copyOfRange(bytes.size - maxBytes.toInt(), bytes.size))
            }
        } catch (_: Exception) {
            // отчёт о падении не должен ронять приложение ещё раз
        }
    }

    @Synchronized
    fun pending(): String? = try {
        file.takeIf { it.exists() }?.readText()?.takeIf { it.isNotBlank() }
    } catch (_: Exception) {
        null
    }

    @Synchronized
    fun clear() {
        file.delete()
    }
}

/**
 * Автоотправка журнала (kind=auto_crash) в двух случаях:
 *  - ошибка в работе (порт crash_reporter.dart): не чаще раза в 30 минут
 *    (отметка в prefs — переживает перезапуск посреди цикла ошибок),
 *    последние 500 КБ; после успеха журнал очищается;
 *  - падение приложения ([CrashStore]): всегда, без ограничения частоты, при
 *    первой возможности — при запуске сессии и при каждом подключении к
 *    серверу, пока сервер не подтвердит; вместе с журналом перед падением.
 */
class CrashReporter(
    private val logger: FileLogger,
    private val crashes: CrashStore,
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
    private val sendingCrash = AtomicBoolean(false)

    fun install() = logger.setErrorHook { if (sending.compareAndSet(false, true)) scope.launch { report() } }

    /** Отправить записанное падение, если оно есть (повторный вызов во время отправки — пропуск). */
    fun sendPendingCrash() {
        if (!sendingCrash.compareAndSet(false, true)) return
        scope.launch {
            try {
                deliverCrash()
            } finally {
                sendingCrash.set(false)
            }
        }
    }

    private suspend fun deliverCrash() {
        val crash = crashes.pending() ?: return
        val token = session.token ?: return
        logger.flush()
        val context = runCatching { logger.file.readText() }.getOrDefault("")
            .takeLast((MAX_UPLOAD_CHARS - crash.length).coerceAtLeast(0))
        try {
            api.reportCrashLog(token, "=== CRASH ===\n$crash\n=== журнал перед падением ===\n$context")
            crashes.clear()
            logger.log("Crash report delivered")
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            logger.log("Crash report not delivered yet: $e")
        }
    }

    private suspend fun report() {
        try {
            val last = prefs.getLong(LAST_SENT_KEY)
            if (last != null && now() - last < MIN_INTERVAL_MS) return
            val token = session.token ?: return
            // ошибка, разбудившая отправку, могла ещё не дойти до файла
            logger.flush()
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
