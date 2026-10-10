package com.oshinobu.app.system

import android.app.Service
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat

/**
 * Пуск и остановка службы переднего плана без падения
 * ForegroundServiceDidNotStartInTimeException. После startForegroundService
 * Android требует startForeground в течение нескольких секунд, а
 * остановленная раньше этого служба роняет приложение. А старт и стоп у нас
 * бывают почти одновременно: звонок начал звонить и сразу принят, передача
 * файла тут же закончилась, на медленном телефоне при холодном старте
 * служба не успела подняться. Остановка до того, как служба ушла на
 * передний план, откладывается: служба поднимется, покажет уведомление
 * (требование выполнено) и сразу уйдёт.
 */
class ForegroundGate(private val service: Class<out Service>) {
    /** startForegroundService вызван, служба ещё не завершилась. */
    private var requested = false

    /** Служба уже вызвала startForeground. */
    private var foreground = false

    /** Остановку попросили, пока служба ещё не ушла на передний план. */
    private var stopPending = false

    /** false — Android не дал запустить (например, из фона без исключения). */
    @Synchronized
    fun start(context: Context, intent: Intent): Boolean {
        stopPending = false
        return runCatching { ContextCompat.startForegroundService(context, intent) }
            .onSuccess { requested = true }
            .isSuccess
    }

    @Synchronized
    fun stop(context: Context) {
        if (requested && !foreground) {
            stopPending = true
            return
        }
        requested = false
        context.stopService(Intent(context, service))
    }

    /**
     * Из onStartCommand сразу после startForeground. true — остановку уже
     * попросили: служба должна снять уведомление и уйти.
     */
    @Synchronized
    fun onForeground(): Boolean {
        foreground = true
        if (!stopPending) return false
        stopPending = false
        requested = false
        return true
    }

    /** Из onDestroy. */
    @Synchronized
    fun onDestroy() {
        requested = false
        foreground = false
        stopPending = false
    }
}
