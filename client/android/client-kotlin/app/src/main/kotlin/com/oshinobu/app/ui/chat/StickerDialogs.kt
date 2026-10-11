package com.oshinobu.app.ui.chat

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.FolderZip
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.ui.AppLoadingIndicator
import com.oshinobu.app.ui.ErrorRed
import com.oshinobu.app.ui.PrimaryButton
import com.oshinobu.app.ui.SecondaryButton
import com.oshinobu.app.ui.home.AppDialog
import com.oshinobu.app.ui.home.DialogButton
import com.oshinobu.app.ui.theme.CardShape
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.net.StickerInfo
import com.oshinobu.core.net.StickerPackInfo
import com.oshinobu.core.net.StickerUploadException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

// ---------------- пак стикера из переписки ----------------

/**
 * Пак стикера, по которому тапнули в переписке: шторка на полэкрана, пак
 * скачивается целиком; тап по стикеру — отправить его в чат (шторка
 * закрывается), долгое нажатие — превью; "Добавить" / "Удалить" (из своей
 * панели), у автора — ещё "Удалить навсегда" с подтверждением.
 * [onSend] = null — отправлять нельзя (блокировка).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StickerPackSheet(stickerId: String, onSend: ((StickerInfo) -> Unit)?, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val colors = LocalAppColors.current
    val stickers = context.app.core.stickers
    val scope = rememberCoroutineScope()
    var pack by remember { mutableStateOf<StickerPackInfo?>(null) }
    var deleted by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var preview by remember { mutableStateOf<StickerInfo?>(null) }
    val failedText = stringResource(R.string.error_stickersFailed)

    LaunchedEffect(stickerId) {
        val p = try {
            stickers.fetchPackOf(stickerId)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            failed = true
            return@LaunchedEffect
        }
        if (p == null || p.deleted) {
            deleted = true
            return@LaunchedEffect
        }
        pack = p
        // весь пак — на устройство (и в кэш)
        val ok = runCatching { stickers.ensurePack(p) }.getOrDefault(true)
        if (!ok) deleted = true
    }

    fun act(action: suspend () -> Unit) {
        busy = true
        scope.launch {
            try {
                action()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                Toast.makeText(context, failedText, Toast.LENGTH_SHORT).show()
            } finally {
                busy = false
            }
        }
    }

    val sheetHeight = (LocalConfiguration.current.screenHeightDp * 0.5f).dp
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = colors.surface,
    ) {
        Box(Modifier.fillMaxWidth().height(sheetHeight)) {
            val p = pack
            when {
                deleted -> CenteredMessage(stringResource(R.string.sticker_packDeleted))
                failed -> CenteredMessage(failedText)
                p == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { AppLoadingIndicator(size = 56.dp) }
                else -> Column(Modifier.fillMaxSize().navigationBarsPadding()) {
                    Text(
                        p.title, color = colors.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.SemiBold,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 20.dp),
                    )
                    Text(stringResource(R.string.sticker_count, p.stickers.size), color = colors.textMuted, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 20.dp))
                    StickerGrid(
                        p.stickers,
                        onSend = onSend?.let { send ->
                            { sticker ->
                                send(sticker)
                                onDismiss()
                            }
                        },
                        onPreview = { preview = it },
                        modifier = Modifier.weight(1f).fillMaxWidth(),
                    )
                    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                        if (p.installed) {
                            SecondaryButton(stringResource(R.string.sticker_remove), enabled = !busy, onClick = {
                                act {
                                    stickers.uninstall(p.id)
                                    pack = p.copy(installed = false)
                                }
                            })
                        } else {
                            PrimaryButton(stringResource(R.string.sticker_add), loading = busy, onClick = {
                                act {
                                    stickers.install(p)
                                    pack = p.copy(installed = true)
                                }
                            })
                        }
                        if (p.isOwner) {
                            Spacer(Modifier.height(4.dp))
                            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                                DialogButton(stringResource(R.string.sticker_deleteForever), color = ErrorRed) { if (!busy) confirmDelete = true }
                            }
                        }
                    }
                }
            }
            StickerPreviewOverlay(preview)
        }
    }

    val p = pack
    if (confirmDelete && p != null) {
        AppDialog(
            stringResource(R.string.sticker_deleteForeverTitle),
            onDismiss = { confirmDelete = false },
            confirm = {
                DialogButton(stringResource(R.string.sticker_deleteForeverConfirm), color = ErrorRed) {
                    confirmDelete = false
                    act {
                        stickers.deleteForever(p.id)
                        onDismiss()
                    }
                }
            },
            dismiss = { DialogButton(stringResource(R.string.common_cancel)) { confirmDelete = false } },
        ) { Text(stringResource(R.string.sticker_deleteForeverBody, p.title), color = colors.textMuted) }
    }
}

@Composable
private fun CenteredMessage(text: String) {
    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        Text(text, color = LocalAppColors.current.textMuted, fontStyle = FontStyle.Italic, textAlign = TextAlign.Center)
    }
}

// ---------------- загрузка своего пака ----------------

/** Как на сервере: латиница, кириллица, цифры и пробелы, 1–50 символов, без пробелов по краям. */
private const val MAX_TITLE = 50
private val TitleChars = Regex("[A-Za-zА-Яа-яЁё0-9 ]")
private const val MAX_ARCHIVE_BYTES = 80L * 1024 * 1024

