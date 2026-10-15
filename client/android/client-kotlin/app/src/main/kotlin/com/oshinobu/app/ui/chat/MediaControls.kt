package com.oshinobu.app.ui.chat

import android.graphics.Bitmap
import android.widget.VideoView
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.oshinobu.app.ui.theme.LocalAppColors
import kotlinx.coroutines.delay
import kotlin.math.abs

// Общее для просмотра медиа в чате и предпросмотра в галерее: фото с
// масштабом и полоса перемотки видео.

/**
 * Жесты страницы: два пальца (или уже увеличено) — масштаб и сдвиг;
 * один палец по вертикали — закрытие свайпом; по горизонтали — не трогаем,
 * это листание.
 */
internal fun Modifier.viewerGestures(
    zoomEnabled: Boolean,
    scale: () -> Float,
    onTransform: (zoom: Float, pan: Offset) -> Unit,
    onDismissDrag: (Float) -> Unit,
    onDismissEnd: () -> Unit,
): Modifier = pointerInput(zoomEnabled) {
    val slop = viewConfiguration.touchSlop
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        var vertical = false
        var horizontal = false
        while (true) {
            val event = awaitPointerEvent()
            val pressed = event.changes.filter { it.pressed }
            if (pressed.isEmpty()) break
            if (zoomEnabled && (pressed.size >= 2 || scale() > 1f)) {
                onTransform(event.calculateZoom(), event.calculatePan())
                event.changes.forEach { it.consume() }
                continue
            }
            if (horizontal) continue
            val ch = event.changes.firstOrNull { it.id == down.id } ?: break
            val d = ch.position - down.position
            if (!vertical && abs(d.y) > slop && abs(d.y) > abs(d.x)) vertical = true
            else if (!vertical && abs(d.x) > slop) horizontal = true
            if (vertical) {
                onDismissDrag(ch.positionChange().y)
                ch.consume()
            }
        }
        if (vertical) onDismissEnd()
    }
}

/**
 * Фото на весь экран с масштабом: щипок — до ×5, при увеличении — сдвиг
 * одним пальцем, двойной тап — увеличить вокруг точки тапа или вернуть
 * исходный размер (как в Телеге). [onZoomChanged] — чтобы листалка не
 * перехватывала сдвиг увеличенного фото.
 */
@Composable
internal fun ZoomableImage(
    bitmap: Bitmap,
    onZoomChanged: (Boolean) -> Unit,
    onDismissDrag: (Float) -> Unit = {},
    onDismissEnd: () -> Unit = {},
) {
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    var size by remember { mutableStateOf(IntSize.Zero) }

    fun clamp(o: Offset, s: Float): Offset {
        val maxX = size.width * (s - 1) / 2
        val maxY = size.height * (s - 1) / 2
        return Offset(o.x.coerceIn(-maxX, maxX), o.y.coerceIn(-maxY, maxY))
    }

    fun apply(s: Float, o: Offset) {
        scale = s
        offset = clamp(o, s)
        onZoomChanged(s > 1f)
    }

    val image = remember(bitmap) { bitmap.asImageBitmap() }
    Image(
        image, null, contentScale = ContentScale.Fit,
        modifier = Modifier.fillMaxSize()
            .onSizeChanged { size = it }
            .viewerGestures(
                zoomEnabled = true,
                scale = { scale },
                onTransform = { zoom, pan -> apply((scale * zoom).coerceIn(1f, 5f), offset + pan) },
                onDismissDrag = onDismissDrag,
                onDismissEnd = onDismissEnd,
            )
            .pointerInput(Unit) {
                detectTapGestures(onDoubleTap = { tap ->
                    if (scale > 1f) {
                        apply(1f, Offset.Zero)
                    } else {
                        val center = Offset(size.width / 2f, size.height / 2f)
                        apply(2.5f, (center - tap) * 1.5f)
                    }
                })
            }
            .graphicsLayer(scaleX = scale, scaleY = scale, translationX = offset.x, translationY = offset.y),
    )
}

/**
 * Полоса перемотки видео: текущее время, ползунок (тянуть — перемотка),
 * длительность. Пока длительность неизвестна (видео не готово) — не видна.
 */
@Composable
internal fun VideoSeekBar(view: () -> VideoView?, modifier: Modifier = Modifier) {
    val colors = LocalAppColors.current
    var position by remember { mutableFloatStateOf(0f) }
    var duration by remember { mutableFloatStateOf(0f) }
    var dragging by remember { mutableStateOf<Float?>(null) }
    LaunchedEffect(Unit) {
        while (true) {
            view()?.let { v ->
                if (dragging == null) position = v.currentPosition.toFloat()
                if (v.duration > 0) duration = v.duration.toFloat()
            }
            delay(200)
        }
    }
    if (duration <= 0f) return
    Row(
        modifier.fillMaxWidth().background(Color.Black.copy(alpha = 0.45f)).navigationBarsPadding()
            .padding(horizontal = 12.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val shown = dragging ?: position
        Text(formatClock(shown.toLong()), color = Color.White, fontSize = 12.sp)
        Slider(
            value = shown.coerceIn(0f, duration), valueRange = 0f..duration,
            onValueChange = { dragging = it },
            onValueChangeFinished = {
                dragging?.let { view()?.seekTo(it.toInt()); position = it }
                dragging = null
            },
            colors = SliderDefaults.colors(thumbColor = colors.primary, activeTrackColor = colors.primary, inactiveTrackColor = Color.White.copy(alpha = 0.24f)),
            modifier = Modifier.weight(1f).padding(horizontal = 8.dp),
        )
        Text(formatClock(duration.toLong()), color = Color.White, fontSize = 12.sp)
    }
}

private fun formatClock(ms: Long): String {
    val s = ms / 1000
    val h = s / 3600
    val mm = ((s % 3600) / 60).toString().padStart(2, '0')
    val ss = (s % 60).toString().padStart(2, '0')
    return if (h > 0) "$h:$mm:$ss" else "$mm:$ss"
}
