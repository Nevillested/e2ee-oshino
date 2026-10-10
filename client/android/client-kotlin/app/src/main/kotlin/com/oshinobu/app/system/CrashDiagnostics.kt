package com.oshinobu.app.system

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.os.Build
import com.oshinobu.app.OshinobuApp
import com.oshinobu.app.ui.update.installedVersionCode
import java.io.PrintWriter
import java.io.StringWriter
import java.util.Date

/**
 * Падения приложения — на сервер (auto_crash, пункт "отзывы" в админ-утилите),
 * без исключений:
 *  - Java/Kotlin-исключение — полный стек пишется в [CrashStore] синхронно,
 *    прямо в обработчике, пока процесс ещё жив;
 *  - падение в нативном коде (WebRTC и т. п.) и ANR Java не ловит — процесс
 *    умирает молча; Android 11+ помнит причину, при следующем запуске она
 *    читается и тоже уходит в [CrashStore] (для нативного на Android 12+ — с
 *    сигналом, стеком упавшего потока и последними строками логов
 *    приложения из tombstone).
 * Отправляет ядро ([CrashReporter]) — при каждом подключении к серверу, пока
 * сервер не примет.
 */
object CrashDiagnostics {
    private const val LAST_SEEN_KEY = "exit_diagnostics_last_seen_ms"
    private const val ANR_TRACE_CHARS = 16_000

    fun install(app: OshinobuApp) {
        app.core.logger.log(deviceLine(app))
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            runCatching {
                val stack = StringWriter().also { error.printStackTrace(PrintWriter(it)) }.toString()
                app.core.crashes.record("Uncaught exception on thread \"${thread.name}\" at ${Date()}\n${deviceLine(app)}\n$stack")
                app.core.logger.log("Uncaught on ${thread.name}: $error")
            }
            previous?.uncaughtException(thread, error)
        }
        recordPreviousExits(app)
    }

    private fun deviceLine(app: OshinobuApp) =
        "Device: ${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT}), app ${app.installedVersionCode()}"

    /** Нативные падения и ANR прошлых запусков (Java-исключения уже записал обработчик). */
    private fun recordPreviousExits(app: OshinobuApp) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val prefs = app.core.prefs
        val lastSeen = prefs.getLong(LAST_SEEN_KEY) ?: 0L
        val exits = runCatching {
            app.getSystemService(ActivityManager::class.java).getHistoricalProcessExitReasons(app.packageName, 0, 5)
        }.getOrDefault(emptyList()).filter { it.timestamp > lastSeen }
        exits.maxOfOrNull { it.timestamp }?.let { prefs.setLong(LAST_SEEN_KEY, it) }
        // при первом запуске с этой проверкой уходят и падения прошлых версий — они и нужны
        for (exit in exits.sortedBy { it.timestamp }) {
            val details = when (exit.reason) {
                ApplicationExitInfo.REASON_CRASH_NATIVE -> "Native crash\n${nativeTrace(exit)}"
                ApplicationExitInfo.REASON_ANR -> "ANR (app not responding)\n${anrTrace(exit)}"
                else -> continue
            }
            app.core.crashes.record("Previous run died at ${Date(exit.timestamp)}: ${exit.description}\n${deviceLine(app)}\n$details")
        }
    }

    private fun anrTrace(exit: ApplicationExitInfo): String =
        runCatching { exit.traceInputStream?.use { it.readBytes().decodeToString().take(ANR_TRACE_CHARS) } }.getOrNull() ?: "(no trace)"

    private fun nativeTrace(exit: ApplicationExitInfo): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return "(no tombstone before Android 12)"
        val bytes = runCatching { exit.traceInputStream?.use { it.readBytes() } }.getOrNull() ?: return "(no tombstone)"
        return runCatching { Tombstone.describe(bytes) }.getOrElse { "(tombstone unreadable: $it)" }
    }
}

/**
 * Разбор tombstone (системный отчёт о нативном падении, protobuf, Android
 * 12+; схема — system/core/debuggerd/proto/tombstone.proto) — только то,
 * что нужно для поиска причины: сигнал, abort-сообщение, причины, стек
 * упавшего потока и последние строки логов приложения перед падением.
 */
private object Tombstone {
    private const val MAX_LOG_LINES = 60

    private class Frame(val pc: Long, val function: String, val offset: Long, val file: String)

