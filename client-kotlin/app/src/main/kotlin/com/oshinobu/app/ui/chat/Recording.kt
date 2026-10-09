package com.oshinobu.app.ui.chat

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.OptIn
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.ExperimentalPersistentRecording
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.oshinobu.app.R
import com.oshinobu.app.ui.theme.LocalAppColors
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

enum class RecKind { VOICE, VIDEO }
enum class RecPhase { IDLE, DRAGGING, LOCKED }

/** Короче — случайное касание, не отправляем. */
private const val MIN_RECORDING_MS = 700L

/** Видео-кружок длиннее не пишется — отправляется сам. */
private const val MAX_VIDEO_NOTE_MS = 5 * 60_000L

/**
 * Запись голосового (AAC в m4a) или видео-кружка (CameraX). Удержание
 * кнопки — запись; вверх — фиксация (можно отпустить); влево — отмена.
 */
class ChatRecorder(
    private val context: Context,
    private val scope: CoroutineScope,
    private val onRecorded: (file: File, durationMs: Long, videoNote: Boolean) -> Unit,
) {
    /** Что пишет кнопка в покое: голос или видео (тап переключает). */
    var cameraSelected by mutableStateOf(false)
    var phase by mutableStateOf(RecPhase.IDLE)
        private set
    var kind by mutableStateOf<RecKind?>(null)
        private set
    var elapsedMs by mutableLongStateOf(0L)
        private set
    var drag by mutableStateOf(Offset.Zero)
        private set
    var canFlip by mutableStateOf(false)
        private set

    val previewView: PreviewView by lazy { PreviewView(context).apply { scaleType = PreviewView.ScaleType.FILL_CENTER } }

    private var pointerDown = false
    private var startedAt = 0L
    private var ticker: Job? = null
    private var output: File? = null
    private var audio: MediaRecorder? = null
    private var camera: ProcessCameraProvider? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var recording: Recording? = null
    private var finalized: CompletableDeferred<Unit>? = null
    private var lifecycle: LifecycleOwner? = null
    private var frontLens = true

    fun onPointer(down: Boolean) {
        pointerDown = down
    }

    /** Начать запись (палец удерживает кнопку). */
    fun begin(owner: LifecycleOwner) {
        if (phase != RecPhase.IDLE) return
        val video = cameraSelected
        scope.launch {
            val ok = if (video) startVideo(owner) else startVoice()
            if (!ok) return@launch
            if (!pointerDown) {
                // отпустили раньше, чем запись успела начаться
                discard(if (video) RecKind.VIDEO else RecKind.VOICE)
                return@launch
            }
            kind = if (video) RecKind.VIDEO else RecKind.VOICE
            phase = RecPhase.DRAGGING
            drag = Offset.Zero
            startedAt = System.currentTimeMillis()
            elapsedMs = 0
            ticker = scope.launch {
                while (true) {
                    delay(200)
                    elapsedMs = System.currentTimeMillis() - startedAt
                    if (kind == RecKind.VIDEO && elapsedMs >= MAX_VIDEO_NOTE_MS) {
                        finish(send = true)
                        break
                    }
                }
            }
        }
    }

    /** Палец сдвинулся: влево за половину экрана — отмена, вверх на 70dp — фиксация. Возвращает, что произошло. */
    fun onDrag(offset: Offset, cancelThresholdPx: Float, lockThresholdPx: Float): RecPhase? {
        if (phase != RecPhase.DRAGGING) return null
        drag = offset
        if (offset.x < -cancelThresholdPx) {
            finish(send = false)
            return RecPhase.IDLE
        }
        if (offset.y < -lockThresholdPx) {
            phase = RecPhase.LOCKED
            return RecPhase.LOCKED
        }
        return null
    }

    /** Палец отпущен: без фиксации — отправить. */
    fun onRelease() {
        if (phase == RecPhase.DRAGGING) finish(send = true)
    }

    fun finish(send: Boolean) {
        if (phase == RecPhase.IDLE) return
        val k = kind ?: return
        val duration = System.currentTimeMillis() - startedAt
        ticker?.cancel()
        phase = RecPhase.IDLE
        kind = null
        elapsedMs = 0
        drag = Offset.Zero
        scope.launch {
            if (!send) {
                discard(k)
                return@launch
            }
            val file = stop(k)
            if (file == null || duration < MIN_RECORDING_MS || !file.exists() || file.length() == 0L) {
                file?.delete()
                return@launch
            }
            onRecorded(file, duration, k == RecKind.VIDEO)
        }
    }

    /** Смена камеры прямо во время записи (запись не прерывается). */
    fun flipCamera() {
        val owner = lifecycle ?: return
        val provider = camera ?: return
        val capture = videoCapture ?: return
        frontLens = !frontLens
        runCatching {
            provider.unbindAll()
            provider.bindToLifecycle(owner, selector(), preview(), capture)
        }
    }

    fun release() {
        ticker?.cancel()
        kind?.let { k -> scope.launch { discard(k) } }
        phase = RecPhase.IDLE
        kind = null
    }

    private fun selector() = if (frontLens) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA

    private fun preview() = Preview.Builder().build().also { it.surfaceProvider = previewView.surfaceProvider }

    @Suppress("DEPRECATION")
    private fun startVoice(): Boolean {
        val file = File(context.cacheDir, "voice_${System.nanoTime()}.m4a")
        val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(context) else MediaRecorder()
        return try {
            recorder.setAudioSource(MediaRecorder.AudioSource.MIC)
            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            recorder.setAudioEncodingBitRate(64_000)
            recorder.setAudioSamplingRate(44_100)
            recorder.setOutputFile(file.path)
            recorder.prepare()
            recorder.start()
            audio = recorder
            output = file
            true
        } catch (_: Exception) {
            recorder.release()
            file.delete()
            false
        }
    }

    @SuppressLint("MissingPermission")
    @OptIn(ExperimentalPersistentRecording::class)
    private suspend fun startVideo(owner: LifecycleOwner): Boolean {
        val provider = runCatching { cameraProvider() }.getOrNull() ?: return false
        val recorder = Recorder.Builder().setQualitySelector(QualitySelector.from(Quality.SD)).build()
        val capture = VideoCapture.withOutput(recorder)
        frontLens = provider.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA)
        canFlip = frontLens && provider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA)
        val file = File(context.cacheDir, "vnote_${System.nanoTime()}.mp4")
        return try {
            provider.unbindAll()
            provider.bindToLifecycle(owner, selector(), preview(), capture)
            val done = CompletableDeferred<Unit>()
            recording = capture.output.prepareRecording(context, FileOutputOptions.Builder(file).build())
                .withAudioEnabled()
                .asPersistentRecording()
                .start(ContextCompat.getMainExecutor(context)) { event ->
                    if (event is VideoRecordEvent.Finalize) done.complete(Unit)
                }
            camera = provider
            videoCapture = capture
            finalized = done
            lifecycle = owner
            output = file
            true
        } catch (_: Exception) {
            provider.unbindAll()
            file.delete()
            false
        }
    }

    private suspend fun cameraProvider(): ProcessCameraProvider = suspendCancellableCoroutine { cont ->
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            runCatching { future.get() }.fold(cont::resume, cont::resumeWithException)
        }, ContextCompat.getMainExecutor(context))
    }

    /** Остановить и вернуть файл записи. */
    private suspend fun stop(k: RecKind): File? {
        val file = output
        output = null
        when (k) {
            RecKind.VOICE -> {
                val ok = runCatching { audio?.stop() }.isSuccess
                audio?.release()
                audio = null
                if (!ok) {
                    file?.delete()
                    return null
                }
            }
            RecKind.VIDEO -> {
                recording?.stop()
                recording = null
                finalized?.await()
                finalized = null
                camera?.unbindAll()
                camera = null
                videoCapture = null
                lifecycle = null
            }
        }
        return file
    }

    private suspend fun discard(k: RecKind) {
        stop(k)?.delete()
    }
}

