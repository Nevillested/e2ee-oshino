package com.oshinobu.app.ui.chat

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Forward
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.LockReset
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.outlined.Call
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
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
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.oshinobu.app.R
import com.oshinobu.app.media.FileActions
import com.oshinobu.app.ui.PeerAvatar
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.app.ui.translate
import com.oshinobu.core.format.formatChatTime
import com.oshinobu.core.format.formatPresence
import com.oshinobu.core.storage.MessageStatus
import com.oshinobu.core.storage.StoredMessage
import kotlinx.coroutines.launch
import java.io.File

// ---------------- пузыри ----------------

/** Слот галочки выбора: плавно раздвигает место рядом с пузырём. */
@Composable
fun SelectionSlot(selectionMode: Boolean, selected: Boolean) {
    val colors = LocalAppColors.current
    AnimatedVisibility(selectionMode, enter = expandHorizontally() + fadeIn(), exit = shrinkHorizontally() + fadeOut()) {
        Icon(
            if (selected) Icons.Filled.CheckCircle else Icons.Outlined.RadioButtonUnchecked, null,
            tint = if (selected) colors.primary else colors.textMuted,
            modifier = Modifier.padding(horizontal = 8.dp).size(22.dp),
        )
    }
}

/** Пульсирующая подсветка поверх пузыря — текущее совпадение поиска. */
@Composable
fun HighlightFrame(highlighted: Boolean, content: @Composable () -> Unit) {
    Box {
        content()
        if (highlighted) {
            val a = pulsingHighlightAlpha()
            Box(Modifier.matchParentSize().padding(vertical = 4.dp).clip(BubbleShape).background(Color.White.copy(alpha = a)))
        }
    }
}

private fun aggregateStatus(group: List<StoredMessage>): String = when {
    group.any { it.status == MessageStatus.FAILED } -> MessageStatus.FAILED
    group.any { it.status == MessageStatus.SENDING || it.status == MessageStatus.QUEUED } -> MessageStatus.SENDING
    group.all { it.status == MessageStatus.READ } -> MessageStatus.READ
    else -> MessageStatus.SENT
}

