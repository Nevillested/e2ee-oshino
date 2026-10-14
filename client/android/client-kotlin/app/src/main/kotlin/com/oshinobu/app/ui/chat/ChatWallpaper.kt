package com.oshinobu.app.ui.chat

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.ui.PeerAvatar
import com.oshinobu.app.ui.PrimaryButton
import com.oshinobu.app.ui.SecondaryButton
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.service.Wallpaper
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

/**
 * Цвета настройки "Фон чата": спокойные, у каждого — светлый и тёмный
 * вариант (под тему), чтобы пузыри и подписи читались одинаково.
 */
val ChatBackgroundColors = listOf(
    Color(0xFFDCE8F4) to Color(0xFF1A2734), // небо
    Color(0xFFDDEEE3) to Color(0xFF1A2C24), // мята
    Color(0xFFD8ECEC) to Color(0xFF172D2E), // бирюза
    Color(0xFFE3E8D6) to Color(0xFF232A1E), // шалфей
    Color(0xFFF1E9D8) to Color(0xFF2C281F), // песок
    Color(0xFFF5E1D5) to Color(0xFF31231E), // персик
    Color(0xFFF2DDE3) to Color(0xFF302029), // роза
    Color(0xFFE5DFF2) to Color(0xFF252137), // лаванда
    Color(0xFFD9E0F0) to Color(0xFF1B2135), // сумерки
    Color(0xFFE3E6EA) to Color(0xFF202327), // графит
)

fun chatBackgroundColor(index: Int?, dark: Boolean): Color? =
    index?.let { ChatBackgroundColors.getOrNull(it) }?.let { if (dark) it.second else it.first }

/** Длинная сторона обоев: хватает на экран любого телефона, а JPEG — сотни КБ. */
private const val WALLPAPER_MAX_SIDE = 1920

/** Исходник для превью — с запасом на увеличение. */
private const val WALLPAPER_SOURCE_MAX_SIDE = 2560

/** Во сколько раз можно увеличить сверх "заполнить экран". */
private const val WALLPAPER_MAX_ZOOM = 5f

/** Картинка из галереи, не больше [maxSide] по длинной стороне. */
private suspend fun Context.loadScaledBitmap(uri: Uri, maxSide: Int): Bitmap = withContext(Dispatchers.IO) {
    if (Build.VERSION.SDK_INT >= 28) {
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(contentResolver, uri)) { decoder, info, _ ->
            val longest = maxOf(info.size.width, info.size.height)
            if (longest > maxSide) decoder.setTargetSize(info.size.width * maxSide / longest, info.size.height * maxSide / longest)
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
    } else {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
        val decoded = contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }
            ?: error("wallpaper: undecodable image")
        decoded.scaledDown(maxSide)
    }
}

private fun Bitmap.scaledDown(maxSide: Int): Bitmap {
    val longest = maxOf(width, height)
    return if (longest > maxSide) Bitmap.createScaledBitmap(this, width * maxSide / longest, height * maxSide / longest, true) else this
}

/**
 * Выбранная картинка до установки и её кадр: картинка всегда заполняет
 * экран чата ([zoom] = 1 — "заполнить", больше — крупнее), [offset] — сдвиг
 * от центра в пикселях экрана. Пустых полей не бывает: сдвиг и масштаб
 * ограничены так, чтобы картинка закрывала весь экран.
 */
@Stable
class WallpaperDraft(private val bitmap: Bitmap) {
    val image: ImageBitmap = bitmap.asImageBitmap()
    var zoom by mutableFloatStateOf(1f)
        private set
    var offset by mutableStateOf(Offset.Zero)
        private set

    /** Размер экрана чата — по нему "заполнить" и вырезается кадр. */
    var viewport by mutableStateOf(IntSize.Zero)
        internal set

    /** Масштаб "картинка × это = экран целиком" при [zoom] = 1. */
    private fun coverScale(): Float =
        maxOf(viewport.width / bitmap.width.toFloat(), viewport.height / bitmap.height.toFloat())

    private fun clamp(o: Offset, z: Float): Offset {
        val k = coverScale() * z
        val maxX = ((bitmap.width * k - viewport.width) / 2f).coerceAtLeast(0f)
        val maxY = ((bitmap.height * k - viewport.height) / 2f).coerceAtLeast(0f)
        return Offset(o.x.coerceIn(-maxX, maxX), o.y.coerceIn(-maxY, maxY))
    }

    /** Жест: сдвиг [pan] и масштаб [zoomChange] вокруг точки [centroid] (координаты экрана чата). */
    fun transform(centroid: Offset, pan: Offset, zoomChange: Float) {
        val newZoom = (zoom * zoomChange).coerceIn(1f, WALLPAPER_MAX_ZOOM)
        // точка под пальцами остаётся под пальцами
        val p = centroid - Offset(viewport.width / 2f, viewport.height / 2f)
        offset = clamp((offset - p) * (newZoom / zoom) + p + pan, newZoom)
        zoom = newZoom
    }

    fun reset() {
        zoom = 1f
        offset = Offset.Zero
    }

    /** Где рисовать картинку: левый верхний угол и размер в пикселях экрана. */
    fun placement(): Pair<IntOffset, IntSize> {
        val k = coverScale() * zoom
        val w = bitmap.width * k
        val h = bitmap.height * k
        val left = (viewport.width - w) / 2f + offset.x
        val top = (viewport.height - h) / 2f + offset.y
        return IntOffset(left.roundToInt(), top.roundToInt()) to IntSize(w.roundToInt(), h.roundToInt())
    }