private fun validTitle(t: String) = t.isNotEmpty() && t.length <= MAX_TITLE && t.trim() == t && t.all { TitleChars.matches(it.toString()) }

private sealed interface UploadPhase {
    data object Idle : UploadPhase
    data class Running(val text: String, val progress: Float?) : UploadPhase
    data class Failed(val message: String) : UploadPhase
    data class Done(val pack: StickerPackInfo) : UploadPhase
}

private data class PickedArchive(val file: File, val name: String)

/** Сообщение об отказе сервера — по коду причины. */
private fun Context.uploadError(e: StickerUploadException): String {
    val name = e.fileName.orEmpty()
    val limit = e.limit ?: 0
    return when (e.code) {
        "title.invalid" -> getString(R.string.sticker_err_titleInvalid, limit.takeIf { it > 0 } ?: MAX_TITLE)
        "pack.quota" -> getString(R.string.sticker_err_quota, limit)
        "archive.tooLarge" -> getString(R.string.sticker_err_archiveTooLarge, limit)
        "archive.invalid" -> getString(R.string.sticker_err_archiveInvalid)
        "archive.empty" -> getString(R.string.sticker_err_archiveEmpty)
        "archive.tooMany" -> getString(R.string.sticker_err_archiveTooMany, limit)
        "file.webm" -> getString(R.string.sticker_err_webm, name)
        "file.unsupported" -> getString(R.string.sticker_err_unsupported, name)
        "file.tooLarge" -> getString(R.string.sticker_err_tooLarge, name, limit)
        "file.corrupt" -> getString(R.string.sticker_err_corrupt, name)
        "file.badDimensions" -> getString(R.string.sticker_err_dimensions, name, limit)
        else -> getString(R.string.sticker_err_server)
    }
}

/** Выбранный архив — во временный файл (загрузка идёт из файла); null — это не ZIP. */
private suspend fun Context.copyArchive(uri: Uri): PickedArchive? = withContext(Dispatchers.IO) {
    val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
        if (c.moveToFirst()) c.getString(0) else null
    } ?: "archive.zip"
    val dest = File(cacheDir, "sticker-upload.zip")
    contentResolver.openInputStream(uri)?.use { input -> dest.outputStream().use { input.copyTo(it) } } ?: return@withContext null
    // ZIP начинается с "PK\3\4" — остальное не берём, как бы ни назывался файл
    val magic = ByteArray(4)
    val read = dest.inputStream().use { it.read(magic) }
    if (read < 4 || magic[0] != 'P'.code.toByte() || magic[1] != 'K'.code.toByte() || magic[2] != 3.toByte() || magic[3] != 4.toByte()) {
        dest.delete()
        return@withContext null
    }
    PickedArchive(dest, name)
}

/**
 * Загрузка своего пака: название, ZIP-архив, затем живой прогресс —
 * отправка архива и каждый шаг проверки на сервере. Уйти (отмена, "назад")
 * во время загрузки — только через предупреждение; ушли — загрузка
 * прерывается, сервер ничего не сохраняет.
 */