/** Пузырь: одно сообщение (текст, голосовое, вложение, видео-кружок) или альбом. */
@Composable
fun MessageBubble(
    vm: ChatViewModel,
    group: List<StoredMessage>,
    peerName: String,
    maxBubble: Dp,
    maxText: Dp,
    expandedVideo: Dp,
    playback: PlaybackCoordinator,
    revealed: Set<String>,
    onReveal: (String) -> Unit,
    onJump: (String) -> Unit,
    onOpenViewer: (StoredMessage) -> Unit,
    onOpenFile: (StoredMessage) -> Unit,
    onSaveFile: (StoredMessage) -> Unit,
) {
    val colors = LocalAppColors.current
    if (group.size > 1) {
        val media = group.filter { it.isMedia }
        val caption = group.firstOrNull { !it.isMedia }
        val isMine = group.first().isMine
        val last = group.maxBy { it.timestamp }
        Column(
            Modifier.padding(vertical = 4.dp).widthIn(max = maxBubble).background(colors.bubble(isMine), BubbleShape).padding(6.dp),
            horizontalAlignment = Alignment.End,
        ) {
            Column {
                if (media.isNotEmpty()) MediaGrid(vm, media, maxBubble - 12.dp, revealed, onReveal, onOpenViewer, onOpenFile, onSaveFile)
                if (caption != null) {
                    Text(linkified(caption.text, isMine), color = colors.bubbleText(isMine), fontSize = 16.sp, modifier = Modifier.padding(start = 4.dp, end = 4.dp, top = 6.dp))
                }
            }
            Spacer(Modifier.height(4.dp))
            MetaRow(last.copy(edited = false), status = aggregateStatus(group))
        }
        return
    }

    val msg = group.single()
    if (msg.isVideoNote) {
        val upload = uploadPhase(vm, msg)
        val download = downloadPhase(vm, msg)
        Column(horizontalAlignment = if (msg.isMine) Alignment.End else Alignment.Start) {
            VideoNotePlayer(
                messageId = msg.messageId,
                durationMs = msg.durationMs,
                localPreviewPath = msg.localPreviewPath,
                expandedSize = expandedVideo,
                statusOverlay = upload?.let { { MediaStatusOverlay(it.text, it.percent, null) } },
                downloadPercent = download?.percent,
                coordinator = playback,
                resolveFile = { vm.mediaFile(msg, userInitiated = true) },
                resolveThumbnail = { vm.mediaFile(msg, userInitiated = false) },
            )
            Spacer(Modifier.height(4.dp))
            Row(Modifier.padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                if (msg.fileSize > 0) {
                    Text(fileSizeText(msg.fileSize), color = colors.textMuted, fontSize = 10.sp)
                    Spacer(Modifier.width(6.dp))
                }
                MetaRow(msg, onColoredBubble = false)
            }
        }
        return
    }

    Column(
        Modifier.padding(vertical = 4.dp).background(colors.bubble(msg.isMine), BubbleShape)
            .padding(horizontal = 14.dp, vertical = 10.dp).width(IntrinsicSize.Max),
    ) {
        if (msg.replyToPreview != null) {
            Box(Modifier.fillMaxWidth().widthIn(max = maxText)) { ReplyPreview(msg, vm.findMessage(msg.replyToMessageId), peerName, onJump) }
        }
        when {
            msg.isVoice -> Column(horizontalAlignment = Alignment.End, modifier = Modifier.fillMaxWidth()) {
                val upload = uploadPhase(vm, msg)
                VoicePlayer(
                    messageId = msg.messageId,
                    isMine = msg.isMine,
                    durationMs = msg.durationMs,
                    processingStep = upload?.let { u -> u.percent?.let { "${it.toInt()}%" } ?: u.text },
                    downloadPercent = downloadPhase(vm, msg)?.percent,
                    coordinator = playback,
                    resolveFile = { vm.mediaFile(msg, userInitiated = true) },
                )
                Spacer(Modifier.height(4.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (msg.fileSize > 0) {
                        Text(fileSizeText(msg.fileSize), color = colors.bubbleMuted(msg.isMine), fontSize = 10.sp)
                        Spacer(Modifier.width(6.dp))
                    }
                    MetaRow(msg)
                }
            }
            msg.isMedia -> Column(horizontalAlignment = Alignment.End, modifier = Modifier.fillMaxWidth()) {
                AttachmentBubble(vm, msg, 220.dp, msg.messageId in revealed, { onReveal(msg.messageId) }, onOpenViewer, onOpenFile, onSaveFile)
                Spacer(Modifier.height(4.dp))
                MetaRow(msg)
            }
            else -> Box(Modifier.fillMaxWidth()) {
                TextWithMeta(linkified(msg.text, msg.isMine), colors.bubbleText(msg.isMine), maxText) { MetaRow(msg) }
            }
        }
    }
}

// ---------------- шапка ----------------

@Composable
private fun HeaderPill(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val colors = LocalAppColors.current
    Box(modifier.shadow(4.dp, RoundedCornerShape(50)).background(colors.surface, RoundedCornerShape(50))) { content() }
}

@Composable
private fun PillIcon(icon: androidx.compose.ui.graphics.vector.ImageVector, enabled: Boolean = true, onClick: () -> Unit) {
    val colors = LocalAppColors.current
    Icon(
        icon, null,
        tint = if (enabled) colors.textPrimary else colors.textMuted.copy(alpha = 0.5f),
        modifier = Modifier.clip(CircleShape).clickable(enabled = enabled, onClick = onClick).padding(8.dp).size(22.dp),
    )
}

/**
 * Обычная шапка: назад и передачи слева; собеседник (аватар, имя, статус
 * присутствия) по центру — тап открывает профиль; звонок и меню справа.
 */
@Composable
fun ChatHeader(
    vm: ChatViewModel,
    peerName: String,
    onBack: () -> Unit,
    onOpenTransfers: () -> Unit,
    onOpenProfile: () -> Unit,
    onCall: (() -> Unit)?,
    onSearch: () -> Unit,
    onResetSession: () -> Unit,
) {
    val context = LocalContext.current
    val colors = LocalAppColors.current
    var menuOpen by remember { mutableStateOf(false) }
    Row(Modifier.statusBarsPadding().padding(start = 12.dp, end = 12.dp, top = 8.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        HeaderPill {
            Row {
                PillIcon(Icons.AutoMirrored.Filled.ArrowBack, onClick = onBack)
                PillIcon(Icons.Filled.SwapVert, onClick = onOpenTransfers)
            }
        }
        Spacer(Modifier.width(8.dp))
        Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
            HeaderPill {
                Row(
                    Modifier.clip(RoundedCornerShape(50)).clickable(enabled = !vm.peerDeleted, onClick = onOpenProfile)
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (!vm.peerDeleted) {
                        PeerAvatar(vm.peer.accountId, 32.dp)
                        Spacer(Modifier.width(8.dp))
                    }
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(peerName, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.Medium)
                        if (!vm.peerDeleted) {
                            val status = formatPresence(vm.peerTyping, vm.peerOnline, vm.peerLastSeenMs, context::translate)
                            AnimatedContent(status, transitionSpec = { (fadeIn() + slideInVertically { -it / 3 }) togetherWith fadeOut() }, label = "presence") { s ->
                                if (s.isNotEmpty()) {
                                    Text(s, fontSize = 12.sp, color = if (vm.peerTyping) colors.primary else colors.textPrimary.copy(alpha = 0.7f), maxLines = 1)
                                }
                            }
                        }
                    }
                }
            }
        }
        Spacer(Modifier.width(8.dp))
        HeaderPill {
            Row {
                PillIcon(Icons.Outlined.Call, enabled = onCall != null) { onCall?.invoke() }
                Box {
                    PillIcon(Icons.Filled.MoreVert) { menuOpen = true }
                    DropdownMenu(menuOpen, { menuOpen = false }) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.chat_searchAction), color = colors.textPrimary) },
                            leadingIcon = { Icon(Icons.Filled.Search, null, tint = colors.textMuted) },
                            onClick = { menuOpen = false; onSearch() },
                        )
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.chat_resetSessionAction), color = colors.textPrimary) },
                            leadingIcon = { Icon(Icons.Filled.LockReset, null, tint = colors.textMuted) },
                            onClick = { menuOpen = false; onResetSession() },
                        )
                    }
                }
            }
        }
    }
}

