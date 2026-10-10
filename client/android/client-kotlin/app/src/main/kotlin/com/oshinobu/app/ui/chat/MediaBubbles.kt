package com.oshinobu.app.ui.chat

import com.oshinobu.app.ui.AppLoadingIndicator
import android.graphics.Bitmap
import android.os.Build
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Article
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.filled.Android
import androidx.compose.material.icons.filled.Audiotrack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.FolderZip
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Slideshow
import androidx.compose.material.icons.filled.TableChart
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.oshinobu.app.R
import com.oshinobu.app.media.MediaDecoding
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.app.ui.translate
import com.oshinobu.core.format.formatFileSize
import com.oshinobu.core.service.MediaDownloadManager
import com.oshinobu.core.storage.MessageStatus
import com.oshinobu.core.storage.StoredMessage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.random.Random

/** Этап отправки/скачивания вложения, как его видит пузырь. */
data class TransferPhase(val text: String, val percent: Double?)

/**
 * Этап своей отправки: "Загрузка…" с процентом; когда клиент дослал все
 * байты, сервер ещё сохраняет файл — показываем это отдельной фазой, а не
 * зависшие 100%.
 */
@Composable
fun uploadPhase(vm: ChatViewModel, msg: StoredMessage): TransferPhase? {
    val step = msg.processingStep ?: return null
    val progress by vm.uploadProgress.collectAsState()
    val percent = progress[msg.messageId]
    if (percent != null && percent >= 100) return TransferPhase(stringResource(R.string.chat_savingOnServer), null)
    return TransferPhase(LocalContext.current.translate(step), percent)
}

/** Скачивание: идёт (с процентом), ждёт в очереди или null — не качается. */
@Composable
fun downloadPhase(vm: ChatViewModel, msg: StoredMessage): TransferPhase? {
    val id = msg.mediaId ?: return null
    val progress by vm.downloadProgress.collectAsState()
    val snapshot by vm.downloads.collectAsState()
    val row = (snapshot.manual + snapshot.auto).firstOrNull { it.mediaId == id } ?: return null
    return if (row.active) {
        TransferPhase(stringResource(R.string.media_downloading), progress[id] ?: 0.0)
    } else {
        TransferPhase(stringResource(R.string.chat_queued), null)
    }
}