@Composable
fun StickerUploadDialog(onClose: () -> Unit) {
    val context = LocalContext.current
    val colors = LocalAppColors.current
    val stickers = context.app.core.stickers
    val scope = rememberCoroutineScope()
    var title by remember { mutableStateOf("") }
    var archive by remember { mutableStateOf<PickedArchive?>(null) }
    var pickError by remember { mutableStateOf<String?>(null) }
    var phase by remember { mutableStateOf<UploadPhase>(UploadPhase.Idle) }
    var job by remember { mutableStateOf<Job?>(null) }
    var confirmLeave by remember { mutableStateOf(false) }
    val running = phase is UploadPhase.Running

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val picked = runCatching { context.copyArchive(uri) }.getOrNull()
            archive = picked
            pickError = if (picked == null) context.getString(R.string.sticker_uploadNotZip) else null
            if (picked != null && picked.file.length() > MAX_ARCHIVE_BYTES) {
                archive = null
                pickError = context.getString(R.string.sticker_err_archiveTooLarge, (MAX_ARCHIVE_BYTES / (1024 * 1024)).toInt())
            }
            if (phase is UploadPhase.Failed) phase = UploadPhase.Idle
        }
    }

    fun leave() {
        job?.cancel()
        archive?.file?.delete()
        onClose()
    }

    fun requestClose() {
        if (running) confirmLeave = true else leave()
    }

    fun start() {
        val file = archive?.file ?: return
        phase = UploadPhase.Running(context.getString(R.string.sticker_uploadSending, 0), 0f)
        job = scope.launch {
            phase = try {
                val pack = stickers.upload(
                    title, file,
                    onProgress = { p ->
                        // после 100% отправки сервер ещё проверяет — следующие шаги придут событиями
                        if (p < 100.0) phase = UploadPhase.Running(context.getString(R.string.sticker_uploadSending, p.toInt()), (p / 100).toFloat())
                    },
                    onEvent = { e ->
                        phase = when (e.stage) {
                            "received" -> UploadPhase.Running(context.getString(R.string.sticker_stageReceived), null)
                            "unpacking" -> UploadPhase.Running(context.getString(R.string.sticker_stageUnpacking), null)
                            "counting" -> UploadPhase.Running(context.getString(R.string.sticker_stageCounting, e.count ?: 0), null)
                            "checking" -> UploadPhase.Running(
                                context.getString(R.string.sticker_stageChecking, e.index ?: 0, e.total ?: 0) + (e.name?.let { "\n$it" } ?: ""),
                                fraction(e.index, e.total),
                            )
                            "saving" -> UploadPhase.Running(context.getString(R.string.sticker_stageSaving, e.index ?: 0, e.total ?: 0), fraction(e.index, e.total))
                            "registering" -> UploadPhase.Running(context.getString(R.string.sticker_stageRegistering), null)
                            else -> phase
                        }
                    },
                )
                archive?.file?.delete()
                archive = null
                UploadPhase.Done(pack)
            } catch (e: CancellationException) {
                throw e
            } catch (e: StickerUploadException) {
                UploadPhase.Failed(context.uploadError(e))
            } catch (e: Exception) {
                UploadPhase.Failed(context.getString(R.string.error_uploadFailed))
            }
        }
    }

    Dialog(onDismissRequest = ::requestClose, properties = DialogProperties(dismissOnClickOutside = false, usePlatformDefaultWidth = false)) {
        Column(
            Modifier.padding(horizontal = 20.dp).fillMaxWidth().background(colors.surface, CardShape).padding(20.dp),
        ) {
            AnimatedContent(phase is UploadPhase.Done, transitionSpec = { fadeIn(tween(200)) togetherWith fadeOut(tween(200)) }, label = "uploadDone") { done ->
                if (done) {
                    val pack = (phase as? UploadPhase.Done)?.pack
                    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(Icons.Filled.CheckCircle, null, tint = colors.primary, modifier = Modifier.size(56.dp))
                        Spacer(Modifier.height(10.dp))
                        Text(stringResource(R.string.sticker_uploadDone), color = colors.textPrimary, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                        Spacer(Modifier.height(6.dp))
                        Text(stringResource(R.string.sticker_uploadDoneBody, pack?.title.orEmpty()), color = colors.textMuted, textAlign = TextAlign.Center)
                        Spacer(Modifier.height(18.dp))
                        PrimaryButton(stringResource(R.string.sticker_ok), onClick = onClose)
                    }
                } else {
                    UploadForm(
                        title = title,
                        onTitle = { t -> if (!running) title = t.filter { TitleChars.matches(it.toString()) }.take(MAX_TITLE) },
                        archive = archive,
                        pickError = pickError,
                        phase = phase,
                        onPick = { picker.launch(arrayOf("application/zip", "application/x-zip-compressed", "application/x-zip")) },
                        onStart = ::start,
                        onCancel = ::requestClose,
                    )
                }
            }
        }
    }

    if (confirmLeave) {
        AppDialog(
            stringResource(R.string.sticker_uploadLeaveTitle),
            onDismiss = { confirmLeave = false },
            confirm = {
                DialogButton(stringResource(R.string.sticker_uploadLeaveConfirm), color = ErrorRed) {
                    confirmLeave = false
                    leave()
                }
            },
            dismiss = { DialogButton(stringResource(R.string.sticker_uploadContinue)) { confirmLeave = false } },
        ) { Text(stringResource(R.string.sticker_uploadLeaveBody), color = colors.textMuted) }
    }
}

