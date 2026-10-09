package com.oshinobu.core.service

import com.oshinobu.core.net.Transport
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.ConcurrentHashMap

/**
 * Диагностический журнал (на Android — DebugLog: файл + автоотправка ошибок).
 * [log] — обычная строка-хлебная крошка, [error] — настоящая ошибка, будит
 * отправку отчёта. НИКОГДА не писать сюда текст переписки и ключи.
 */
interface Logger {
    fun log(message: String)
    fun error(message: String)
}

object NoopLogger : Logger {
    override fun log(message: String) = Unit
    override fun error(message: String) = Unit
}

/**
 * Последовательное выполнение по ключу (порт SendLock). Ключ — device_id
 * собеседника: входящая расшифровка и исходящая отправка для ОДНОГО
 * устройства обязаны не пересекаться — у них общее состояние ratchet.
 */
class KeyedMutex {
    private val locks = ConcurrentHashMap<String, Mutex>()

    suspend fun <T> run(key: String, action: suspend () -> T): T = locks.getOrPut(key) { Mutex() }.withLock { action() }
}

/** Ожидание ack сервера по deliveryId (порт SendAckRegistry). */
class AckRegistry(transport: Transport, scope: CoroutineScope) {
    private val waiters = ConcurrentHashMap<String, CompletableDeferred<Unit>>()

    init {
        scope.launch { transport.acks.collect { fulfill(it) } }
    }

    fun waiter(deliveryId: String): CompletableDeferred<Unit> = waiters.getOrPut(deliveryId) { CompletableDeferred() }

    fun fulfill(deliveryId: String) {
        waiters.remove(deliveryId)?.complete(Unit)
    }

    fun cancel(deliveryId: String) {
        waiters.remove(deliveryId)?.cancel()
    }
}

/** Повтор до успеха с нарастающей паузой 1 → 30 с (retry_until_success.dart). */
suspend fun retryUntilSuccess(action: suspend () -> Unit) {
    var delayMs = 1_000L
    while (true) {
        try {
            action()
            return
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            delay(delayMs)
            delayMs = (delayMs * 2).coerceAtMost(30_000)
        }
    }
}

/** Загрузка этого сообщения отменена пользователем. */
class UploadCancelledException(val messageId: String) : Exception("загрузка $messageId отменена")

/**
 * Отмена идущей загрузки конкретного сообщения (порт UploadCancelRegistry):
 * загрузка выполняется дочерней корутиной, [cancel] гасит только её — не
 * весь рабочий цикл очереди файлов.
 */
class UploadCancellations {
    private val running = ConcurrentHashMap<String, Job>()

    /** Бросает [UploadCancelledException], если загрузку отменили через [cancel]. */
    suspend fun <T> run(messageId: String, block: suspend () -> T): T = coroutineScope {
        val work = async { block() }
        running[messageId] = work
        try {
            work.await()
        } catch (e: CancellationException) {
            // отменили именно эту загрузку, а не всю корутину-владельца
            if (work.isCancelled && isActive) throw UploadCancelledException(messageId)
            throw e
        } finally {
            running.remove(messageId, work)
        }
    }

    fun cancel(messageId: String) {
        running[messageId]?.cancel()
    }
}