/** Затемнение поверх плитки: кольцо прогресса (или бесконечное), подпись, крестик отмены. */
@Composable
fun MediaStatusOverlay(statusText: String, percent: Double?, onCancel: (() -> Unit)?) {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(6.dp)) {
            Box(contentAlignment = Alignment.Center) {
                if (percent != null) {
                    CircularProgressIndicator(
                        progress = { (percent / 100).toFloat().coerceIn(0f, 1f) },
                        modifier = Modifier.size(36.dp), color = Color.White, strokeWidth = 3.dp,
                        trackColor = Color.White.copy(alpha = 0.25f),
                    )
                } else {
                    AppLoadingIndicator(size = 36.dp, color = Color.White)
                }
                if (onCancel != null) {
                    Icon(Icons.Filled.Close, null, tint = Color.White, modifier = Modifier.size(18.dp).clickable(onClick = onCancel))
                }
            }
            Spacer(Modifier.size(4.dp))
            Text(
                if (percent != null) "$statusText ${percent.toInt()}%" else statusText,
                color = Color.White, fontSize = 11.sp, textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** Размер файла в единицах текущего языка. */
@Composable
fun fileSizeText(bytes: Long): String {
    val context = LocalContext.current
    return formatFileSize(bytes, context::translate)
}

/** Значок "play" поверх кадра видео. */
@Composable
private fun PlayBadge() {
    Box(Modifier.size(38.dp).background(Color.Black.copy(alpha = 0.38f), CircleShape), contentAlignment = Alignment.Center) {
        Icon(Icons.Filled.PlayArrow, null, tint = Color.White, modifier = Modifier.size(22.dp))
    }
}

/** Картинка вложения, уже лежащего на устройстве (для видео — кадр). Перечитывается после скачивания. */
@Composable
private fun rememberMediaBitmap(vm: ChatViewModel, msg: StoredMessage, side: Dp): Bitmap? {
    val px = with(LocalDensity.current) { (side * 2).roundToPx() }.coerceAtMost(1440)
    val bitmap by produceState<Bitmap?>(null, msg.messageId, msg.mediaId, vm.mediaVersion, px) {
        value = withContext(Dispatchers.IO) {
            if (msg.isVideo) {
                val preview = msg.localPreviewPath?.let(::File)?.takeIf { it.exists() }
                preview?.let { MediaDecoding.decodeImage(it, px) }
                    ?: vm.localMediaFile(msg)?.let { MediaDecoding.videoFrame(it, px) }
            } else {
                vm.localMediaFile(msg)?.let { MediaDecoding.decodeImage(it, px) }
            }
        }
    }
    return bitmap
}

/**
 * Вложение в пузыре: файл — строкой (или плиткой в альбоме), фото/видео —
 * квадратом [size] с плашкой размера. Свои в процессе отправки — превью и
 * этап; чужие крупные — плитка "скачать"; мелкие докачиваются сами.
 */
@Composable
fun AttachmentBubble(
    vm: ChatViewModel,
    msg: StoredMessage,
    size: Dp,
    revealed: Boolean,
    onReveal: () -> Unit,
    onOpenViewer: (StoredMessage) -> Unit,
    onOpenFile: (StoredMessage) -> Unit,
    onSaveFile: (StoredMessage) -> Unit,
) {
    if (msg.isFile) {
        FileAttachment(vm, msg, size, onOpenFile, onSaveFile)
        return
    }
    Box(Modifier.size(size).clip(BubbleShape)) {
        MediaTile(vm, msg, size, revealed, onReveal, onOpenViewer)
        if (msg.fileSize > 0) SizePlaque(fileSizeText(msg.fileSize), Modifier.align(Alignment.BottomStart).padding(6.dp))
    }
}

@Composable
private fun MediaTile(
    vm: ChatViewModel,
    msg: StoredMessage,
    size: Dp,
    revealed: Boolean,
    onReveal: () -> Unit,
    onOpenViewer: (StoredMessage) -> Unit,
) {
    val colors = LocalAppColors.current
    val sendingOrFailed = msg.isMine && (msg.status == MessageStatus.SENDING || msg.status == MessageStatus.FAILED)
    val upload = if (sendingOrFailed) uploadPhase(vm, msg) else null
    val download = downloadPhase(vm, msg)
    val bitmap = rememberMediaBitmap(vm, msg, size)
    val hiddenSpoiler = msg.isSpoiler && !revealed

    Box(Modifier.size(size).background(colors.surface), contentAlignment = Alignment.Center) {
        when {
            bitmap != null -> {
                SpoilerImage(bitmap, hidden = hiddenSpoiler, modifier = Modifier.fillMaxSize().clickable(enabled = !sendingOrFailed) {
                    if (hiddenSpoiler) onReveal() else onOpenViewer(msg)
                })
                if (msg.isVideo && !hiddenSpoiler) PlayBadge()
            }
            sendingOrFailed -> Icon(Icons.AutoMirrored.Filled.InsertDriveFile, null, tint = colors.textMuted, modifier = Modifier.size(40.dp))
            download != null -> MediaStatusOverlay(download.text, download.percent) { vm.cancelDownload(msg) }
            msg.mediaId != null && msg.mediaId in vm.failedDownloads ->
                Icon(Icons.Filled.Refresh, null, tint = Color(0xFFFF5252), modifier = Modifier.fillMaxSize().clickable { vm.requestDownload(msg) }.padding(size / 3))
            // мелкое чужое вложение: авто-очередь заберёт его, как только пузырь окажется на экране
            !msg.isMine && msg.fileSize < MediaDownloadManager.AUTO_DOWNLOAD_LIMIT_BYTES ->
                MediaStatusOverlay(stringResource(R.string.chat_queued), null, null)
            else -> Box(
                Modifier.fillMaxSize().border(1.dp, colors.textMuted.copy(alpha = 0.35f), BubbleShape).clickable { vm.requestDownload(msg) },
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Filled.Download, null, tint = colors.textPrimary, modifier = Modifier.size(32.dp)) }
        }
        if (upload != null) MediaStatusOverlay(upload.text, upload.percent, null)
    }
}

/**
 * Фото под спойлером: размытие и мерцающие частицы; раскрытие — плавно.
 * До Android 12 размытия нет — картинку закрывает плотная вуаль.
 */
@Composable
private fun SpoilerImage(bitmap: Bitmap, hidden: Boolean, modifier: Modifier) {
    val image = remember(bitmap) { bitmap.asImageBitmap() }
    val veil by animateFloatAsState(if (hidden) 1f else 0f, tween(450), label = "spoiler")
    Box(modifier) {
        val blurModifier = if (veil > 0f && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Modifier.blur((24 * veil).dp) else Modifier
        Image(image, null, Modifier.fillMaxSize().then(blurModifier), contentScale = ContentScale.Crop)
        if (veil > 0f) {
            val baseVeil = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) 0.25f else 0.85f
            Box(Modifier.fillMaxSize().graphicsLayer { alpha = veil }.background(Color.Black.copy(alpha = baseVeil)))
            SpoilerParticles(Modifier.fillMaxSize().graphicsLayer { alpha = veil })
        }
    }
}

/** Мерцающие частицы поверх скрытого под спойлером. */
@Composable
fun SpoilerParticles(modifier: Modifier) {
    val particles = remember { List(70) { Triple(Random.nextFloat(), Random.nextFloat(), Random.nextFloat()) } }
    val t by rememberInfiniteTransition(label = "spoilerParticles").animateFloat(
        0f, 1f, infiniteRepeatable(tween(3000, easing = LinearEasing), RepeatMode.Restart), label = "t",
    )
    Canvas(modifier) {
        for ((x, y, phase) in particles) {
            val p = (t + phase) % 1f
            val dx = kotlin.math.sin((p + phase) * 6.283f) * 6f
            val a = 1f - kotlin.math.abs(p * 2 - 1)
            drawCircle(Color.White.copy(alpha = 0.8f * a), radius = 1.6f, center = Offset(x * size.width + dx, (y + p * 0.08f) % 1f * size.height))
        }
    }
}

private fun iconForFileName(name: String?): ImageVector = when (name?.substringAfterLast('.', "")?.lowercase()) {
    "pdf" -> Icons.Filled.PictureAsPdf
    "doc", "docx", "odt", "rtf" -> Icons.Filled.Description
    "xls", "xlsx", "csv", "ods" -> Icons.Filled.TableChart
    "ppt", "pptx", "odp" -> Icons.Filled.Slideshow
    "txt" -> Icons.AutoMirrored.Filled.Article
    "zip", "rar", "7z", "tar", "gz" -> Icons.Filled.FolderZip
    "mp3", "wav", "m4a", "aac", "flac", "ogg" -> Icons.Filled.Audiotrack
    "mp4", "mov", "avi", "mkv", "webm", "3gp" -> Icons.Filled.Videocam
    "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp" -> Icons.Filled.Image
    "apk" -> Icons.Filled.Android
    "json", "xml", "html", "css", "js", "dart", "py", "java", "kt", "c", "cpp" -> Icons.Filled.Code
    else -> Icons.AutoMirrored.Filled.InsertDriveFile
}

/** Меню "⋮" у скачанного файла: сохранить в "Загрузки". */
@Composable
private fun SaveFileMenu(tint: Color, badge: Boolean, onSave: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Icon(
            Icons.Filled.MoreVert, null, tint = tint,
            modifier = Modifier
                .then(if (badge) Modifier.background(Color.Black.copy(alpha = 0.45f), CircleShape) else Modifier)
                .clickable { open = true }
                .padding(if (badge) 3.dp else 6.dp)
                .size(if (badge) 14.dp else 18.dp),
        )
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(text = { Text(stringResource(R.string.chat_saveToDevice)) }, onClick = {
                open = false
                onSave()
            })
        }
    }
}

