package com.oshinobu.app.ui.chat

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.os.Build
import android.widget.VideoView
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.view.LifecycleCameraController
import androidx.camera.view.PreviewView
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.CheckBoxOutlineBlank
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.PlayCircleFilled
import androidx.compose.material.icons.outlined.EmojiEmotions
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.media.DeviceGallery
import com.oshinobu.app.media.GalleryAccess
import com.oshinobu.app.media.GalleryItem
import com.oshinobu.app.media.MediaDecoding
import com.oshinobu.app.ui.theme.LocalAppColors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Своя галерея (как во Flutter-клиенте): шторка с сеткой фото и видео, первая
 * плитка — живая камера (тап — экран съёмки). Кружок в углу плитки — выбор с
 * номером порядка, тап по плитке — просмотр на весь экран. С выбором — счётчик,
 * "скрыть под спойлером" и подпись; отправка — альбомом.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GallerySheet(onDismiss: () -> Unit, onSend: (List<PickedFile>, caption: String, spoiler: Boolean) -> Unit) {
    val context = LocalContext.current
    val colors = LocalAppColors.current
    val scope = rememberCoroutineScope()
    // шторка сразу открыта полностью — иначе нижняя часть (подпись и "отправить") уходит за край экрана
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var access by remember { mutableStateOf(DeviceGallery.access(context)) }
    var items by remember { mutableStateOf<List<GalleryItem>?>(null) }
    var version by remember { mutableIntStateOf(0) }
    val selected = remember { mutableStateListOf<GalleryItem>() }
    var spoiler by remember { mutableStateOf(false) }
    var previewIndex by remember { mutableStateOf<Int?>(null) }
    var cameraOpen by remember { mutableStateOf(false) }
    var sending by remember { mutableStateOf(false) }

    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        access = DeviceGallery.access(context)
        version++
    }
    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { if (it) cameraOpen = true }
    LaunchedEffect(Unit) { if (access == GalleryAccess.NONE) permissionLauncher.launch(DeviceGallery.permissions) }
    LaunchedEffect(access, version) { if (access != GalleryAccess.NONE) items = DeviceGallery.load(context) else items = emptyList() }
    DisposableEffect(Unit) {
        val stop = DeviceGallery.observe(context) { version++ }
        onDispose { stop() }
    }

    fun toggle(item: GalleryItem) {
        if (item in selected) selected.remove(item) else selected.add(item)
        if (selected.isEmpty()) spoiler = false
    }

    fun close(then: () -> Unit = {}) = scope.launch {
        sheet.hide()
        onDismiss()
        then()
    }

    fun send(caption: String) {
        if (sending) return
        sending = true
        val ordered = selected.toList()
        scope.launch {
            val store = context.app.core.pendingSends
            val files = ordered.mapNotNull { MediaImport.import(context, it.uri, store) }
            close { if (files.isNotEmpty()) onSend(files, caption, spoiler) }
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet, containerColor = colors.background) {
        Column(Modifier.fillMaxHeight(0.75f)) {
            if (access == GalleryAccess.PARTIAL) {
                Row(
                    Modifier.fillMaxWidth().background(colors.primary.copy(alpha = 0.15f))
                        .clickable { permissionLauncher.launch(DeviceGallery.permissions) }.padding(horizontal = 14.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Outlined.Info, null, tint = colors.primary, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.media_limitedAccess), color = colors.textPrimary, fontSize = 12.sp)
                }
            }
            AnimatedVisibility(selected.isNotEmpty(), enter = expandVertically() + fadeIn(), exit = shrinkVertically() + fadeOut()) {
                SelectionBar(selected.size, spoiler) { spoiler = !spoiler }
            }
            Box(Modifier.weight(1f)) {
                val list = items
                if (list == null) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = colors.primary) }
                } else {
                    LazyVerticalGrid(
                        GridCells.Fixed(3), Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(bottom = if (selected.isNotEmpty()) 72.dp else 0.dp),
                    ) {
                        item(key = "camera") {
                            CameraTile(live = !cameraOpen) {
                                val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
                                if (granted) cameraOpen = true else cameraPermission.launch(Manifest.permission.CAMERA)
                            }
                        }
                        items(list, key = { it.id }) { item ->
                            val order = selected.indexOf(item).takeIf { it >= 0 }?.plus(1)
                            GalleryTile(item, order, blurred = spoiler && order != null, onOpen = { previewIndex = list.indexOf(item) }, onToggle = { toggle(item) })
                        }
                    }
                }
                if (selected.isNotEmpty()) {
                    Box(Modifier.align(Alignment.BottomCenter)) { CaptionBar(sending, ::send) }
                }
            }
        }
    }

    previewIndex?.let { start ->
        GalleryPreview(items.orEmpty(), start, selected, onToggle = ::toggle, onClose = { previewIndex = null })
    }
    if (cameraOpen) {
        CameraCaptureDialog(onClose = { cameraOpen = false }) { file, caption ->
            cameraOpen = false
            close { onSend(listOf(file), caption, false) }
        }
    }
}

