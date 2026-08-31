package com.oshinobu.oshinobu_client

import android.app.Application
import android.util.Log

private const val TAG = "OshinobuApplication"

/**
 * Единственная причина существования этого класса — обойти известную гонку
 * Flutter-embedding: MainActivity намеренно держит FlutterEngine живым между
 * несколькими Activity (shouldDestroyEngineWithHost=false, см. её же
 * комментарий там — иначе смахивание задачи из "недавних" рвало бы активный
 * звонок). Из-за этого при смене/пересоздании Activity (PiP, поворот
 * экрана, системные ограничения памяти) иногда уже ПОСЛЕ отсоединения
 * старого View от движка успевает выстрелить отложенный
 * Choreographer-колбэк onSizeChanged, который пытается дёрнуть
 * FlutterJNI.setViewportMetrics — а тот уже not attached. Сама Flutter
 * framework нигде эту гонку не ловит (реальный кейс с устройства —
 * тестировщик прислал полный стектрейс: падает глубоко внутри
 * io.flutter.embedding.engine.FlutterJNI.ensureAttachedToNative, вызванного
 * из rc.r.onSizeChanged). Событие само по себе безвредное — это пропущенное
 * обновление размеров для уже умирающего View, реальных данных не теряется
 * — но по умолчанию Android считает любое необработанное исключение на
 * главном потоке FATAL и убивает всё приложение целиком, хотя звонок или
 * сама сессия вполне могли бы продолжаться. Перехватываем ИМЕННО этот,
 * узкий случай — любое другое необработанное исключение по-прежнему падает
 * как обычно, мы его не глушим.
 */
class OshinobuApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val defaultHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            if (isStaleFlutterJniViewportRace(throwable)) {
                Log.w(
                    TAG,
                    "Подавлено безвредное исключение FlutterJNI-not-attached " +
                        "(гонка отсоединения View от закэшированного движка при PiP/смене Activity)",
                    throwable,
                )
                return@setDefaultUncaughtExceptionHandler
            }
            defaultHandler?.uncaughtException(thread, throwable)
        }
    }

    private fun isStaleFlutterJniViewportRace(throwable: Throwable): Boolean {
        if (throwable !is RuntimeException) return false
        val message = throwable.message ?: return false
        if (!message.contains("FlutterJNI is not attached to native")) return false
        // Дополнительно сверяемся со стектрейсом (а не полагаемся на один
        // только текст сообщения) — сработать должно только на этот
        // конкретный, разобранный случай "отложенный layout-колбэк уже
        // отсоединённого View", а не на любую другую причину той же ошибки.
        return throwable.stackTrace.any {
            it.methodName == "setViewportMetrics" || it.methodName == "onSizeChanged"
        }
    }
}