/** Шапка режима выбора: счётчик, копировать, переслать, удалить. */
@Composable
fun SelectionHeader(count: Int, onClose: () -> Unit, onCopy: () -> Unit, onForward: () -> Unit, onDelete: () -> Unit) {
    val colors = LocalAppColors.current
    Row(
        Modifier.fillMaxWidth().background(colors.surface).statusBarsPadding().height(56.dp).padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onClose) { Icon(Icons.Filled.Close, null, tint = colors.textPrimary) }
        Text("${stringResource(R.string.chat_selectedCount)}: $count", color = colors.textPrimary, fontSize = 18.sp, modifier = Modifier.weight(1f))
        IconButton(onClick = onCopy, enabled = count > 0) { Icon(Icons.Outlined.ContentCopy, null, tint = colors.textPrimary) }
        IconButton(onClick = onForward, enabled = count > 0) { Icon(Icons.AutoMirrored.Outlined.Forward, null, tint = colors.textPrimary) }
        IconButton(onClick = onDelete, enabled = count > 0) { Icon(Icons.Outlined.Delete, null, tint = colors.textPrimary) }
    }
}

/** Шапка поиска: "назад" и поле запроса в таблетках. */
@Composable
fun SearchHeader(query: String, onQuery: (String) -> Unit, onClose: () -> Unit) {
    val colors = LocalAppColors.current
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    Row(Modifier.statusBarsPadding().padding(start = 12.dp, end = 12.dp, top = 8.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        HeaderPill { PillIcon(Icons.AutoMirrored.Filled.ArrowBack, onClick = onClose) }
        Spacer(Modifier.width(10.dp))
        HeaderPill(Modifier.weight(1f)) {
            Box(Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
                if (query.isEmpty()) Text(stringResource(R.string.chat_searchHint), color = colors.textMuted, fontSize = 15.sp)
                BasicTextField(
                    query, onQuery, singleLine = true,
                    textStyle = TextStyle(color = colors.textPrimary, fontSize = 15.sp),
                    cursorBrush = SolidColor(colors.primary),
                    modifier = Modifier.fillMaxWidth().focusRequester(focus),
                )
            }
        }
    }
}

/** Баннер закреплённого сообщения — тап переносит к нему. */
@Composable
fun PinnedBanner(text: String, onClick: () -> Unit) {
    val colors = LocalAppColors.current
    Row(
        Modifier.fillMaxWidth().background(colors.surface).clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.PushPin, null, tint = colors.primary, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(8.dp))
        Text(text, color = colors.textPrimary, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

// ---------------- поиск ----------------

/** Панель поиска вместо поля ввода: N/M, переход по совпадениям, "списком"/"в чате". */
@Composable
fun SearchControls(current: Int, total: Int, asList: Boolean, onOlder: () -> Unit, onNewer: () -> Unit, onToggleList: () -> Unit) {
    val colors = LocalAppColors.current
    Box(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp).height(52.dp)) {
        Text("$current/$total", color = colors.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.Bold, modifier = Modifier.align(Alignment.CenterStart))
        if (!asList) {
            Row(Modifier.align(Alignment.Center), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                SearchNavButton(Icons.Filled.KeyboardArrowDown, total > 0, onNewer)
                SearchNavButton(Icons.Filled.KeyboardArrowUp, total > 0, onOlder)
            }
        }
        Text(
            stringResource(if (asList) R.string.chat_showAsChat else R.string.chat_showAsList),
            color = colors.primary, fontSize = 15.sp, fontWeight = FontWeight.Bold,
            modifier = Modifier.align(Alignment.CenterEnd).clip(RoundedCornerShape(20.dp)).background(colors.surface)
                .clickable(onClick = onToggleList).padding(horizontal = 18.dp, vertical = 13.dp),
        )
    }
}

@Composable
private fun SearchNavButton(icon: androidx.compose.ui.graphics.vector.ImageVector, enabled: Boolean, onClick: () -> Unit) {
    val colors = LocalAppColors.current
    Icon(
        icon, null, tint = if (enabled) colors.textPrimary else colors.textMuted,
        modifier = Modifier.clip(CircleShape).background(colors.surface).clickable(enabled = enabled, onClick = onClick).padding(10.dp).size(30.dp),
    )
}

/** Совпадения поиска списком (новые сверху); тап — к сообщению в чате. */
@Composable
fun SearchResultsList(matches: List<StoredMessage>, topPadding: Dp, bottomPadding: Dp, onPick: (StoredMessage) -> Unit) {
    val colors = LocalAppColors.current
    if (matches.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text(stringResource(R.string.chat_searchNoResults), color = colors.textMuted) }
        return
    }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = topPadding + 8.dp, bottom = bottomPadding + 8.dp)) {
        items(matches, key = { it.messageId }) { m ->
            Column(Modifier.fillMaxWidth().clickable { onPick(m) }.padding(horizontal = 16.dp, vertical = 10.dp)) {
                Text(m.text, color = colors.textPrimary, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(formatChatTime(m.timestamp), color = colors.textMuted, fontSize = 12.sp)
            }
        }
    }
}

