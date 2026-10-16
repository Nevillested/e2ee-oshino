package com.oshinobu.app.ui.chat

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.unit.dp
import kotlin.math.ceil
import kotlin.math.sqrt
import kotlin.random.Random

/**
 * Пузырь, который при удалении рассыпается на осколки: в момент удаления
 * содержимое замораживается (больше не перерисовывается) и режется на мелкие
 * квадраты, они разлетаются вверх, сжимаясь в точку, — волной слева направо.
 * Место в ленте сохраняется до конца анимации ([DISSOLVE_MS]), затем
 * сообщение исчезает.
 *
 * Осколки рисуются прямо из записанного слоя, без снимка-картинки: снимок
 * (toImageBitmap) на части устройств выходил пустым — сообщение пропадало
 * сразу, без анимации.
 */
@Composable
fun Dissolvable(dissolving: Boolean, content: @Composable () -> Unit) {
    val layer = rememberGraphicsLayer()
    var frozen by remember { mutableStateOf(false) }
    val progress = remember { Animatable(0f) }
    // осколки считаются один раз — в первом кадре после заморозки, по размеру пузыря
    val shards = remember { arrayOfNulls<Shards>(1) }
    LaunchedEffect(dissolving) {
        if (dissolving && !frozen) {
            frozen = true
            progress.animateTo(1f, tween((DISSOLVE_MS - 60).toInt(), easing = LinearEasing))
        }
    }
    Box(
        Modifier.drawWithContent {
            if (!frozen) {
                layer.record { this@drawWithContent.drawContent() }
                drawLayer(layer)
            } else {
                val s = shards[0] ?: Shards.of(size.width, size.height).also { shards[0] = it }
                drawShatter(layer, s, progress.value)
            }
        },
    ) { content() }
}

/** Сколько осколков не больше: каждый — отдельная отрисовка слоя, больше — кадры не успевают. */
private const val MAX_SHARDS = 600

/** Мельче этого осколки не режем (на маленьких пузырях их и так немного). */
private const val MIN_SHARD_PX = 10f

/**
 * Осколки пузыря: на каждый — x, y, ширина, высота, когда стартует (0..1),
 * куда улетает по x и по y. Считаются один раз, а не в каждом кадре.
 */
private class Shards(val data: FloatArray, val count: Int) {
    companion object {
        const val FIELDS = 7

        fun of(width: Float, height: Float): Shards {
            val side = maxOf(MIN_SHARD_PX, ceil(sqrt(width * height / MAX_SHARDS)))
            val cols = ceil(width / side).toInt().coerceAtLeast(1)
            val rows = ceil(height / side).toInt().coerceAtLeast(1)
            val data = FloatArray(cols * rows * FIELDS)
            val rnd = Random(cols * 7919 + rows)
            var i = 0
            for (r in 0 until rows) {
                for (c in 0 until cols) {
                    data[i++] = c * side
                    data[i++] = r * side
                    data[i++] = minOf(side, width - c * side)
                    data[i++] = minOf(side, height - r * side)
                    // волна слева направо: правые осколки стартуют позже
                    data[i++] = c.toFloat() / cols * 0.45f + rnd.nextFloat() * 0.1f
                    data[i++] = (rnd.nextFloat() - 0.3f) * 160f
                    data[i++] = -(40f + rnd.nextFloat() * 140f)
                }
            }
            return Shards(data, cols * rows)
        }
    }
}

private fun DrawScope.drawShatter(layer: GraphicsLayer, shards: Shards, t: Float) {
    val d = shards.data
    for (n in 0 until shards.count) {
        val i = n * Shards.FIELDS
        val start = d[i + 4]
        val local = ((t - start) / (1f - start)).coerceIn(0f, 1f)
        if (local >= 1f) continue
        val w = d[i + 2]
        val h = d[i + 3]
        val eased = FastOutSlowInEasing.transform(local)
        val dx = d[i + 5] * eased
        val dy = d[i + 6] * eased
        // осколок сжимается к своему центру — вместо затухания
        val keep = 1f - local
        val cx = d[i] + w / 2 + dx
        val cy = d[i + 1] + h / 2 + dy
        clipRect(cx - w * keep / 2, cy - h * keep / 2, cx + w * keep / 2, cy + h * keep / 2) {
            translate(dx, dy) { drawLayer(layer) }
        }
    }
}

/** Разовая подсветка строки во всю ширину — после перехода к сообщению по цитате или закрепу. */
fun Modifier.jumpFlash(alpha: Float, color: Color): Modifier =
    if (alpha <= 0f) this else drawBehind {
        drawRoundRect(color.copy(alpha = alpha), cornerRadius = CornerRadius(14.dp.toPx()))
    }

/** Пульсация пузыря — совпадение поиска, на котором сейчас стоим. */
@Composable
fun pulsingHighlightAlpha(): Float {
    val a by rememberInfiniteTransition(label = "highlight").animateFloat(
        0.15f, 0.45f, infiniteRepeatable(tween(650), RepeatMode.Reverse), label = "a",
    )
    return a
}

/** Плавное угасание вспышки: от 0.35 к нулю за ~1.1 с, перезапуск по [token]. */
@Composable
fun flashAlpha(token: Int): Float {
    val anim = remember { Animatable(0f) }
    LaunchedEffect(token) {
        if (token == 0) return@LaunchedEffect
        anim.snapTo(0.35f)
        anim.animateTo(0f, tween(2200))
    }
    return anim.value
}
