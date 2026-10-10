package com.oshinobu.app.ui.chat

import android.content.Context
import android.net.Uri
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.content.MediaType
import androidx.compose.foundation.content.consume
import androidx.compose.foundation.content.contentReceiver
import androidx.compose.foundation.content.hasMediaType
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Forward
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.outlined.EmojiEmotions
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.ui.emoji.EmojiPicker
import com.oshinobu.app.ui.theme.LocalAppColors
import kotlinx.coroutines.launch

/** Баннер над полем ввода: правка, ответ или пересылка — с крестиком отмены. */
@Composable
fun ComposerBanner(vm: ChatViewModel, context: Context) {
    val edit = vm.editing
    val reply = vm.replyTo
    val forward = vm.forwarding
    val banner: Triple<ImageVector, String, () -> Unit>? = when {
        edit != null -> Triple(Icons.Filled.Edit, stringResource(R.string.chat_editingMessage), vm::cancelEdit)
        reply != null -> Triple(Icons.AutoMirrored.Filled.Reply, "${stringResource(R.string.action_reply)}: ${previewOf(context, reply)}", vm::cancelReply)
        !forward.isNullOrEmpty() -> Triple(Icons.AutoMirrored.Filled.Forward, "${stringResource(R.string.chat_forwardingCount)}: ${forward.size}", vm::cancelForward)
        else -> null
    }
    Box(Modifier.animateContentSize(tween(180))) {
        if (banner != null) {
            val colors = LocalAppColors.current
            Row(
                Modifier.padding(start = 10.dp, end = 10.dp, top = 4.dp).fillMaxWidth().background(colors.surface, RoundedCornerShape(12.dp))
                    .padding(horizontal = 12.dp, vertical = 4.dp).height(26.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(banner.first, null, tint = colors.primary, modifier = Modifier.size(15.dp))
                Spacer(Modifier.width(8.dp))
                Text(banner.second, color = colors.textPrimary, fontSize = 12.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                Icon(Icons.Filled.Close, null, tint = colors.textMuted, modifier = Modifier.size(16.dp).clickable(onClick = banner.third))
            }
        }
    }
}

/**
 * Поле ввода в "таблетке": эмодзи/клавиатура, растущий до 5 строк текст,
 * справа — "отправить" (есть текст, правка или пересылка) либо скрепка и
 * запись. Во время записи — строка записи; при блокировке — пояснение.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun Composer(
    vm: ChatViewModel,
    recorder: ChatRecorder,
    blockedText: String?,
    emojiMode: Boolean,
    focusRequester: FocusRequester,
    onToggleEmoji: () -> Unit,
    /** Тап по полю ввода (уходим с панели эмодзи на клавиатуру). */
    onTextTapped: () -> Unit,
    onSendMedia: (List<PickedFile>, String, Boolean) -> Unit,
    onSendFiles: (List<PickedFile>) -> Unit,
) {
    val colors = LocalAppColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    Box(
        Modifier.padding(horizontal = 6.dp, vertical = 4.dp).fillMaxWidth().background(colors.surface, RoundedCornerShape(24.dp))
            .padding(start = 2.dp, end = 8.dp).heightIn(min = 52.dp).animateContentSize(tween(140)),
        contentAlignment = Alignment.CenterStart,
    ) {
        AnimatedContent(
            blockedText,
            transitionSpec = { fadeIn(tween(160)) togetherWith fadeOut(tween(160)) },
            label = "composer",
        ) { blocked ->
            if (blocked != null) {
                Text(
                    blocked, color = colors.textMuted, fontSize = 12.5.sp, textAlign = TextAlign.Center, maxLines = 2,
                    overflow = TextOverflow.Ellipsis, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                )
                return@AnimatedContent
            }
            // Строка записи ложится поверх поля ввода, а не вместо него: поле
            // (и его фокус) остаётся на месте, клавиатура не закрывается.
            val recording = recorder.phase != RecPhase.IDLE
            Box {
                Row(Modifier.graphicsLayer { alpha = if (recording) 0f else 1f }, verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = onToggleEmoji, modifier = Modifier.size(40.dp)) {
                        AnimatedContent(emojiMode, label = "emojiIcon") { e ->
                            Icon(if (e) Icons.Filled.Keyboard else Icons.Outlined.EmojiEmotions, null, tint = colors.textMuted)
                        }
                    }
                    Spacer(Modifier.width(2.dp))
                    Box(Modifier.weight(1f).padding(vertical = 14.dp)) {
                        if (vm.input.text.isEmpty()) Text(stringResource(R.string.chat_messageHint), color = colors.textMuted, fontSize = 16.sp)
                        BasicTextField(
                            state = vm.input,
                            textStyle = TextStyle(color = colors.textPrimary, fontSize = 16.sp),
                            cursorBrush = SolidColor(colors.primary),
                            lineLimits = TextFieldLineLimits.MultiLine(maxHeightInLines = 5),
                            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                            modifier = Modifier.fillMaxWidth().focusRequester(focusRequester)
                                .onFocusChanged { if (it.isFocused) onTextTapped() }
                                .contentReceiver { content ->
                                    // картинка/GIF из клавиатуры — сразу отдельным сообщением
                                    if (!content.hasMediaType(MediaType.Image)) return@contentReceiver content
                                    val uris = ArrayList<Uri>()
                                    val rest = content.consume { item -> item.uri?.also { uris += it } != null }
                                    if (uris.isNotEmpty()) scope.launch {
                                        val store = context.app.core.pendingSends
                                        val picked = uris.mapNotNull { MediaImport.import(context, it, store) }
                                        if (picked.isNotEmpty()) onSendMedia(picked, "", false)
                                    }
                                    rest
                                },
                        )
                    }
                    Spacer(Modifier.width(2.dp))
                    val hasText = vm.input.text.isNotBlank()
                    when {
                        vm.editing != null -> IconButton(onClick = vm::send, enabled = hasText, modifier = Modifier.size(40.dp)) {
                            Icon(Icons.AutoMirrored.Filled.Send, null, tint = colors.primary)
                        }
                        hasText || !vm.forwarding.isNullOrEmpty() -> IconButton(onClick = vm::send, modifier = Modifier.size(40.dp)) {
                            Icon(Icons.AutoMirrored.Filled.Send, null, tint = colors.primary)
                        }
                        else -> {
                            AttachButton(onSendMedia, onSendFiles)
                            RecordButton(recorder)
                        }
                    }
                }
                if (recording) {
                    // перехватывает касания, чтобы они не доходили до скрытого поля под ней
                    Box(Modifier.matchParentSize().pointerInput(Unit) { awaitEachGesture { awaitFirstDown() } }) { RecordingRow(recorder) }
                }
            }
        }
    }
}

/** Панель эмодзи на месте клавиатуры (той же высоты). */
@Composable
fun EmojiPanel(height: Dp, onEmoji: (String) -> Unit) {
    val colors = LocalAppColors.current
    Box(Modifier.fillMaxWidth().height(height).background(colors.surface)) { EmojiPicker(onEmoji) }
}