// ---------------- файлы ----------------

/**
 * "Сохранить на устройство": копия в "Загрузки". До Android 10 для этого
 * нужно разрешение на запись — спрашиваем при первом сохранении.
 */
@Composable
fun rememberSaveToDownloads(resolve: suspend (StoredMessage) -> File): (StoredMessage) -> Unit {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var pending by remember { mutableStateOf<StoredMessage?>(null) }

    fun save(msg: StoredMessage) = scope.launch {
        val result = runCatching { FileActions.saveToDownloads(context, resolve(msg), msg.fileName ?: msg.text.ifBlank { "file" }) }
        val text = result.fold(
            onSuccess = { "${context.getString(R.string.chat_savedToDevice)}: $it" },
            onFailure = { context.getString(R.string.chat_saveToDeviceFailed) },
        )
        Toast.makeText(context, text, Toast.LENGTH_LONG).show()
    }

    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val msg = pending
        pending = null
        if (msg != null) {
            if (granted) save(msg) else Toast.makeText(context, context.getString(R.string.chat_saveToDeviceFailed), Toast.LENGTH_SHORT).show()
        }
    }
    return { msg ->
        val needsPermission = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
        if (needsPermission) {
            pending = msg
            permission.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        } else {
            save(msg)
        }
    }
}
