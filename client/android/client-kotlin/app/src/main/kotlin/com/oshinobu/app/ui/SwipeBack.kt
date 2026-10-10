package com.oshinobu.app.ui

import androidx.activity.BackEventCompat
import androidx.activity.OnBackPressedDispatcher
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.awaitHorizontalTouchSlopOrCancellation
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.input.pointer.util.addPointerInputChange
import kotlin.math.abs

/**
 * Свайп назад с любого места экрана (как во Flutter-клиенте): палец ведёт
 * системный "назад" с прогрессом — Navigation Compose двигает экран вслед за
 * ним (та же анимация, что у краевого жеста Android). Отпустили дальше
 * середины или быстрым броском вправо — экран закрывается, иначе возвращается.
 */
class SwipeBackController(
    private val dispatcher: OnBackPressedDispatcher,
    /**
     * Можно ли сейчас свайпнуть назад (есть куда возвращаться, экран не
     * запрещает). Спрашивается в момент касания: флаг, выставляемый при
     * перерисовке, не успевал за сменой экрана — свайп не срабатывал вовсе.
     */
    private val canSwipe: () -> Boolean,
) {
    val enabled: Boolean get() = canSwipe()
    private var active = false

    fun start(): Boolean {
        if (active || !canSwipe()) return false
        active = true
        dispatcher.dispatchOnBackStarted(BackEventCompat(0f, 0f, 0f, BackEventCompat.EDGE_LEFT))
        return true
    }

    fun progress(fraction: Float) {
        if (active) dispatcher.dispatchOnBackProgressed(BackEventCompat(0f, 0f, fraction.coerceIn(0f, 1f), BackEventCompat.EDGE_LEFT))
    }

    /** [velocityFraction] — скорость в ширинах экрана в секунду (вправо — больше нуля). */
    fun finish(fraction: Float, velocityFraction: Float) {
        if (!active) return
        active = false
        val close = if (abs(velocityFraction) >= 1f) velocityFraction > 0 else fraction > 0.5f
        if (close) dispatcher.onBackPressed() else dispatcher.dispatchOnBackCancelled()
    }
}

val LocalSwipeBack = staticCompositionLocalOf<SwipeBackController?> { null }

/**
 * Горизонтальный свайп вправо, который никто внутри не забрал (листалки,
 * свайп-ответ в чате забирают свои жесты сами), — свайп назад.
 */
fun Modifier.swipeBack(controller: SwipeBackController): Modifier = pointerInput(controller) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        if (!controller.enabled) return@awaitEachGesture
        var startedRight = false
        val slop = awaitHorizontalTouchSlopOrCancellation(down.id) { change, over ->
            if (over > 0) {
                startedRight = true
                change.consume()
            }
        } ?: return@awaitEachGesture
        if (!startedRight || !controller.start()) return@awaitEachGesture
        val width = size.width.toFloat().coerceAtLeast(1f)
        val tracker = VelocityTracker().apply { addPointerInputChange(slop) }
        var dx = slop.position.x - down.position.x
        while (true) {
            val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
            tracker.addPointerInputChange(change)
            if (!change.pressed) break
            dx += change.positionChange().x
            change.consume()
            controller.progress(dx / width)
        }
        controller.finish(dx / width, tracker.calculateVelocity().x / width)
    }
}
