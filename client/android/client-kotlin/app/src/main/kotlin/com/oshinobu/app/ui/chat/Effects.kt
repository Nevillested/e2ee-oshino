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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import kotlin.random.Random

/**
 * Пузырь, который при удалении рассыпается на осколки: в момент удаления
 * снимок содержимого режется на мелкие квадраты, и они разлетаются вверх с
 * затуханием — волной слева направо. Место в ленте сохраняется до конца
 * анимации ([DISSOLVE_MS]), затем сообщение исчезает.
 */
@Composable
fun Dissolvable(dissolving: Boolean, content: @Composable () -> Unit) {
    val layer = rememberGraphicsLayer()
    var snapshot by remember { mutableStateOf<ImageBitmap?>(null) }
    val progress = remember { Animatable(0f) }
    LaunchedEffect(dissolving) {
        if (dissolving && snapshot == null) {
            snapshot = layer.toImageBitmap()
            progress.animateTo(1f, tween((DISSOLVE_MS - 60).toInt(), easing = LinearEasing))
        }
    }
    Box(
        Modifier.drawWithContent {
            val shot = snapshot
            if (shot == null) {
                layer.record { this@drawWithContent.drawContent() }
                drawLayer(layer)
            } else {
                drawShatter(shot, progress.value)
            }
        },
    ) { content() }
}

private const val SHARD_PX = 7

private fun DrawScope.drawShatter(image: ImageBitmap, t: Float) {
    val cols = (image.width + SHARD_PX - 1) / SHARD_PX
    val rows = (image.height + SHARD_PX - 1) / SHARD_PX
    for (r in 0 until rows) {
        for (c in 0 until cols) {
            val rnd = Random(r * 7919 + c)
            // волна слева направо: правые осколки стартуют позже
            val start = c.toFloat() / cols * 0.45f + rnd.nextFloat() * 0.1f
            val local = ((t - start) / (1f - start)).coerceIn(0f, 1f)
            if (local >= 1f) continue
            val w = minOf(SHARD_PX, image.width - c * SHARD_PX)
            val h = minOf(SHARD_PX, image.height - r * SHARD_PX)
            val vx = (rnd.nextFloat() - 0.3f) * 160f
            val vy = -(40f + rnd.nextFloat() * 140f)
            val eased = FastOutSlowInEasing.transform(local)
            val dx = c * SHARD_PX + vx * eased
            val dy = r * SHARD_PX + vy * eased
            drawImage(
                image,
                srcOffset = IntOffset(c * SHARD_PX, r * SHARD_PX),
                srcSize = IntSize(w, h),
                dstOffset = IntOffset(dx.toInt(), dy.toInt()),
                dstSize = IntSize(w, h),
                alpha = 1f - local,
            )
        }
    }
}

/** Разовая подсветка строки во всю ширину — после перехода к сообщению по цитате или закрепу. */
fun Modifier.jumpFlash(alpha: Float, color: Color): Modifier =
    if (alpha <= 0f) this else drawBehind { drawRect(color.copy(alpha = alpha)) }

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
        anim.animateTo(0f, tween(1100))
    }
    return anim.value
}
