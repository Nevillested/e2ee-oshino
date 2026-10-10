package com.oshinobu.app.ui.chat

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.os.Build
import android.widget.Toast
import android.widget.VideoView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.BrokenImage
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.media.FileActions
import com.oshinobu.app.media.MediaDecoding
import com.oshinobu.app.ui.AppLoadingIndicator
import com.oshinobu.app.ui.theme.CardShape
import com.oshinobu.core.storage.StoredMessage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.abs

/** Вложения, которые листаются в просмотрщике: фото и видео (не файлы, не голосовые, не кружки). */
private fun StoredMessage.viewable() = isMedia && !isFile && !isVoice && !isVideoNote

/**
 * Просмотр фото и видео чата на весь экран: свайп в стороны — соседние,
 * свайп вверх/вниз — закрыть; фото — щипок и двойной тап для увеличения
 * (пока увеличено, листание и закрытие свайпом выключены); видео — тап
 * пауза/продолжить. В меню — "сохранить в галерею".
 */
@Composable
fun MediaViewerScreen(peerLogin: String, messageId: String, onBack: () -> Unit) {
    val context = LocalContext.current
    val core = context.app.core
    val labels = rememberMediaLabels()
    val resolver = remember { MediaResolver(core, peerLogin, labels) }
    val items by produceState<List<StoredMessage>?>(null) { value = core.chats.getMessages(peerLogin).filter { it.viewable() } }
    val list = items ?: return
    val start = list.indexOfFirst { it.messageId == messageId }.coerceAtLeast(0)
    if (list.isEmpty()) {
        LaunchedEffect(Unit) { onBack() }
        return
    }
    val pager = rememberPagerState(initialPage = start) { list.size }
    var zoomed by remember { mutableStateOf(false) }
    val dismiss = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current

    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = (1f - abs(dismiss.value) / 1500f).coerceIn(0.3f, 1f)))) {
        HorizontalPager(pager, userScrollEnabled = !zoomed, modifier = Modifier.fillMaxSize().graphicsLayer { translationY = dismiss.value }) { page ->
            val msg = list[page]
            MediaPage(
                msg = msg,
                resolver = resolver,
                current = pager.currentPage == page,
                onZoomChanged = { zoomed = it },
                onDismissDrag = { dy -> scope.launch { dismiss.snapTo(dismiss.value + dy) } },
                onDismissEnd = {
                    scope.launch {
                        if (abs(dismiss.value) > with(density) { 120.dp.toPx() }) {
                            dismiss.animateTo(if (dismiss.value > 0) 3000f else -3000f, tween(200))
                            onBack()
                        } else {
                            dismiss.animateTo(0f, tween(180))
                        }
                    }
                },
            )
        }
        ViewerTopBar(list[pager.currentPage], resolver, onBack)
    }
}

@Composable
private fun ViewerTopBar(msg: StoredMessage, resolver: MediaResolver, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var menuOpen by remember { mutableStateOf(false) }

    fun save() = scope.launch {
        val ok = runCatching {
            val file = resolver.file(msg, userInitiated = true)
            val name = msg.fileName ?: "oshinobu_${msg.timestamp}.${if (msg.isVideo) "mp4" else "jpg"}"
            FileActions.saveToGallery(context, file, name, msg.isVideo)
        }.isSuccess
        Toast.makeText(context, context.getString(if (ok) R.string.mediaViewer_saved else R.string.mediaViewer_saveFailed), Toast.LENGTH_SHORT).show()
    }

    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) save() else Toast.makeText(context, context.getString(R.string.mediaViewer_savePermissionDenied), Toast.LENGTH_LONG).show()
    }

    Row(Modifier.fillMaxWidth().statusBarsPadding().padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, null, tint = Color.White) }
        Spacer(Modifier.weight(1f))
        Box {
            IconButton(onClick = { menuOpen = true }) { Icon(Icons.Filled.MoreVert, null, tint = Color.White) }
            DropdownMenu(menuOpen, { menuOpen = false }, shape = CardShape) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.mediaViewer_saveToGallery)) },
                    leadingIcon = { Icon(Icons.Filled.Download, null) },
                    onClick = {
                        menuOpen = false
                        val needsPermission = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
                            ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
                        if (needsPermission) permission.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE) else save()
                    },
                )
            }
        }
    }
}

