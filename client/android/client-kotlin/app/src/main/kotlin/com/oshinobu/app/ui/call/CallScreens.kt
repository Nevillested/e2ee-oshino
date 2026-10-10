package com.oshinobu.app.ui.call

import android.Manifest
import android.content.Context
import android.content.ContextWrapper
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BluetoothAudio
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CloseFullscreen
import androidx.compose.material.icons.filled.Headset
import androidx.compose.material.icons.filled.Hearing
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.VideocamOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.call.AudioRoute
import com.oshinobu.app.ui.PeerAvatar
import com.oshinobu.app.ui.rememberPeerDisplayName
import com.oshinobu.app.ui.rememberWithPermission
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.app.ui.translate
import com.oshinobu.core.service.CallState
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoTrack

private val EndRed = Color(0xFFE53935)
private val AcceptGreen = Color(0xFF43A047)

/** Что экрану звонка нужно от Activity: картинка-в-картинке и снятие блокировки экрана. */
interface CallWindow {
    fun enterCallPip()

    /** Экран заблокирован — попросить разблокировать; true — можно уходить с экрана звонка. */
    suspend fun unlockIfLocked(): Boolean
}

private tailrec fun Context.callWindow(): CallWindow? = when (this) {
    is CallWindow -> this
    is ContextWrapper -> baseContext.callWindow()
    else -> null
}

/** Видеодорожка WebRTC в Compose (SurfaceViewRenderer на общем EGL). */
@Composable
fun VideoTrackView(track: VideoTrack, mirror: Boolean, modifier: Modifier = Modifier, onTop: Boolean = false) {
    val rtc = LocalContext.current.app.rtc
    val renderer = remember { arrayOfNulls<SurfaceViewRenderer>(1) }
    AndroidView(
        factory = { ctx ->
            SurfaceViewRenderer(ctx).apply {
                init(rtc.egl.eglBaseContext, null)
                setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FILL)
                setEnableHardwareScaler(true)
                setZOrderMediaOverlay(onTop)
                renderer[0] = this
            }
        },
        update = { it.setMirror(mirror) },
        modifier = modifier,
    )
    DisposableEffect(track) {
        val r = renderer[0]
        r?.let(track::addSink)
        onDispose { r?.let(track::removeSink) }
    }
    DisposableEffect(Unit) { onDispose { renderer[0]?.release() } }
}

private fun formatDuration(seconds: Long) = "${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')}"

/** Длительность разговора (тикает раз в секунду) или этап соединения. */
@Composable
fun rememberCallStatusText(): String {
    val context = LocalContext.current
    val calls = context.app.core.calls
    val state by calls.state.collectAsState()
    val status by calls.status.collectAsState()
    val connectedAt by calls.connectedAt.collectAsState()
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(connectedAt) {
        while (connectedAt != null) {
            now = System.currentTimeMillis()
            delay(1_000)
        }
    }
    val started = connectedAt
    return when {
        state == CallState.CONNECTED && started != null -> formatDuration(((now - started) / 1000).coerceAtLeast(0))
        status != null -> context.translate(status!!)
        else -> stringResource(R.string.call_dialing)
    }
}

@Composable
private fun RoundButton(icon: ImageVector, background: Color, tint: Color, size: Int = 56, onClick: () -> Unit) {
    Box(Modifier.size(size.dp).clip(CircleShape).background(background).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = tint)
    }
}

private fun routeIcon(route: AudioRoute) = when (route) {
    AudioRoute.BLUETOOTH -> Icons.Filled.BluetoothAudio
    AudioRoute.SPEAKER -> Icons.Filled.VolumeUp
    AudioRoute.WIRED_HEADSET -> Icons.Filled.Headset
    AudioRoute.EARPIECE -> Icons.Filled.Hearing
}

private fun routeLabel(route: AudioRoute) = when (route) {
    AudioRoute.BLUETOOTH -> R.string.call_outputBluetooth
    AudioRoute.SPEAKER -> R.string.call_outputSpeaker
    AudioRoute.WIRED_HEADSET -> R.string.call_outputWiredHeadset
    AudioRoute.EARPIECE -> R.string.call_outputEarpiece
}