/**
 * Файл: иконка по расширению, имя, размер и этап (отправка/скачивание с
 * процентом). В альбоме (size < 200) — компактная плитка.
 */
@Composable
private fun FileAttachment(
    vm: ChatViewModel,
    msg: StoredMessage,
    size: Dp,
    onOpenFile: (StoredMessage) -> Unit,
    onSaveFile: (StoredMessage) -> Unit,
) {
    val colors = LocalAppColors.current
    val sending = msg.isMine && msg.processingStep != null
    val failed = msg.isMine && msg.status == MessageStatus.FAILED
    val local = remember(msg, vm.mediaVersion) { vm.localMediaFile(msg) != null }
    val needsDownload = !sending && !failed && !local
    val download = if (needsDownload) downloadPhase(vm, msg) else null
    val upload = if (sending) uploadPhase(vm, msg) else null
    val failedText = stringResource(R.string.error_uploadFailed)
    val status = when {
        upload != null -> upload
        failed -> TransferPhase(failedText, null)
        else -> download
    }
    val icon = if (failed) Icons.Filled.ErrorOutline else iconForFileName(msg.fileName)
    val tappable = !sending && !failed && download == null
    val canSave = tappable && !needsDownload
    val cancel: (() -> Unit)? = if (download != null) ({ vm.cancelDownload(msg) }) else null
    val onTap = { if (needsDownload) vm.requestDownload(msg) else onOpenFile(msg) }

    if (size < 200.dp) {
        Box(
            Modifier.size(size).clip(RoundedCornerShape(10.dp)).background(colors.surface)
                .clickable(enabled = tappable || cancel != null) { cancel?.invoke() ?: onTap() },
            contentAlignment = Alignment.Center,
        ) {
            if (download != null) {
                AppLoadingIndicator(size = 22.dp, color = colors.textMuted)
            } else {
                Icon(icon, null, tint = if (failed) Color(0xFFFF5252) else colors.textMuted, modifier = Modifier.size(32.dp))
            }
            if (cancel != null) {
                Icon(
                    Icons.Filled.Close, null, tint = Color.White,
                    modifier = Modifier.align(Alignment.TopEnd).padding(2.dp).background(Color.Black.copy(alpha = 0.45f), CircleShape)
                        .clickable(onClick = cancel).padding(2.dp).size(12.dp),
                )
            }
            if (canSave) {
                Box(Modifier.align(Alignment.TopEnd).padding(2.dp)) { SaveFileMenu(Color.White, badge = true) { onSaveFile(msg) } }
            }
            if (msg.fileSize > 0) {
                Text(
                    fileSizeText(msg.fileSize), color = colors.textMuted, fontSize = 9.sp, maxLines = 1,
                    modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 3.dp),
                )
            }
        }
        return
    }

    val textColor = colors.bubbleText(msg.isMine)
    Row(
        Modifier.clickable(enabled = tappable) { onTap() },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Start,
    ) {
        Box(Modifier.size(28.dp), contentAlignment = Alignment.Center) {
            if (download != null) {
                AppLoadingIndicator(size = 20.dp, color = textColor)
            } else {
                Icon(
                    if (needsDownload && !failed) Icons.Filled.Download else icon, null,
                    tint = if (failed) Color(0xFFFF5252) else textColor, modifier = Modifier.size(28.dp),
                )
            }
        }
        Spacer(Modifier.width(8.dp))
        Column {
            Text(msg.fileName ?: msg.text, color = textColor, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 160.dp))
            val sizeText = fileSizeText(msg.fileSize)
            Text(
                when {
                    status == null -> sizeText
                    status.percent != null -> "${status.text} ${status.percent.toInt()}% · $sizeText"
                    else -> "${status.text} · $sizeText"
                },
                color = if (failed) Color(0xFFFF5252) else textColor.copy(alpha = 0.7f), fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        if (cancel != null) {
            Icon(Icons.Filled.Close, null, tint = textColor.copy(alpha = 0.7f), modifier = Modifier.clickable(onClick = cancel).padding(6.dp).size(18.dp))
        }
        if (canSave) SaveFileMenu(textColor, badge = false) { onSaveFile(msg) }
    }
}