/** Файл страницы: качается, готов или не удалось получить. */
private sealed interface PageFile {
    data object Loading : PageFile
    data class Ready(val file: File) : PageFile
    data object Failed : PageFile
}

@Composable
private fun MediaPage(
    msg: StoredMessage,
    resolver: MediaResolver,
    current: Boolean,
    onZoomChanged: (Boolean) -> Unit,
    onDismissDrag: (Float) -> Unit,
    onDismissEnd: () -> Unit,
) {
    val core = LocalContext.current.app.core
    val state by produceState<PageFile>(PageFile.Loading, msg.messageId) {
        value = runCatching { PageFile.Ready(resolver.file(msg, userInitiated = true)) }.getOrElse { PageFile.Failed }
    }
    val progress by core.downloads.progress.collectAsState()
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        when (val s = state) {
            PageFile.Loading -> {
                val percent = msg.mediaId?.let { progress[it] }
                if (percent != null) {
                    CircularProgressIndicator(progress = { (percent / 100).toFloat() }, color = Color.White, trackColor = Color.White.copy(alpha = 0.2f))
                } else {
                    AppLoadingIndicator(size = 32.dp, color = Color.White)
                }
            }
            PageFile.Failed -> Icon(Icons.Filled.BrokenImage, null, tint = Color.White.copy(alpha = 0.54f), modifier = Modifier.size(64.dp))
            is PageFile.Ready ->
                if (msg.isVideo) VideoPage(s.file, current, onDismissDrag, onDismissEnd)
                else ZoomablePhoto(s.file, onZoomChanged, onDismissDrag, onDismissEnd)
        }
    }
}

/**
 * Жесты страницы: два пальца (или уже увеличено) — масштаб и сдвиг;
 * один палец по вертикали — закрытие свайпом; по горизонтали — не трогаем,
 * это листание.
 */
private fun Modifier.viewerGestures(
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

@Composable
private fun ZoomablePhoto(file: File, onZoomChanged: (Boolean) -> Unit, onDismissDrag: (Float) -> Unit, onDismissEnd: () -> Unit) {
    val bitmap by produceState<Bitmap?>(null, file) { value = withContext(Dispatchers.IO) { MediaDecoding.decodeImage(file, 2560) } }
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

    val image = bitmap ?: return
    Image(
        image.asImageBitmap(), null, contentScale = ContentScale.Fit,
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
                    // как в Телеге: увеличить вокруг точки тапа или вернуть исходный размер
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

@Composable
private fun VideoPage(file: File, current: Boolean, onDismissDrag: (Float) -> Unit, onDismissEnd: () -> Unit) {
    var playing by remember { mutableStateOf(false) }
    val view = remember { arrayOfNulls<VideoView>(1) }
    LaunchedEffect(current) {
        val v = view[0] ?: return@LaunchedEffect
        if (current) { v.start(); playing = true } else { v.pause(); playing = false }
    }
    DisposableEffect(Unit) { onDispose { view[0]?.stopPlayback() } }
    Box(
        Modifier.fillMaxSize()
            .viewerGestures(zoomEnabled = false, scale = { 1f }, onTransform = { _, _ -> }, onDismissDrag = onDismissDrag, onDismissEnd = onDismissEnd)
            .pointerInput(Unit) {
                detectTapGestures(onTap = {
                    val v = view[0] ?: return@detectTapGestures
                    if (v.isPlaying) { v.pause(); playing = false } else { v.start(); playing = true }
                })
            },
        contentAlignment = Alignment.Center,
    ) {
        AndroidView(
            factory = { ctx ->
                VideoView(ctx).apply {
                    setVideoPath(file.path)
                    setOnPreparedListener { if (current) { start(); playing = true } }
                    setOnCompletionListener { playing = false }
                    view[0] = this
                }
            },
            modifier = Modifier.fillMaxWidth(),
        )
        if (!playing) {
            Box(Modifier.size(64.dp).background(Color.Black.copy(alpha = 0.45f), CircleShape), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.PlayArrow, null, tint = Color.White, modifier = Modifier.size(40.dp))
            }
        }
    }
}