/**
 * Экран разговора: видео собеседника во весь экран (или аватар, имя и
 * статус), своё видео в перетаскиваемом окошке, кнопки микрофона, камеры
 * (и её смены), звука (список выходов при Bluetooth) и завершения.
 * Звонок закончился — экран закрывается сам.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CallScreen(onClose: () -> Unit) {
    val context = LocalContext.current
    val app = context.app
    val calls = app.core.calls
    val colors = LocalAppColors.current
    val scope = rememberCoroutineScope()
    val state by calls.state.collectAsState()
    val peer by calls.peer.collectAsState()
    val mic by calls.micEnabled.collectAsState()
    val video by calls.videoEnabled.collectAsState()
    val remoteVideoOn by calls.remoteVideoEnabled.collectAsState()
    val front by calls.usingFrontCamera.collectAsState()
    val localTrack by app.rtc.localVideo.collectAsState()
    val remoteTrack by app.rtc.remoteVideo.collectAsState()
    val routes by app.calls.audio.routes.collectAsState()
    val route by app.calls.audio.route.collectAsState()
    val status = rememberCallStatusText()
    var outputPicker by remember { mutableStateOf(false) }
    val window = context.callWindow()
    val withCamera = rememberWithPermission(Manifest.permission.CAMERA)

    LaunchedEffect(state) { if (state == CallState.IDLE) onClose() }
    // видео в разговоре — экран не гаснет
    val view = LocalView.current
    DisposableEffect(video, remoteVideoOn) {
        view.keepScreenOn = state == CallState.CONNECTED && (video || remoteVideoOn)
        onDispose { view.keepScreenOn = false }
    }

    fun leave(then: () -> Unit) = scope.launch { if (window?.unlockIfLocked() != false) then() }
    BackHandler { leave(onClose) }

    val showRemote = remoteVideoOn && remoteTrack != null
    val name = peer?.let { rememberPeerDisplayName(it.accountId, it.login ?: "") } ?: ""

    BoxWithConstraints(Modifier.fillMaxSize().background(colors.background)) {
        val remote = remoteTrack
        if (showRemote && remote != null) {
            VideoTrackView(remote, mirror = false, modifier = Modifier.fillMaxSize())
            Column(
                Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(top = 12.dp)
                    .background(Color.Black.copy(alpha = 0.4f), RoundedCornerShape(16.dp)).padding(horizontal = 14.dp, vertical = 6.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(name, color = Color.White, fontSize = 14.sp)
                if (status.isNotEmpty()) Text(status, color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp)
            }
        } else {
            Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                PeerAvatar(peer?.accountId, 96.dp)
                Spacer(Modifier.height(16.dp))
                Text(name, color = colors.textPrimary, fontSize = 22.sp)
                Spacer(Modifier.height(8.dp))
                Text(status, color = colors.textMuted)
            }
        }

        if (state == CallState.CONNECTED || state == CallState.OUTGOING_RINGING) {
            SelfView(video, localTrack, front, maxWidthPx = constraints.maxWidth, maxHeightPx = constraints.maxHeight)
        }

        Box(
            Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(8.dp).size(40.dp).clip(CircleShape)
                .clickable {
                    // экран звонка закрываем: из окошка его вернёт раскрытие, из лаунчера откроется список чатов
                    leave {
                        window?.enterCallPip()
                        onClose()
                    }
                },
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Filled.CloseFullscreen, stringResource(R.string.call_minimize), tint = colors.textPrimary, modifier = Modifier.size(20.dp)) }

        Row(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding().padding(bottom = 32.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.Bottom,
        ) {
            val idle = colors.surface
            RoundButton(if (mic) Icons.Filled.Mic else Icons.Filled.MicOff, if (!mic) colors.primary else idle, if (!mic) Color.White else colors.textPrimary) {
                scope.launch { calls.toggleMic() }
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                if (video) {
                    RoundButton(Icons.Filled.Cameraswitch, if (!front) colors.primary else idle, if (!front) Color.White else colors.textPrimary) {
                        scope.launch { calls.switchCamera() }
                    }
                    Spacer(Modifier.height(8.dp))
                }
                RoundButton(Icons.Filled.VideocamOff, if (video) colors.primary else idle, if (video) Color.White else colors.textPrimary) {
                    withCamera { scope.launch { calls.toggleVideo() } }
                }
            }
            if (AudioRoute.BLUETOOTH in routes) {
                RoundButton(routeIcon(route), colors.primary, Color.White) { outputPicker = true }
            } else {
                val speaker = route == AudioRoute.SPEAKER
                RoundButton(Icons.Filled.VolumeUp, if (speaker) colors.primary else idle, if (speaker) Color.White else colors.textPrimary) {
                    app.calls.audio.toggleSpeaker()
                }
            }
            RoundButton(Icons.Filled.CallEnd, EndRed, Color.White) { scope.launch { calls.hangUp() } }
        }
    }

    if (outputPicker) {
        ModalBottomSheet(onDismissRequest = { outputPicker = false }, containerColor = colors.surface) {
            Column(Modifier.navigationBarsPadding()) {
                Text(
                    stringResource(R.string.call_outputDevices), color = colors.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 8.dp),
                )
                routes.forEach { r ->
                    val current = r == route
                    Row(
                        Modifier.fillMaxWidth().clickable {
                            outputPicker = false
                            app.calls.audio.select(r)
                        }.padding(horizontal = 20.dp, vertical = 14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(routeIcon(r), null, tint = if (current) colors.primary else colors.textPrimary)
                        Spacer(Modifier.width(16.dp))
                        Text(stringResource(routeLabel(r)), color = if (current) colors.primary else colors.textPrimary, modifier = Modifier.weight(1f))
                        if (current) Icon(Icons.Filled.Check, null, tint = colors.primary)
                    }
                }
                Spacer(Modifier.height(8.dp))
            }
        }
    }
}

/** Своё видео (или "камера выключена") в окошке, которое можно перетащить. */
@Composable
private fun SelfView(video: Boolean, track: VideoTrack?, front: Boolean, maxWidthPx: Int, maxHeightPx: Int) {
    val colors = LocalAppColors.current
    val density = LocalDensity.current
    var offset by remember { mutableStateOf(with(density) { Offset(16.dp.toPx(), 60.dp.toPx()) }) }
    val w = with(density) { 100.dp.toPx() }
    val h = with(density) { 140.dp.toPx() }
    Box(
        Modifier
            .offset { IntOffset(offset.x.coerceIn(0f, maxWidthPx - w).toInt(), offset.y.coerceIn(0f, maxHeightPx - h).toInt()) }
            .systemBarsPadding()
            .size(100.dp, 140.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(colors.surface)
            .pointerInput(Unit) { detectDragGestures { change, drag -> change.consume(); offset += drag } },
        contentAlignment = Alignment.Center,
    ) {
        if (video && track != null) {
            VideoTrackView(track, mirror = front, modifier = Modifier.fillMaxSize(), onTop = true)
        } else {
            Text(stringResource(R.string.call_cameraOff), color = colors.textMuted, fontSize = 11.sp, textAlign = TextAlign.Center, modifier = Modifier.padding(8.dp))
        }
    }
}

/** Входящий звонок: кто звонит, "отклонить" и "ответить". Звонок перестал звонить — экран уходит сам. */
@Composable
fun IncomingCallScreen(onAccepted: () -> Unit, onClose: () -> Unit) {
    val context = LocalContext.current
    val calls = context.app.core.calls
    val colors = LocalAppColors.current
    val scope = rememberCoroutineScope()
    val state by calls.state.collectAsState()
    val peer by calls.peer.collectAsState()
    var answered by remember { mutableStateOf(false) }
    val window = context.callWindow()
    val withMic = rememberWithPermission(Manifest.permission.RECORD_AUDIO)

    LaunchedEffect(state) { if (state != CallState.INCOMING_RINGING && !answered) onClose() }
    BackHandler { scope.launch { if (window?.unlockIfLocked() != false) onClose() } }

    val login = peer?.login
    Column(Modifier.fillMaxSize().background(colors.background).systemBarsPadding(), horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.weight(1f))
        PeerAvatar(peer?.accountId, 112.dp)
        Spacer(Modifier.height(20.dp))
        Text(
            if (login == null) stringResource(R.string.common_unknown) else rememberPeerDisplayName(peer?.accountId, login),
            color = colors.textPrimary, fontSize = 24.sp,
        )
        Spacer(Modifier.height(8.dp))
        Text(stringResource(R.string.call_incoming), color = colors.textMuted)
        Spacer(Modifier.weight(1f))
        Row(Modifier.fillMaxWidth().padding(horizontal = 40.dp, vertical = 32.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            RoundButton(Icons.Filled.CallEnd, EndRed, Color.White, size = 64) {
                answered = true
                scope.launch { calls.declineCall() }
                onClose()
            }
            RoundButton(Icons.Filled.Call, AcceptGreen, Color.White, size = 64) {
                withMic {
                    answered = true
                    scope.launch { calls.acceptCall() }
                    onAccepted()
                }
            }
        }
    }
}

/**
 * Полоса "вернуться к звонку" над списком чатов и в чате с тем, с кем идёт
 * разговор ([peerLogin] = null — при любом звонке).
 */
@Composable
fun OngoingCallBanner(peerLogin: String?, onOpen: () -> Unit) {
    val calls = LocalContext.current.app.core.calls
    val state by calls.state.collectAsState()
    val peer by calls.peer.collectAsState()
    val relevant = state != CallState.IDLE && (peerLogin == null || peer?.login == peerLogin)
    if (!relevant) return
    val status = rememberCallStatusText()
    Row(
        Modifier.fillMaxWidth().background(Color(0xFFCCFF90)).clickable(onClick = onOpen).padding(horizontal = 16.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Call, null, tint = Color.Black.copy(alpha = 0.87f), modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text(stringResource(R.string.call_returnToScreen), color = Color.Black.copy(alpha = 0.87f), fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.width(8.dp))
        Text(status, color = Color.Black.copy(alpha = 0.87f), fontWeight = FontWeight.SemiBold)
    }
}

/** Окошко "картинка в картинке": видео собеседника или его аватар и имя. */
@Composable
fun PipCallView() {
    val app = LocalContext.current.app
    val peer by app.core.calls.peer.collectAsState()
    val remoteVideoOn by app.core.calls.remoteVideoEnabled.collectAsState()
    val remote by app.rtc.remoteVideo.collectAsState()
    Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
        val track = remote
        if (remoteVideoOn && track != null) {
            VideoTrackView(track, mirror = false, modifier = Modifier.fillMaxSize())
        } else {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                PeerAvatar(peer?.accountId, 56.dp)
                Spacer(Modifier.height(8.dp))
                Text(peer?.login.orEmpty(), color = Color.White, fontSize = 14.sp)
            }
        }
    }
}
