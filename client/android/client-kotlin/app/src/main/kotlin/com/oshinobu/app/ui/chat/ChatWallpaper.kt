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
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.ui.PeerAvatar
import com.oshinobu.app.ui.PrimaryButton
import com.oshinobu.app.ui.SecondaryButton
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.service.Wallpaper
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

/**
 * Картинка из галереи → JPEG для обоев (не больше [WALLPAPER_MAX_SIDE] по
 * длинной стороне). Его же показывает превью — видно ровно то, что уйдёт на сервер.
 */
private suspend fun Context.loadWallpaperJpeg(uri: Uri): ByteArray = withContext(Dispatchers.IO) {
    val bitmap = if (Build.VERSION.SDK_INT >= 28) {
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(contentResolver, uri)) { decoder, info, _ ->
            val longest = maxOf(info.size.width, info.size.height)
            if (longest > WALLPAPER_MAX_SIDE) {
                decoder.setTargetSize(info.size.width * WALLPAPER_MAX_SIDE / longest, info.size.height * WALLPAPER_MAX_SIDE / longest)
            }
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
    } else {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= WALLPAPER_MAX_SIDE) sample *= 2
        val decoded = contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }
            ?: error("wallpaper: undecodable image")
        val longest = maxOf(decoded.width, decoded.height)
        if (longest > WALLPAPER_MAX_SIDE) {
            Bitmap.createScaledBitmap(decoded, decoded.width * WALLPAPER_MAX_SIDE / longest, decoded.height * WALLPAPER_MAX_SIDE / longest, true)
        } else {
            decoded
        }
    }
    ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
}

/** Выбранная картинка до установки: JPEG для сервера и он же, раскодированный, — для превью. */
class WallpaperDraft(val jpeg: ByteArray, val image: ImageBitmap)

suspend fun Context.loadWallpaperDraft(uri: Uri): WallpaperDraft {
    val jpeg = loadWallpaperJpeg(uri)
    val image = withContext(Dispatchers.IO) { BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size).asImageBitmap() }
    return WallpaperDraft(jpeg, image)
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
 * Фон чата: [preview] (выбранная, ещё не установленная картинка) → обои
 * чата → цвет из настроек → фон темы.
 */
@Composable
fun ChatBackdrop(wallpaper: Wallpaper?, preview: ImageBitmap?, modifier: Modifier = Modifier) {
    val colors = LocalAppColors.current
    val colorIndex by LocalContext.current.app.chatBackground.collectAsState()
    val image = preview ?: rememberWallpaperBitmap(wallpaper)
    Box(modifier.background(chatBackgroundColor(colorIndex, colors.isDark) ?: colors.background)) {
        image?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
    }
}

/**
 * Превью обоев — вместо поля ввода: "Установить также у <собеседник>"
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
