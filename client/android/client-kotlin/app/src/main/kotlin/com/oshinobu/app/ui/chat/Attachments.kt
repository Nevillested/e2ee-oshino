package com.oshinobu.app.ui.chat

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutLinearInEasing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.outlined.PermMedia
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.lerp
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import com.oshinobu.app.app
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.service.OutgoingFile
import com.oshinobu.core.storage.PendingSendStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin

/** Выбранный, но ещё не отправленный файл (копия уже в постоянной папке отправок). */
data class PickedFile(val file: File, val name: String, val isVideo: Boolean)

/** Копирование выбранного (галерея, документы, клавиатура — content://) в папку отправок. */
object MediaImport {
    private fun displayName(context: Context, uri: Uri): String? =
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }

    suspend fun import(context: Context, uri: Uri, store: PendingSendStore): PickedFile? = withContext(Dispatchers.IO) {
        val mime = context.contentResolver.getType(uri).orEmpty()
        val name = displayName(context, uri)
            ?: "file.${MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: "bin"}"
        val target = store.newPersistedFile(name.substringAfterLast('.', ""))
        runCatching {
            context.contentResolver.openInputStream(uri)!!.use { input -> target.outputStream().use { input.copyTo(it) } }
            PickedFile(target, name, mime.startsWith("video/"))
        }.getOrElse {
            target.delete()
            null
        }
    }
}

/**
 * Скрепка: по тапу над ней раскрываются две кнопки — фото и видео (своя
 * галерея с камерой, подписью и спойлером) и файлы (системный выбор
 * документов; уходят сразу, по одному).
 */
@Composable
fun AttachButton(onSendMedia: (List<PickedFile>, caption: String, spoiler: Boolean) -> Unit, onSendFiles: (List<PickedFile>) -> Unit) {
    val context = LocalContext.current
    val colors = LocalAppColors.current
    val store = context.app.core.pendingSends
    val scope = rememberCoroutineScope()
    var open by remember { mutableStateOf(false) }
    var gallery by remember { mutableStateOf(false) }

    val documents = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        scope.launch {
            val files = uris.mapNotNull { MediaImport.import(context, it, store) }
            if (files.isNotEmpty()) onSendFiles(files)
        }
    }

    var anchor by remember { mutableStateOf(Offset.Zero) }
    IconButton(
        onClick = { open = true },
        modifier = Modifier.size(36.dp).onGloballyPositioned { anchor = it.boundsInWindow().center },
    ) { Icon(Icons.Filled.AttachFile, null, tint = colors.textMuted) }
    if (open) {
        AttachLauncher(anchor) { choice ->
            open = false
            when (choice) {
                AttachChoice.MEDIA -> gallery = true
                AttachChoice.FILES -> documents.launch(arrayOf("*/*"))
                null -> Unit
            }
        }
    }
    if (gallery) GallerySheet(onDismiss = { gallery = false }, onSend = onSendMedia)
}

private enum class AttachChoice { MEDIA, FILES }

private val ArrowLength = 70.dp
private val ChoiceCircle = 48.dp

/**
 * Развилка по скрепке: экран затемняется, скрепка остаётся яркой, от неё под
 * 45° выезжают две стрелки — влево к "Медиафайлы", вправо к "Документы".
 * Тап мимо или "назад" — всё сворачивается обратно; [onResult] — после анимации.
 */
@Composable
private fun AttachLauncher(anchor: Offset, onResult: (AttachChoice?) -> Unit) {
    val colors = LocalAppColors.current
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val t = remember { Animatable(0f) }
    var closing by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { t.animateTo(1f, tween(320, easing = FastOutSlowInEasing)) }

    fun close(result: AttachChoice?) {
        if (closing) return
        closing = true
        scope.launch {
            t.animateTo(0f, tween(240, easing = FastOutLinearInEasing))
            onResult(result)
        }
    }

    Dialog(onDismissRequest = { close(null) }, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        // своё затемнение вместо системного — оно анимируется вместе со стрелками
        (LocalView.current.parent as? DialogWindowProvider)?.window?.setDimAmount(0f)
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val (len, circle, margin) = with(density) { Triple(ArrowLength.toPx(), ChoiceCircle.toPx(), 28.dp.toPx()) }
            val width = constraints.maxWidth.toFloat()
            val diag = len * 0.70710677f
            fun end(dir: Int) = Offset((anchor.x + dir * diag).coerceIn(margin, (width - margin).coerceAtLeast(margin)), anchor.y - diag)
            val left = end(-1)
            val right = end(1)
            Canvas(
                Modifier.fillMaxSize().pointerInput(Unit) { detectTapGestures { close(null) } },
            ) {
                val p = t.value
                drawRect(Color.Black.copy(alpha = 0.55f * p))
                for (target in listOf(left, right)) drawArrow(anchor, pullBack(anchor, target, circle / 2 + 6.dp.toPx()), p)
            }
            // яркий клон скрепки поверх затемнения
            Icon(
                Icons.Filled.AttachFile, null, tint = Color.White,
                modifier = Modifier.offset { IntOffset((anchor.x - 12.dp.toPx()).toInt(), (anchor.y - 12.dp.toPx()).toInt()) }
                    .size(24.dp).graphicsLayer { alpha = t.value },
            )
            for ((center, icon, choice) in listOf(
                Triple(left, Icons.Outlined.PermMedia, AttachChoice.MEDIA),
                Triple(right, Icons.AutoMirrored.Outlined.InsertDriveFile, AttachChoice.FILES),
            )) {
                Box(
                    Modifier.offset { IntOffset((center.x - circle / 2).toInt(), (center.y - circle / 2).toInt()) }
                        .size(ChoiceCircle)
                        .graphicsLayer {
                            alpha = t.value
                            scaleX = 0.4f + 0.6f * t.value
                            scaleY = 0.4f + 0.6f * t.value
                        }
                        .clip(CircleShape).background(colors.primary).clickable { close(choice) },
                    contentAlignment = Alignment.Center,
                ) { Icon(icon, null, tint = Color.White, modifier = Modifier.size(22.dp)) }
            }
        }
    }
}

/** Конец стрелки отступает от центра кружка, чтобы наконечник упирался В него, а не прятался под ним. */
private fun pullBack(start: Offset, end: Offset, by: Float): Offset {
    val dir = end - start
    val length = dir.getDistance()
    if (length <= by) return start
    return end - dir * (by / length)
}

/** Белая стрелка от [start] к [end], растущая с [progress]. */
private fun DrawScope.drawArrow(start: Offset, end: Offset, progress: Float) {
    if (progress <= 0f) return
    val color = Color.White.copy(alpha = progress)
    val tip = lerp(start, end, progress)
    drawLine(color, start, tip, strokeWidth = 2.5.dp.toPx(), cap = StrokeCap.Round)
    if (progress < 0.15f) return
    val angle = atan2(end.y - start.y, end.x - start.x)
    val head = 10.dp.toPx()
    val spread = 0.5f
    val p1 = tip - Offset(head * cos(angle - spread), head * sin(angle - spread))
    val p2 = tip - Offset(head * cos(angle + spread), head * sin(angle + spread))
    drawPath(Path().apply { moveTo(tip.x, tip.y); lineTo(p1.x, p1.y); lineTo(p2.x, p2.y); close() }, color)
}

/** Выбранное → файлы для отправки. */
fun List<PickedFile>.toOutgoing(asFiles: Boolean, spoiler: Boolean = false) =
    map { OutgoingFile(it.file, isFile = asFiles, isVideo = !asFiles && it.isVideo, isSpoiler = spoiler && !asFiles, name = it.name) }
