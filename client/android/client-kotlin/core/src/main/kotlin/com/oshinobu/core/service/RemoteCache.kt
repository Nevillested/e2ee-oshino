package com.oshinobu.core.service

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

/**
 * Кэш данных с сервера по ключу (account_id) — общая основа того, что во
 * Flutter было двумя почти одинаковыми классами (PeerProfileCache, AvatarCache):
 *  - свежее [ttlMs] значение отдаётся из памяти без сети;
 *  - при холодном старте отдаётся копия с диска СРАЗУ, а свежее тянется фоном
 *    ([changes] сообщит, если поменялось);
 *  - одновременные запросы одного ключа идут одним запросом;
 *  - сбой сети не затирает последнее известное значение;
 *  - [invalidate] (пришло "профиль изменился") — ответ уже летящего старого
 *    запроса в кэш не попадёт (поколения).
 * Значение null — "на сервере нет" (нет аватара / профиль скрыт) — тоже кэшируется.
 */
class RemoteCache<T : Any>(
    private val scope: CoroutineScope,
    private val diskFile: (String) -> File,
    private val encode: (T) -> ByteArray,
    private val decode: (ByteArray) -> T,
    /** Загрузить с сервера; null — на сервере нет; исключение — сбой сети. */
    private val fetch: suspend (String) -> T?,
    private val same: (T?, T?) -> Boolean = { a, b -> a == b },
    private val ttlMs: Long = 3 * 60_000,
    private val now: () -> Long = System::currentTimeMillis,
    private val log: Logger = NoopLogger,
) {
    private class Entry<T>(val value: T?, val at: Long)

    private val lock = Mutex()
    private val entries = HashMap<String, Entry<T>>()
    private val inFlight = HashMap<String, CompletableDeferred<Result<T?>>>()
    private val generation = HashMap<String, Int>()
    private val _changes = MutableSharedFlow<String>(extraBufferCapacity = 64)

    /** Ключ, значение которого обновилось (или сброшено) — повод перерисовать. */
    val changes: SharedFlow<String> = _changes.asSharedFlow()

    /** Что уже есть в памяти — без сети и диска (для первого кадра). */
    fun peek(key: String): T? = entries[key]?.value

    suspend fun get(key: String): T? {
        lock.withLock {
            entries[key]?.let { if (now() - it.at < ttlMs) return it.value }
        }
        if (lock.withLock { entries[key] == null }) {
            readDisk(key)?.let { fromDisk ->
                lock.withLock { entries[key] = Entry(fromDisk, now()) }
                scope.launch { refresh(key, notify = true) }
                return fromDisk
            }
        }
        return refresh(key, notify = false).getOrElse { lock.withLock { entries[key]?.value } }
    }

    /**
     * Копию с диска — в память, без сети: чтобы первый же кадр (экран
     * входящего звонка) показал её сразу, а не через мгновение. Копия
     * считается устаревшей — следующий [get] всё равно сходит за свежей.
     */
    suspend fun warm(key: String) {
        if (lock.withLock { entries[key] != null }) return
        val fromDisk = readDisk(key) ?: return
        lock.withLock { if (entries[key] == null) entries[key] = Entry(fromDisk, 0) }
    }

    /** Значение на сервере изменилось — следующий [get] пойдёт в сеть. */
    suspend fun invalidate(key: String) {
        lock.withLock {
            entries.remove(key)
            generation[key] = (generation[key] ?: 0) + 1
        }
        _changes.tryEmit(key)
    }

    private suspend fun refresh(key: String, notify: Boolean): Result<T?> {
        val (deferred, owner, myGeneration) = lock.withLock {
            inFlight[key]?.let { return@withLock Triple(it, false, 0) }
            val d = CompletableDeferred<Result<T?>>()
            inFlight[key] = d
            Triple(d, true, generation[key] ?: 0)
        }
        if (!owner) return deferred.await()

        val result = try {
            Result.success(fetch(key))
        } catch (e: CancellationException) {
            lock.withLock { inFlight.remove(key) }
            deferred.cancel()
            throw e
        } catch (e: Exception) {
            log.log("RemoteCache[$key]: fetch failed: $e")
            Result.failure(e)
        }
        val changed = lock.withLock {
            inFlight.remove(key)
            val value = result.getOrNull()
            // за время запроса пришло invalidate — устаревший ответ в кэш не кладём
            if (result.isFailure || (generation[key] ?: 0) != myGeneration) return@withLock false
            val old = entries[key]?.value
            entries[key] = Entry(value, now())
            !same(old, value)
        }
        result.onSuccess { writeDisk(key, it) }
        deferred.complete(result)
        if (notify && changed) _changes.tryEmit(key)
        return result
    }

    private fun readDisk(key: String): T? = try {
        diskFile(key).takeIf { it.exists() }?.readBytes()?.let(decode)
    } catch (e: Exception) {
        log.error("RemoteCache[$key]: disk copy unreadable: $e")
        null
    }

    private fun writeDisk(key: String, value: T?) {
        try {
            val file = diskFile(key)
            if (value == null) {
                file.delete()
                return
            }
            val tmp = File(file.path + ".tmp")
            tmp.writeBytes(encode(value))
            tmp.renameTo(file)
        } catch (e: Exception) {
            log.error("RemoteCache[$key]: disk write failed: $e")
        }
    }
}