    fun describe(bytes: ByteArray): String {
        var tid = 0L
        var signal = ""
        var abort = ""
        val causes = ArrayList<String>()
        val threads = HashMap<Long, Pair<String, List<Frame>>>()
        val logs = ArrayList<String>()
        Proto(bytes).forEach { field, value ->
            when (field) {
                6 -> tid = value.long
                10 -> signal = signalInfo(value.message)
                14 -> abort = value.string
                15 -> Proto(value.message).forEach { f, v -> if (f == 1) causes += v.string }
                16 -> mapEntryThread(value.message)?.let { (id, thread) -> threads[id] = thread }
                18 -> logBuffer(value.message, logs)
            }
        }
        return buildString {
            appendLine("signal: $signal")
            if (abort.isNotEmpty()) appendLine("abort: $abort")
            causes.forEach { appendLine("cause: $it") }
            val (name, frames) = threads[tid] ?: ("?" to emptyList())
            appendLine("crashed thread $tid \"$name\":")
            frames.forEachIndexed { i, fr ->
                val fn = if (fr.function.isNotEmpty()) " (${fr.function}+${fr.offset})" else ""
                appendLine("  #%02d pc %016x  %s%s".format(i, fr.pc, fr.file, fn))
            }
            if (logs.isNotEmpty()) {
                appendLine("last log lines:")
                logs.takeLast(MAX_LOG_LINES).forEach { appendLine("  $it") }
            }
        }
    }

    private fun signalInfo(bytes: ByteArray): String {
        var name = ""
        var code = ""
        var fault = -1L
        Proto(bytes).forEach { f, v ->
            when (f) {
                2 -> name = v.string
                4 -> code = v.string
                9 -> fault = v.long
            }
        }
        return "$name $code" + if (fault >= 0) " fault addr 0x%x".format(fault) else ""
    }

    /** Запись map<uint32, Thread>: key = 1, value = 2. */
    private fun mapEntryThread(bytes: ByteArray): Pair<Long, Pair<String, List<Frame>>>? {
        var key = -1L
        var thread: Pair<String, List<Frame>>? = null
        Proto(bytes).forEach { f, v ->
            when (f) {
                1 -> key = v.long
                2 -> thread = thread(v.message)
            }
        }
        return thread?.let { key to it }
    }

    private fun thread(bytes: ByteArray): Pair<String, List<Frame>> {
        var name = ""
        val frames = ArrayList<Frame>()
        Proto(bytes).forEach { f, v ->
            when (f) {
                2 -> name = v.string
                4 -> frames += frame(v.message)
            }
        }
        return name to frames
    }

    private fun frame(bytes: ByteArray): Frame {
        var pc = 0L
        var function = ""
        var offset = 0L
        var file = ""
        Proto(bytes).forEach { f, v ->
            when (f) {
                1 -> pc = v.long // rel_pc — по нему стек сверяется с символами библиотеки
                4 -> function = v.string
                5 -> offset = v.long
                6 -> file = v.string
            }
        }
        return Frame(pc, function, offset, file)
    }

    /** LogBuffer { name = 1; repeated LogMessage logs = 2 }, LogMessage { timestamp = 1; ... tag = 5; message = 6 }. */
    private fun logBuffer(bytes: ByteArray, out: MutableList<String>) {
        Proto(bytes).forEach { f, v ->
            if (f != 2) return@forEach
            var time = ""
            var tag = ""
            var message = ""
            Proto(v.message).forEach { lf, lv ->
                when (lf) {
                    1 -> time = lv.string
                    5 -> tag = lv.string
                    6 -> message = lv.string
                }
            }
            out += "$time $tag: ${message.trimEnd()}"
        }
    }
}

/** Минимальное чтение protobuf: поля верхнего уровня одного сообщения. */
private class Proto(private val bytes: ByteArray) {
    class Value(val long: Long, private val raw: ByteArray?) {
        val message: ByteArray get() = raw ?: ByteArray(0)
        val string: String get() = raw?.decodeToString() ?: ""
    }

    private var pos = 0

    private fun varint(): Long {
        var result = 0L
        var shift = 0
        while (true) {
            val b = bytes[pos++].toInt() and 0xff
            result = result or ((b and 0x7f).toLong() shl shift)
            if (b and 0x80 == 0) return result
            shift += 7
            require(shift < 64) { "bad varint" }
        }
    }

    private fun fixed(size: Int): Long {
        var result = 0L
        for (i in 0 until size) result = result or ((bytes[pos + i].toLong() and 0xff) shl (8 * i))
        pos += size
        return result
    }

    fun forEach(block: (field: Int, value: Value) -> Unit) {
        while (pos < bytes.size) {
            val key = varint()
            val field = (key ushr 3).toInt()
            val value = when ((key and 7).toInt()) {
                0 -> Value(varint(), null)
                1 -> Value(fixed(8), null)
                2 -> {
                    val len = varint().toInt()
                    require(len >= 0 && pos + len <= bytes.size) { "bad length" }
                    Value(0, bytes.copyOfRange(pos, pos + len)).also { pos += len }
                }
                5 -> Value(fixed(4), null)
                else -> error("unsupported wire type")
            }
            block(field, value)
        }
    }
}