    /** Видимый кадр → JPEG (не больше [WALLPAPER_MAX_SIDE]) — то, что уйдёт на сервер. */
    suspend fun croppedJpeg(): ByteArray = withContext(Dispatchers.Default) {
        check(viewport.width > 0 && viewport.height > 0) { "wallpaper: viewport not measured" }
        val k = coverScale() * zoom
        val (topLeft, _) = placement()
        val x = (-topLeft.x / k).roundToInt().coerceIn(0, bitmap.width - 1)
        val y = (-topLeft.y / k).roundToInt().coerceIn(0, bitmap.height - 1)
        val w = (viewport.width / k).roundToInt().coerceIn(1, bitmap.width - x)
        val h = (viewport.height / k).roundToInt().coerceIn(1, bitmap.height - y)
        val frame = Bitmap.createBitmap(bitmap, x, y, w, h).scaledDown(WALLPAPER_MAX_SIDE)
        ByteArrayOutputStream().also { frame.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
    }
}

suspend fun Context.loadWallpaperDraft(uri: Uri): WallpaperDraft = WallpaperDraft(loadScaledBitmap(uri, WALLPAPER_SOURCE_MAX_SIDE))

/**
 * Слой жестов над чатом на время превью: двумя пальцами — масштаб, одним —
 * сдвиг, двойной тап — как было. Лента под ним в это время не листается.
 */
@Composable
fun WallpaperGestures(draft: WallpaperDraft, modifier: Modifier = Modifier) {
    Box(
        modifier
            .pointerInput(draft) { detectTapGestures(onDoubleTap = { draft.reset() }) }
            .pointerInput(draft) { detectTransformGestures { centroid, pan, zoom, _ -> draft.transform(centroid, pan, zoom) } },
    )
}

/** Обои на устройстве — в память (перечитываются при новой версии). */
@Composable
private fun rememberWallpaperBitmap(wallpaper: Wallpaper?): ImageBitmap? {
    val bitmap by produceState<ImageBitmap?>(null, wallpaper) {
        value = wallpaper?.let { w ->
            withContext(Dispatchers.IO) { runCatching { BitmapFactory.decodeFile(w.file.path)?.asImageBitmap() }.getOrNull() }
        }
    }
    return bitmap
}

/**
 * Фон чата: [draft] (выбранная, ещё не установленная картинка, в своём
 * кадре) → обои чата → цвет из настроек → фон темы.
 */
@Composable
fun ChatBackdrop(wallpaper: Wallpaper?, draft: WallpaperDraft?, modifier: Modifier = Modifier) {
    val colors = LocalAppColors.current
    val colorIndex by LocalContext.current.app.chatBackground.collectAsState()
    val image = if (draft == null) rememberWallpaperBitmap(wallpaper) else null
    Box(modifier.background(chatBackgroundColor(colorIndex, colors.isDark) ?: colors.background)) {
        when {
            draft != null -> Box(
                Modifier.fillMaxSize().clipToBounds().onSizeChanged { draft.viewport = it }.drawBehind {
                    val (topLeft, size) = draft.placement()
                    drawImage(draft.image, dstOffset = topLeft, dstSize = size, filterQuality = FilterQuality.Medium)
                },
            )
            image != null -> Image(image, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        }
    }
}

/**
 * Превью обоев — вместо поля ввода: подсказка про жесты, "Установить также у <собеседник>"
 * (если ему можно), "Установить как фон чата" и "Отмена".
 */
@Composable
fun WallpaperPreviewBar(
    peerAccountId: String,
    peerName: String,
    canSetForPeer: Boolean,
    forPeer: Boolean,
    onForPeerChange: (Boolean) -> Unit,
    busy: Boolean,
    onSet: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAppColors.current
    Column(
        modifier
            .fillMaxWidth()
            .background(colors.surface, RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp))
            // касания сквозь панель в ленту не проходят
            .clickable(remember { MutableInteractionSource() }, indication = null) {}
            .navigationBarsPadding()
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Text(
            stringResource(R.string.chat_wallpaperHint), color = colors.textMuted, fontSize = 13.sp,
            textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp),
        )
        if (canSetForPeer) {
            Row(
                Modifier.fillMaxWidth().clickable(enabled = !busy) { onForPeerChange(!forPeer) },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Checkbox(forPeer, onForPeerChange, enabled = !busy, colors = CheckboxDefaults.colors(checkedColor = colors.primary))
                Text(stringResource(R.string.chat_wallpaperAlsoFor), color = colors.textPrimary)
                Spacer(Modifier.width(6.dp))
                PeerAvatar(peerAccountId, 20.dp)
                Spacer(Modifier.width(4.dp))
                Text(
                    peerName, color = colors.textPrimary, fontWeight = FontWeight.SemiBold,
                    maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false),
                )
            }
            Spacer(Modifier.height(8.dp))
        }
        PrimaryButton(stringResource(R.string.chat_wallpaperSet), onClick = onSet, loading = busy)
        Spacer(Modifier.height(8.dp))
        SecondaryButton(stringResource(R.string.common_cancel), onClick = onCancel, enabled = !busy)
    }
}