/** Альбом: одно вложение — крупно, несколько — плитками по 2–3 в ряд. */
@Composable
fun MediaGrid(
    vm: ChatViewModel,
    media: List<StoredMessage>,
    maxWidth: Dp,
    revealed: Set<String>,
    onReveal: (String) -> Unit,
    onOpenViewer: (StoredMessage) -> Unit,
    onOpenFile: (StoredMessage) -> Unit,
    onSaveFile: (StoredMessage) -> Unit,
) {
    if (media.size == 1) {
        val m = media.single()
        Box(Modifier.clip(RoundedCornerShape(10.dp))) {
            AttachmentBubble(vm, m, 180.dp, m.messageId in revealed, { onReveal(m.messageId) }, onOpenViewer, onOpenFile, onSaveFile)
        }
        return
    }
    val spacing = 3.dp
    val columns = if (media.size >= 3) 3 else 2
    val tile = ((maxWidth - spacing * (columns - 1)) / columns).coerceIn(70.dp, 130.dp)
    FlowRow(horizontalArrangement = Arrangement.spacedBy(spacing), verticalArrangement = Arrangement.spacedBy(spacing), maxItemsInEachRow = columns) {
        media.forEach { m ->
            Box(Modifier.clip(RoundedCornerShape(10.dp))) {
                AttachmentBubble(vm, m, tile, m.messageId in revealed, { onReveal(m.messageId) }, onOpenViewer, onOpenFile, onSaveFile)
            }
        }
    }
}
