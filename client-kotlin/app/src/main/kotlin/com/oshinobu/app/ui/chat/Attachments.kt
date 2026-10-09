package com.oshinobu.app.ui.chat

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.outlined.PermMedia
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import com.oshinobu.app.app
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.service.OutgoingFile
import com.oshinobu.core.storage.PendingSendStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

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

    Box {
        IconButton(onClick = { open = !open }, modifier = Modifier.size(36.dp)) {
            Icon(Icons.Filled.AttachFile, null, tint = colors.textMuted)
        }
        if (open) {
            // кнопки выбора — столбиком над скрепкой
            val lift = with(LocalDensity.current) { 48.dp.roundToPx() }
            Popup(alignment = Alignment.BottomCenter, offset = IntOffset(0, -lift), onDismissRequest = { open = false }) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    AttachChoice(Icons.Outlined.PermMedia) {
                        open = false
                        gallery = true
                    }
                    AttachChoice(Icons.AutoMirrored.Outlined.InsertDriveFile) {
                        open = false
                        documents.launch(arrayOf("*/*"))
                    }
                }
            }
        }
    }
    if (gallery) GallerySheet(onDismiss = { gallery = false }, onSend = onSendMedia)
}

@Composable
private fun AttachChoice(icon: ImageVector, onClick: () -> Unit) {
    val colors = LocalAppColors.current
    Box(
        Modifier.size(48.dp).clip(CircleShape).background(colors.primary).clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, null, tint = Color.White, modifier = Modifier.size(24.dp)) }
}

/** Выбранное → файлы для отправки. */
fun List<PickedFile>.toOutgoing(asFiles: Boolean, spoiler: Boolean = false) =
    map { OutgoingFile(it.file, isFile = asFiles, isVideo = !asFiles && it.isVideo, isSpoiler = spoiler && !asFiles, name = it.name) }