private fun fraction(index: Int?, total: Int?): Float? =
    if (index != null && total != null && total > 0) (index.toFloat() / total).coerceIn(0f, 1f) else null

@Composable
private fun UploadForm(
    title: String,
    onTitle: (String) -> Unit,
    archive: PickedArchive?,
    pickError: String?,
    phase: UploadPhase,
    onPick: () -> Unit,
    onStart: () -> Unit,
    onCancel: () -> Unit,
) {
    val colors = LocalAppColors.current
    val running = phase is UploadPhase.Running
    Column(Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.sticker_uploadTitle), color = colors.textPrimary, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(14.dp))
        TextField(
            value = title,
            onValueChange = onTitle,
            enabled = !running,
            singleLine = true,
            label = { Text(stringResource(R.string.sticker_uploadName)) },
            supportingText = { Text("${stringResource(R.string.sticker_uploadNameHint, MAX_TITLE)} · ${title.length}/$MAX_TITLE") },
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
            shape = CardShape,
            modifier = Modifier.fillMaxWidth(),
            colors = TextFieldDefaults.colors(
                focusedContainerColor = colors.background,
                unfocusedContainerColor = colors.background,
                disabledContainerColor = colors.background,
                focusedIndicatorColor = Color.Transparent,
                unfocusedIndicatorColor = Color.Transparent,
                disabledIndicatorColor = Color.Transparent,
                focusedTextColor = colors.textPrimary,
                unfocusedTextColor = colors.textPrimary,
                disabledTextColor = colors.textMuted,
                focusedLabelColor = colors.primary,
                unfocusedLabelColor = colors.textMuted,
                focusedSupportingTextColor = colors.textMuted,
                unfocusedSupportingTextColor = colors.textMuted,
                cursorColor = colors.primary,
            ),
        )
        Spacer(Modifier.height(6.dp))
        Text(stringResource(R.string.sticker_uploadRules), color = colors.textMuted, fontSize = 12.5.sp)
        Spacer(Modifier.height(12.dp))
        Row(
            Modifier.fillMaxWidth().background(colors.background, CardShape).padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Outlined.FolderZip, null, tint = colors.primary, modifier = Modifier.size(22.dp))
            Spacer(Modifier.width(10.dp))
            Text(
                archive?.name ?: stringResource(R.string.sticker_uploadPick),
                color = if (archive != null) colors.textPrimary else colors.textMuted,
                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
            )
            if (!running) {
                DialogButton(stringResource(if (archive == null) R.string.sticker_uploadPick else R.string.sticker_uploadChange), onClick = onPick)
            }
        }
        pickError?.let {
            Spacer(Modifier.height(6.dp))
            Text(it, color = ErrorRed, fontSize = 13.sp)
        }
        when (phase) {
            is UploadPhase.Running -> {
                Spacer(Modifier.height(16.dp))
                if (phase.progress != null) {
                    LinearProgressIndicator(
                        progress = { phase.progress }, modifier = Modifier.fillMaxWidth(),
                        color = colors.primary, trackColor = colors.background, drawStopIndicator = {},
                    )
                } else {
                    LinearProgressIndicator(Modifier.fillMaxWidth(), color = colors.primary, trackColor = colors.background)
                }
                Spacer(Modifier.height(8.dp))
                Text(phase.text, color = colors.textPrimary, fontSize = 13.5.sp, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
            is UploadPhase.Failed -> {
                Spacer(Modifier.height(14.dp))
                Text(phase.message, color = ErrorRed, fontSize = 13.5.sp)
            }
            else -> Unit
        }
        Spacer(Modifier.height(18.dp))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            SecondaryButton(stringResource(R.string.common_cancel), onClick = onCancel, modifier = Modifier.weight(1f))
            Spacer(Modifier.width(10.dp))
            PrimaryButton(
                stringResource(R.string.sticker_uploadStart),
                onClick = onStart,
                enabled = validTitle(title) && archive != null && !running,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