private fun hasPermissions(context: Context, video: Boolean): Boolean {
    fun granted(p: String) = ContextCompat.checkSelfPermission(context, p) == PackageManager.PERMISSION_GRANTED
    return granted(Manifest.permission.RECORD_AUDIO) && (!video || granted(Manifest.permission.CAMERA))
}

@Composable
fun rememberChatRecorder(onRecorded: (File, Long, Boolean) -> Unit): ChatRecorder {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val recorder = remember { ChatRecorder(context, scope, onRecorded) }
    DisposableEffect(Unit) { onDispose { recorder.release() } }
    return recorder
}

/**
 * Кнопка записи: тап — переключить голос/видео (в зафиксированной записи —
 * отправить), удержание — запись с жестами фиксации и отмены.
 */
@Composable
fun RecordButton(recorder: ChatRecorder) {
    val context = LocalContext.current
    val colors = LocalAppColors.current
    val owner = LocalLifecycleOwner.current
    val haptics = LocalHapticFeedback.current
    val density = LocalDensity.current
    val screenWidth = with(density) { LocalConfiguration.current.screenWidthDp.dp.toPx() }
    val lockPx = with(density) { 70.dp.toPx() }
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { }

    Box(
        Modifier.size(40.dp).pointerInput(recorder) {
            awaitEachGesture {
                val down = awaitFirstDown()
                recorder.onPointer(true)
                val upBeforeLongPress = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
                    while (true) {
                        val ch = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                        if (!ch.pressed) break
                    }
                }
                if (upBeforeLongPress != null) {
                    recorder.onPointer(false)
                    when (recorder.phase) {
                        RecPhase.LOCKED -> recorder.finish(send = true)
                        RecPhase.IDLE -> recorder.cameraSelected = !recorder.cameraSelected
                        RecPhase.DRAGGING -> Unit
                    }
                    return@awaitEachGesture
                }
                if (recorder.phase != RecPhase.IDLE) return@awaitEachGesture
                if (!hasPermissions(context, recorder.cameraSelected)) {
                    recorder.onPointer(false)
                    val needed = buildList {
                        add(Manifest.permission.RECORD_AUDIO)
                        if (recorder.cameraSelected) add(Manifest.permission.CAMERA)
                    }
                    permissions.launch(needed.toTypedArray())
                    return@awaitEachGesture
                }
                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                recorder.begin(owner)
                while (true) {
                    val ch = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                    ch.consume()
                    if (!ch.pressed) break
                    when (recorder.onDrag(ch.position - down.position, screenWidth * 0.5f, lockPx)) {
                        RecPhase.IDLE, RecPhase.LOCKED -> haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        else -> Unit
                    }
                }
                recorder.onPointer(false)
                recorder.onRelease()
            }
        },
        contentAlignment = Alignment.Center,
    ) {
        when (recorder.phase) {
            RecPhase.LOCKED -> Icon(Icons.AutoMirrored.Filled.Send, null, tint = colors.primary)
            RecPhase.DRAGGING -> Icon(if (recorder.kind == RecKind.VIDEO) Icons.Filled.Videocam else Icons.Filled.Mic, null, tint = Color(0xFFFF5252))
            RecPhase.IDLE -> AnimatedContent(
                recorder.cameraSelected,
                transitionSpec = { (scaleIn() + fadeIn()) togetherWith fadeOut() },
                label = "recKind",
            ) { camera -> Icon(if (camera) Icons.Filled.CameraAlt else Icons.Filled.Mic, null, tint = colors.textMuted) }
        }
    }
}

