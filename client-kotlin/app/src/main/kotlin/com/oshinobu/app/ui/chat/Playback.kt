package com.oshinobu.app.ui.chat

import android.graphics.SurfaceTexture
import android.media.MediaPlayer
import android.view.Surface
import android.view.TextureView
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.oshinobu.app.R
import com.oshinobu.app.media.MediaDecoding
import com.oshinobu.app.ui.theme.LocalAppColors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Одно воспроизведение на чат: голосовое или видео-кружок. Новое — останавливает
 * прежнее. Панель управления под шапкой чата видна, пока [activeId] != null.
 */
class PlaybackCoordinator(private val scope: CoroutineScope) {
    var activeId by mutableStateOf<String?>(null)
        private set
    var isPlaying by mutableStateOf(false)
        private set
    var positionMs by mutableLongStateOf(0L)
        private set
    var durationMs by mutableLongStateOf(0L)
        private set
    var failedId by mutableStateOf<String?>(null)
        private set

    private var player: MediaPlayer? = null
    private var surface: Surface? = null
    private var ticker: Job? = null

    /** Начать [id] с начала (или продолжить, если это уже активное). */
    fun play(id: String, file: File) {
        if (activeId == id && player != null) {
            resume()
            return
        }
        stop()
        failedId = null
        val p = MediaPlayer()
        try {
            p.setDataSource(file.path)
            surface?.let(p::setSurface)
            p.setOnCompletionListener { stop() }
            p.setOnErrorListener { _, _, _ ->
                failedId = id
                stop()
                true
            }
            p.prepare()
        } catch (_: Exception) {
            p.release()
            failedId = id
            return
        }
        player = p
        activeId = id
        durationMs = p.duration.toLong().coerceAtLeast(0)
        positionMs = 0
        p.start()
        isPlaying = true
        startTicker()
    }

    fun pause() {
        player?.takeIf { it.isPlaying }?.pause()
        isPlaying = false
    }

    fun resume() {
        val p = player ?: return
        p.start()
        isPlaying = true
        startTicker()
    }

    fun togglePlayPause() = if (isPlaying) pause() else resume()

    fun stop() {
        ticker?.cancel()
        player?.release()
        player = null
        activeId = null
        isPlaying = false
        positionMs = 0
    }

    /** Поверхность видео-кружка (TextureView) готова/исчезла. */
    fun attachSurface(s: Surface?) {
        surface = s
        runCatching { player?.setSurface(s) }
    }

    private fun startTicker() {
        ticker?.cancel()
        ticker = scope.launch {
            while (isActive && isPlaying) {
                positionMs = runCatching { player?.currentPosition?.toLong() }.getOrNull() ?: 0
                delay(100)
            }
        }
    }
}

private fun formatDuration(ms: Long): String {
    val s = ms / 1000
    return "${s / 60}:${(s % 60).toString().padStart(2, '0')}"
}

/** Подготовка файла для воспроизведения: процент скачивания, пока он нужен. */
private class FileLoad {
    var loading by mutableStateOf(false)
    var percent by mutableFloatStateOf(0f)
}

/**
 * Голосовое: кнопка play/pause, полоса прогресса, длительность (во время
 * отправки — этап и процент).
 */