/** "Выбрано: N" и меню со спойлером. */
@Composable
private fun SelectionBar(count: Int, spoiler: Boolean, onToggleSpoiler: () -> Unit) {
    val colors = LocalAppColors.current
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        AnimatedContent(count, transitionSpec = { (scaleIn() + fadeIn()) togetherWith (scaleOut() + fadeOut()) }, label = "count") { n ->
            Text("${stringResource(R.string.media_selectedCount)}: $n", color = colors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
        }
        Spacer(Modifier.weight(1f))
        Box {
            IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, null, tint = colors.textPrimary) }
            DropdownMenu(menu, { menu = false }) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.media_hideWithSpoiler)) },
                    leadingIcon = { Icon(if (spoiler) Icons.Filled.CheckBox else Icons.Filled.CheckBoxOutlineBlank, null) },
                    onClick = {
                        menu = false
                        onToggleSpoiler()
                    },
                )
            }
        }
    }
}

/** Плитка с живым превью задней камеры (без разрешения — просто значок). */
@Composable
private fun CameraTile(live: Boolean, onClick: () -> Unit) {
    val context = LocalContext.current
    val colors = LocalAppColors.current
    val owner = LocalLifecycleOwner.current
    val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
    Box(Modifier.aspectRatio(1f).border(0.5.dp, Color.Black.copy(alpha = 0.26f)).background(colors.surface).clickable(onClick = onClick)) {
        if (live && granted) {
            val controller = remember { LifecycleCameraController(context) }
            DisposableEffect(owner) {
                controller.bindToLifecycle(owner)
                onDispose { controller.unbind() }
            }
            AndroidView(
                factory = { ctx -> PreviewView(ctx).apply { scaleType = PreviewView.ScaleType.FILL_CENTER; this.controller = controller } },
                modifier = Modifier.fillMaxSize(),
            )
        }
        Icon(Icons.Filled.CameraAlt, null, tint = Color.White, modifier = Modifier.align(Alignment.TopEnd).padding(6.dp).size(20.dp))
    }
}

@Composable
private fun rememberThumbnail(item: GalleryItem): Bitmap? {
    val context = LocalContext.current
    val bitmap by produceState(DeviceGallery.cachedThumbnail(item), item.id) { if (value == null) value = DeviceGallery.thumbnail(context, item) }
    return bitmap
}

/** Кружок выбора с номером порядка. */
@Composable
private fun OrderBadge(order: Int?, size: Int) {
    val colors = LocalAppColors.current
    Box(
        Modifier.size(size.dp).clip(CircleShape).background(if (order != null) colors.primary else Color.Black.copy(alpha = 0.45f))
            .border(1.5.dp, Color.White, CircleShape),
        contentAlignment = Alignment.Center,
    ) { if (order != null) Text("$order", color = Color.White, fontSize = (size / 2).sp, fontWeight = FontWeight.Bold) }
}

