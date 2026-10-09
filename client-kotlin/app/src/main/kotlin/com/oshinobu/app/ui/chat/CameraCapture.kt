package com.oshinobu.app.ui.chat

import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.view.CameraController
import androidx.camera.view.LifecycleCameraController
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.oshinobu.app.app
import com.oshinobu.app.media.MediaDecoding
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Съёмка фото из галереи: превью камеры, затвор, смена камеры. После снимка —
 * просмотр с подписью; крестик — переснять.
 */
@Composable
fun CameraCaptureDialog(onClose: () -> Unit, onSend: (PickedFile, caption: String) -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val store = context.app.core.pendingSends
    val controller = remember {
        LifecycleCameraController(context).apply {
            setEnabledUseCases(CameraController.IMAGE_CAPTURE)
            cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA
        }
    }
    var shot by remember { mutableStateOf<PickedFile?>(null) }
    var capturing by remember { mutableStateOf(false) }
    DisposableEffect(owner) {
        controller.bindToLifecycle(owner)
        onDispose { controller.unbind() }
    }

    fun capture() {
        if (capturing) return
        capturing = true
        val file = store.newPersistedFile("jpg")
        controller.takePicture(
            ImageCapture.OutputFileOptions.Builder(file).build(),
            ContextCompat.getMainExecutor(context),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    capturing = false
                    shot = PickedFile(file, file.name, isVideo = false)
                }

                override fun onError(exception: ImageCaptureException) {
                    capturing = false
                    file.delete()
                    context.app.core.logger.log("Camera capture failed: $exception")
                }
            },
        )
    }

    Dialog(onDismissRequest = { shot?.file?.delete(); onClose() }, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            val taken = shot
            if (taken == null) {
                AndroidView(
                    factory = { ctx -> PreviewView(ctx).apply { this.controller = controller } },
                    modifier = Modifier.fillMaxSize(),
                )
                Row(
                    Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding().padding(bottom = 24.dp),
                    horizontalArrangement = Arrangement.SpaceEvenly,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RoundIcon(Icons.Filled.Close, onClose)
                    Box(
                        Modifier.size(72.dp).clip(CircleShape).border(4.dp, Color.White, CircleShape).clickable { capture() },
                        contentAlignment = Alignment.Center,
                    ) { if (capturing) CircularProgressIndicator(color = Color.White) }
                    RoundIcon(Icons.Filled.Cameraswitch) {
                        controller.cameraSelector =
                            if (controller.cameraSelector == CameraSelector.DEFAULT_BACK_CAMERA) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
                    }
                }
            } else {
                val bitmap by produceState<android.graphics.Bitmap?>(null, taken.file) {
                    value = withContext(Dispatchers.IO) { MediaDecoding.decodeImage(taken.file, 2048) }
                }
                bitmap?.let { Image(it.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit) }
                Box(Modifier.statusBarsPadding().padding(8.dp)) {
                    RoundIcon(Icons.Filled.Close) {
                        taken.file.delete()
                        shot = null
                    }
                }
                Box(Modifier.align(Alignment.BottomCenter)) { CaptionBar(sending = false) { onSend(taken, it) } }
            }
        }
    }
}

@Composable
private fun RoundIcon(icon: ImageVector, onClick: () -> Unit) {
    Box(Modifier.size(52.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.45f)).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = Color.White)
    }
}
