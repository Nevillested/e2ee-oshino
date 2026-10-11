package com.oshinobu.app.ui.chat

import android.content.Context
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.airbnb.lottie.compose.LottieAnimation
import com.airbnb.lottie.compose.LottieCompositionSpec
import com.airbnb.lottie.compose.animateLottieCompositionAsState
import com.airbnb.lottie.compose.rememberLottieComposition
import kotlinx.coroutines.flow.first
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Анимированные реакции — Noto Animated Emoji (Google, CC BY 4.0), лежат в
 * assets/reactions/<кодовые точки без FE0F>.json прямо в приложении: брать
 * их по запросу с серверов Google нельзя — Google узнавал бы, кто какую
 * реакцию поставил. Для эмодзи без анимации у Noto — только частицы.
 */
private object ReactionAnimations {
    @Volatile private var available: Set<String>? = null

    fun asset(context: Context, emoji: String): String? {
        val names = available ?: (context.assets.list("reactions")?.toSet() ?: emptySet()).also { available = it }
        val key = emoji.codePoints().toArray().filter { it != 0xFE0F }.joinToString("_") { Integer.toHexString(it) }
        return "$key.json".takeIf { it in names }?.let { "reactions/$it" }
    }
}

private val BurstSize = 72.dp
private const val PARTICLES = 8

/**
 * Только что поставленная реакция: живое эмодзи поверх бейджа и разлёт его
 * маленьких копий; рисуется за пределами бейджа, место в раскладке не
 * занимает. [onDone] — всё доиграло.
 */
@Composable
fun ReactionBurst(emoji: String, onDone: () -> Unit) {
    val context = LocalContext.current
    val asset = remember(emoji) { ReactionAnimations.asset(context, emoji) }
    val particles = remember { Animatable(0f) }
    // нет анимации у Noto — ждать нечего, только частицы
    var lottieDone by remember { mutableStateOf(asset == null) }

    LaunchedEffect(Unit) {
        particles.animateTo(1f, tween(700, easing = FastOutSlowInEasing))
        snapshotFlow { lottieDone }.first { it }
        onDone()
    }

    Box(Modifier.wrapContentSize(unbounded = true).requiredSize(BurstSize), contentAlignment = Alignment.Center) {
        if (asset != null) ReactionLottie(asset) { lottieDone = true }
        val t = particles.value
        for (i in 0 until PARTICLES) {
            val angle = 2 * PI * i / PARTICLES
            val distance = 34.dp * t
            Text(
                emoji,
                fontSize = 11.sp,
                modifier = Modifier
                    .offset {
                        val d = distance.toPx()
                        IntOffset((cos(angle) * d).roundToInt(), (sin(angle) * d).roundToInt())
                    }
                    .graphicsLayer {
                        alpha = 1f - t
                        scaleX = 1f - 0.4f * t
                        scaleY = 1f - 0.4f * t
                    },
            )
        }
    }
}

/** Живое эмодзи один раз; доиграло или не загрузилось — [onDone]. */
@Composable
private fun ReactionLottie(asset: String, onDone: () -> Unit) {
    val result = rememberLottieComposition(LottieCompositionSpec.Asset(asset))
    val composition by result
    val progress by animateLottieCompositionAsState(composition, iterations = 1)
    LaunchedEffect(composition, progress, result.isFailure) {
        if (result.isFailure || (composition != null && progress >= 1f)) onDone()
    }
    LottieAnimation(composition, { progress }, Modifier.fillMaxSize())
}