@Composable
private fun GalleryTile(item: GalleryItem, order: Int?, blurred: Boolean, onOpen: () -> Unit, onToggle: () -> Unit) {
    val colors = LocalAppColors.current
    val thumb = rememberThumbnail(item)
    Box(Modifier.aspectRatio(1f).border(0.5.dp, Color.Black.copy(alpha = 0.26f)).background(colors.surface).clickable(onClick = onOpen)) {
        thumb?.let {
            val blur = if (blurred && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Modifier.blur(12.dp) else Modifier
            Image(it.asImageBitmap(), null, Modifier.fillMaxSize().then(blur), contentScale = ContentScale.Crop)
        }
        if (blurred) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.6f)))
            SpoilerParticles(Modifier.fillMaxSize())
        }
        if (item.isVideo) {
            Icon(Icons.Filled.PlayCircleFilled, null, tint = Color.White, modifier = Modifier.align(Alignment.BottomStart).padding(4.dp).size(20.dp))
        }
        // правая верхняя четверть плитки — зона выбора, остальное — просмотр
        Box(
            Modifier.align(Alignment.TopEnd).fillMaxWidth(0.5f).fillMaxHeight(0.5f).clickable(onClick = onToggle),
            contentAlignment = Alignment.TopEnd,
        ) { Box(Modifier.padding(6.dp)) { OrderBadge(order, 24) } }
    }
}

/** Просмотр выбранного на весь экран: листание, выбор кружком сверху, видео с перемоткой. */
@Composable
private fun GalleryPreview(items: List<GalleryItem>, start: Int, selected: List<GalleryItem>, onToggle: (GalleryItem) -> Unit, onClose: () -> Unit) {
    if (items.isEmpty()) return
    val pager = rememberPagerState(initialPage = start.coerceIn(0, items.size - 1)) { items.size }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            HorizontalPager(pager, Modifier.fillMaxSize()) { page -> PreviewPage(items[page], current = pager.currentPage == page) }
            Row(Modifier.fillMaxWidth().statusBarsPadding().padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, null, tint = Color.White) }
                Spacer(Modifier.weight(1f))
                val item = items[pager.currentPage]
                val order = selected.indexOf(item).takeIf { it >= 0 }?.plus(1)
                Box(Modifier.padding(end = 14.dp).clickable { onToggle(item) }) { OrderBadge(order, 28) }
            }
        }
    }
}