@Composable
fun VoicePlayer(
    messageId: String,
    isMine: Boolean,
    durationMs: Long?,
    processingStep: String?,
    downloadPercent: Double?,
    coordinator: PlaybackCoordinator,
    resolveFile: suspend () -> File,
) {
    val colors = LocalAppColors.current
    val accent = if (isMine) Color.White else colors.primary
    val scope = rememberCoroutineScope()
    val load = remember { FileLoad() }
    val active = coordinator.activeId == messageId
    val playing = active && coordinator.isPlaying
    val total = if (active && coordinator.durationMs > 0) coordinator.durationMs else durationMs ?: 0
    val position = if (active) coordinator.positionMs else 0
    val progress = if (total > 0) (position.toFloat() / total).coerceIn(0f, 1f) else 0f

    fun toggle() {
        when {
            playing -> coordinator.pause()
            active -> coordinator.resume()
            else -> scope.launch {
                load.loading = true
                val file = runCatching { resolveFile() }.getOrNull()
                load.loading = false
                if (file != null) coordinator.play(messageId, file)
            }
        }
    }

    Row(Modifier.width(200.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier.size(34.dp).clip(CircleShape).background(accent.copy(alpha = 0.18f))
                .clickable(enabled = !load.loading && processingStep == null) { toggle() },
            contentAlignment = Alignment.Center,
        ) {
            if (load.loading) {
                Text("${(downloadPercent ?: 0.0).toInt()}%", color = accent, fontSize = 8.sp, fontWeight = FontWeight.Bold)
            } else {
                Icon(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, null, tint = accent, modifier = Modifier.size(20.dp))
            }
        }
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            if (processingStep != null) {
                LinearProgressIndicator(Modifier.fillMaxWidth().height(3.dp), color = accent, trackColor = accent.copy(alpha = 0.2f))
            } else {
                LinearProgressIndicator(
                    progress = { progress }, modifier = Modifier.fillMaxWidth().height(3.dp),
                    color = accent, trackColor = accent.copy(alpha = 0.2f), drawStopIndicator = {},
                )
            }
            Spacer(Modifier.height(4.dp))
            Text(
                processingStep ?: formatDuration(if (active) position else total),
                color = accent.copy(alpha = 0.85f), fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/**
 * Видео-кружок (скруглённый квадрат, без пузыря): превью-кадр, по тапу —
 * воспроизведение с увеличением до ширины чата; повторный тап — пауза.
 */
@Composable
fun VideoNotePlayer(
    messageId: String,
    durationMs: Long?,
    localPreviewPath: String?,
    expandedSize: Dp,
    statusOverlay: (@Composable () -> Unit)?,
    downloadPercent: Double?,
    coordinator: PlaybackCoordinator,
    resolveFile: suspend () -> File,
    resolveThumbnail: suspend () -> File?,
) {
    val scope = rememberCoroutineScope()
    val load = remember { FileLoad() }
    val active = coordinator.activeId == messageId
    val size by animateDpAsState(if (active) expandedSize else 200.dp, tween(220), label = "videoNoteSize")
    val thumb by produceState<android.graphics.Bitmap?>(null, localPreviewPath) {
        value = withContext(Dispatchers.IO) {
            val local = localPreviewPath?.let(::File)?.takeIf { it.exists() }
            if (local != null) MediaDecoding.decodeImage(local, 480)
            else runCatching { resolveThumbnail() }.getOrNull()?.let { MediaDecoding.videoFrame(it, 480) }
        }
    }
    val shape = RoundedCornerShape(18.dp)

    fun toggle() {
        when {
            active -> coordinator.togglePlayPause()
            else -> scope.launch {
                load.loading = true
                val file = runCatching { resolveFile() }.getOrNull()
                load.loading = false
                if (file != null) coordinator.play(messageId, file)
            }
        }
    }

    Box(
        Modifier.size(size).clip(shape).background(Color.Black)
            .clickable(enabled = !load.loading && statusOverlay == null) { toggle() },
    ) {
        thumb?.let { Image(it.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
        if (active) {
            DisposableEffect(Unit) { onDispose { coordinator.attachSurface(null) } }
            AndroidView(
                factory = { ctx ->
                    TextureView(ctx).apply {
                        surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                            override fun onSurfaceTextureAvailable(st: SurfaceTexture, w: Int, h: Int) = coordinator.attachSurface(Surface(st))
                            override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, w: Int, h: Int) = Unit
                            override fun onSurfaceTextureDestroyed(st: SurfaceTexture): Boolean {
                                coordinator.attachSurface(null)
                                return true
                            }
                            override fun onSurfaceTextureUpdated(st: SurfaceTexture) = Unit
                        }
                    }
                },
                modifier = Modifier.fillMaxSize(),
            )
        }
        when {
            statusOverlay != null -> statusOverlay()
            load.loading -> MediaStatusOverlay(stringResource(R.string.media_downloading), downloadPercent, null)
            coordinator.failedId == messageId -> MediaStatusOverlay(stringResource(R.string.media_playbackFailed), null, null)
            !(active && coordinator.isPlaying) -> Box(
                Modifier.align(Alignment.Center).size(46.dp).background(Color.Black.copy(alpha = 0.45f), CircleShape),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Filled.PlayArrow, null, tint = Color.White, modifier = Modifier.size(28.dp)) }
        }
        if (durationMs != null) {
            Text(
                formatDuration(if (active) coordinator.positionMs else durationMs),
                color = Color.White, fontSize = 11.sp,
                modifier = Modifier.align(Alignment.BottomEnd).padding(8.dp)
                    .background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(8.dp)).padding(horizontal = 6.dp, vertical = 2.dp),
            )
        }
    }
}

/** Панель под шапкой чата, пока что-то играет: play/pause и полная остановка. */
@Composable
fun MediaControlBar(coordinator: PlaybackCoordinator) {
    val colors = LocalAppColors.current
    Row(
        Modifier.padding(start = 12.dp, end = 12.dp, top = 8.dp).fillMaxWidth().height(44.dp)
            .shadow(6.dp, RoundedCornerShape(22.dp)).background(colors.surface, RoundedCornerShape(22.dp))
            .padding(horizontal = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = coordinator::togglePlayPause) {
            Icon(if (coordinator.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, null, tint = colors.primary)
        }
        Text(
            stringResource(R.string.chat_mediaBarPlaying), color = colors.textMuted, fontSize = 13.sp,
            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
        )
        IconButton(onClick = coordinator::stop) { Icon(Icons.Filled.Close, null, tint = colors.textMuted) }
    }
}