private fun formatTimer(ms: Long): String {
    val s = ms / 1000
    return "${(s / 60).toString().padStart(2, '0')}:${(s % 60).toString().padStart(2, '0')}"
}

/** Поле ввода во время записи: мигающая точка, таймер, подсказка отмены (или "отмена" при фиксации), кнопка. */
@Composable
fun RecordingRow(recorder: ChatRecorder) {
    val colors = LocalAppColors.current
    val screenWidth = with(LocalDensity.current) { LocalConfiguration.current.screenWidthDp.dp.toPx() }
    val dot by rememberInfiniteTransition(label = "recDot").animateFloat(1f, 0.2f, infiniteRepeatable(tween(600), RepeatMode.Reverse), label = "a")
    Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.padding(horizontal = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(10.dp).graphicsLayer { alpha = dot }.background(Color(0xFFFF5252), CircleShape))
            Spacer(Modifier.width(6.dp))
            Text(formatTimer(recorder.elapsedMs), color = colors.textPrimary, fontFamily = FontFamily.Monospace)
        }
        Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
            if (recorder.phase == RecPhase.LOCKED) {
                Text(
                    stringResource(R.string.chat_cancelRecording), color = Color(0xFFFF5252), fontSize = 13.sp,
                    modifier = Modifier.clickable { recorder.finish(send = false) }.padding(8.dp),
                )
            } else {
                val progress = (-recorder.drag.x / (screenWidth * 0.5f)).coerceIn(0f, 1f)
                val tint = lerp(colors.textMuted, Color(0xFFFF5252), progress)
                Row(Modifier.offset { IntOffset((-18 * progress * density).toInt(), 0) }, verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.ChevronLeft, null, tint = tint, modifier = Modifier.size(16.dp))
                    Text(stringResource(R.string.chat_swipeLeftToCancel), color = tint, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
        RecordButton(recorder)
    }
}

/** Замочек над кнопкой записи: тянется и светлеет по мере движения пальца вверх. */
@Composable
fun RecordingLockIndicator(recorder: ChatRecorder, modifier: Modifier) {
    val colors = LocalAppColors.current
    val lockPx = with(LocalDensity.current) { 70.dp.toPx() }
    val progress = (-recorder.drag.y / lockPx).coerceIn(0f, 1f)
    val tint = lerp(colors.textMuted, colors.primary, progress)
    Column(
        modifier.offset { IntOffset(0, (-10 * progress * density).toInt()) }.scale(1f + 0.18f * progress)
            .size(width = 38.dp, height = 64.dp).background(colors.surface, RoundedCornerShape(20.dp)).padding(vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.SpaceBetween,
    ) {
        Icon(Icons.Filled.KeyboardArrowUp, null, tint = tint, modifier = Modifier.size(18.dp))
        Icon(Icons.Outlined.Lock, null, tint = tint, modifier = Modifier.size(20.dp))
    }
}

/** Живое превью камеры во время записи кружка — квадрат во всю ширину над полем ввода, плюс смена камеры. */
@Composable
fun VideoNoteLivePreview(recorder: ChatRecorder, bottomPadding: Dp) {
    Box(Modifier.fillMaxSize().padding(bottom = bottomPadding)) {
        AndroidView(
            factory = { recorder.previewView },
            modifier = Modifier.align(Alignment.Center).fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(16.dp)),
        )
        if (recorder.canFlip) {
            Box(
                Modifier.align(Alignment.BottomStart).padding(12.dp).size(44.dp).clip(CircleShape)
                    .background(Color.Black.copy(alpha = 0.45f)).clickable { recorder.flipCamera() },
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Filled.Cameraswitch, null, tint = Color.White, modifier = Modifier.size(22.dp)) }
        }
    }
}