@Composable
private fun PreviewPage(item: GalleryItem, current: Boolean) {
    val context = LocalContext.current
    if (!item.isVideo) {
        val density = LocalDensity.current
        val px = with(density) { 1600.dp.roundToPx() }.coerceAtMost(2560)
        val bitmap by produceState<Bitmap?>(null, item.id) {
            value = withContext(Dispatchers.IO) {
                runCatching {
                    val tmp = File(context.cacheDir, "gallery_preview_${item.id}")
                    if (!tmp.exists()) context.contentResolver.openInputStream(item.uri)!!.use { input -> tmp.outputStream().use { input.copyTo(it) } }
                    MediaDecoding.decodeImage(tmp, px).also { tmp.delete() }
                }.getOrNull()
            }
        }
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            bitmap?.let { Image(it.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit) }
                ?: CircularProgressIndicator(color = Color.White)
        }
        return
    }
    val view = remember { arrayOfNulls<VideoView>(1) }
    var playing by remember { mutableStateOf(false) }
    var position by remember { mutableFloatStateOf(0f) }
    var duration by remember { mutableFloatStateOf(0f) }
    var dragging by remember { mutableStateOf<Float?>(null) }
    LaunchedEffect(current) {
        val v = view[0] ?: return@LaunchedEffect
        if (!current) {
            v.pause()
            playing = false
        }
    }
    LaunchedEffect(Unit) {
        while (true) {
            view[0]?.let { v ->
                if (dragging == null) position = v.currentPosition.toFloat()
                if (v.duration > 0) duration = v.duration.toFloat()
                playing = v.isPlaying
            }
            delay(200)
        }
    }
    DisposableEffect(Unit) { onDispose { view[0]?.stopPlayback() } }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        AndroidView(
            factory = { ctx ->
                VideoView(ctx).apply {
                    setVideoURI(item.uri)
                    setOnPreparedListener { if (current) start() }
                    view[0] = this
                }
            },
            modifier = Modifier.fillMaxWidth().clickable {
                view[0]?.let { if (it.isPlaying) it.pause() else it.start() }
            },
        )
        if (!playing) Icon(Icons.Filled.PlayArrow, null, tint = Color.White.copy(alpha = 0.7f), modifier = Modifier.size(64.dp))
        if (duration > 0) {
            Row(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth().background(Color.Black.copy(alpha = 0.45f)).navigationBarsPadding()
                    .padding(horizontal = 12.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                val shown = dragging ?: position
                Text(formatClock(shown.toLong()), color = Color.White, fontSize = 12.sp)
                Slider(
                    value = shown.coerceIn(0f, duration), valueRange = 0f..duration,
                    onValueChange = { dragging = it },
                    onValueChangeFinished = {
                        dragging?.let { view[0]?.seekTo(it.toInt()); position = it }
                        dragging = null
                    },
                    colors = SliderDefaults.colors(thumbColor = LocalAppColors.current.primary, activeTrackColor = LocalAppColors.current.primary, inactiveTrackColor = Color.White.copy(alpha = 0.24f)),
                    modifier = Modifier.weight(1f).padding(horizontal = 8.dp),
                )
                Text(formatClock(duration.toLong()), color = Color.White, fontSize = 12.sp)
            }
        }
    }
}

private fun formatClock(ms: Long): String {
    val s = ms / 1000
    val h = s / 3600
    val mm = ((s % 3600) / 60).toString().padStart(2, '0')
    val ss = (s % 60).toString().padStart(2, '0')
    return if (h > 0) "$h:$mm:$ss" else "$mm:$ss"
}

/** Подпись к выбранному: эмодзи/клавиатура, поле, "отправить". Эмодзи — панелью на месте клавиатуры. */
@Composable
fun CaptionBar(sending: Boolean, onSend: (String) -> Unit) {
    val colors = LocalAppColors.current
    val context = LocalContext.current
    var text by remember { mutableStateOf("") }
    var emoji by remember { mutableStateOf(false) }
    BackHandler(enabled = emoji) { emoji = false }
    Column(Modifier.fillMaxWidth().imePadding()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp).background(colors.surface, RoundedCornerShape(24.dp)).padding(horizontal = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = { emoji = !emoji }) {
                Icon(if (emoji) Icons.Filled.Keyboard else Icons.Outlined.EmojiEmotions, null, tint = colors.textMuted)
            }
            Box(Modifier.weight(1f).padding(vertical = 12.dp)) {
                if (text.isEmpty()) Text(stringResource(R.string.chat_captionHint), color = colors.textMuted)
                BasicTextField(
                    text, { text = it }, maxLines = 4,
                    textStyle = TextStyle(color = colors.textPrimary, fontSize = 16.sp),
                    cursorBrush = SolidColor(colors.primary), modifier = Modifier.fillMaxWidth(),
                )
            }
            if (sending) {
                CircularProgressIndicator(Modifier.padding(10.dp).size(24.dp), color = colors.primary, strokeWidth = 2.dp)
            } else {
                IconButton(onClick = { onSend(text.trim()) }) { Icon(Icons.AutoMirrored.Filled.Send, null, tint = colors.primary) }
            }
        }
        if (emoji) {
            EmojiPanel(context.app.core.settings.keyboardHeight().dp) { text += it }
        } else {
            Spacer(Modifier.navigationBarsPadding())
        }
    }
}
