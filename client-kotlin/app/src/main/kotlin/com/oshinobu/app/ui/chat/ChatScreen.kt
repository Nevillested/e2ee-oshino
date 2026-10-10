package com.oshinobu.app.ui.chat

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.AwaitPointerEventScope
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.media.AndroidVideoThumbnailer
import com.oshinobu.app.media.FileActions
import com.oshinobu.app.ui.call.OngoingCallBanner
import com.oshinobu.app.ui.home.ChatTarget
import com.oshinobu.app.ui.rememberPeerDisplayName
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.storage.MessageStatus
import com.oshinobu.core.storage.StoredMessage
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.abs

/** Подписи вложений для панели передач — в языке интерфейса на момент открытия чата. */
data class MediaLabels(val photo: String, val video: String, val file: String, val voice: String, val videoNote: String) {
    fun of(m: StoredMessage) = m.fileName ?: when {
        m.isVoice -> voice
        m.isVideoNote -> videoNote
        m.isVideo -> video
        m.isFile -> file
        else -> photo
    }
}

@Composable
fun rememberMediaLabels(): MediaLabels {
    val context = LocalContext.current
    return remember {
        MediaLabels(
            context.getString(R.string.media_photo), context.getString(R.string.media_video), context.getString(R.string.media_file),
            context.getString(R.string.media_voiceNote), context.getString(R.string.media_videoNote),
        )
    }
}

/** Подряд идущие сообщения одной отправки (общий groupId) — один альбом. */
private fun groupMessages(messages: List<StoredMessage>): List<List<StoredMessage>> {
    val result = ArrayList<List<StoredMessage>>()
    var i = 0
    while (i < messages.size) {
        val gid = messages[i].groupId
        if (gid == null) {
            result += listOf(messages[i++])
            continue
        }
        val cluster = ArrayList<StoredMessage>()
        while (i < messages.size && messages[i].groupId == gid) cluster += messages[i++]
        result += cluster
    }
    return result
}

/** Представитель альбома: подпись, если есть, иначе первое вложение. */
private fun List<StoredMessage>.rep(): StoredMessage = firstOrNull { !it.isMedia } ?: first()

private fun List<StoredMessage>.key(): String = first().groupId ?: first().messageId

/** Краткое описание сообщения для баннеров (ответ, закреп). */
fun previewOf(context: Context, m: StoredMessage): String = when {
    m.isVoice -> "🎤 ${context.getString(R.string.media_voiceNote)}"
    m.isVideoNote -> "🎥 ${context.getString(R.string.media_videoNote)}"
    m.isMedia && m.isFile -> "📎 ${context.getString(R.string.media_file)}"
    m.isMedia -> "📷 ${context.getString(R.string.media_photo)}"
    else -> m.text
}

private fun Context.copyToClipboard(text: String) {
    (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("message", text))
}

/**
 * Экран переписки. Лента — снизу вверх (новые внизу), шапка и поле ввода —
 * плавающие "таблетки" поверх неё. Жесты на сообщении: тап — меню (после
 * паузы на двойной тап), двойной тап — реакция по умолчанию, долгий тап —
 * выбор (с протяжкой по соседним), свайп влево — ответ, вправо — назад.
 */
@OptIn(FlowPreview::class)
@Composable
fun ChatScreen(
    target: ChatTarget,
    forwardedTexts: List<String>,
    onBack: () -> Unit,
    onOpenTransfers: () -> Unit,
    onOpenProfile: (accountId: String, login: String) -> Unit,
    onForward: (List<String>) -> Unit,
    onOpenMedia: (peerLogin: String, messageId: String) -> Unit,
    onStartCall: (ChatTarget) -> Unit,
    onOpenCall: () -> Unit,
) {
    val context = LocalContext.current
    val app = context.app
    val colors = LocalAppColors.current
    val density = LocalDensity.current
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    val labels = rememberMediaLabels()
    val vm: ChatViewModel = viewModel(key = "chat:${target.login}") {
        ChatViewModel(app.core, app.routerHost, target.login, target.accountId, target.deviceId, forwardedTexts, labels)
    }
    val thumbnailer = remember { AndroidVideoThumbnailer(app.core.dirs.support) }
    val playback = remember { PlaybackCoordinator(scope) }
    DisposableEffect(Unit) { onDispose { playback.stop() } }
    val recorder = rememberChatRecorder { file, durationMs, videoNote -> vm.sendRecorded(file, durationMs, videoNote, thumbnailer) }

    val peerName = if (vm.peerDeleted) stringResource(R.string.home_deletedAccount) else rememberPeerDisplayName(vm.peer.accountId, vm.peer.login)
    val composerBlocked = vm.blockedByMe || vm.blockingMe

    var menu by remember { mutableStateOf<MenuTarget?>(null) }
    var deleteIds by remember { mutableStateOf<List<String>?>(null) }
    var reportTarget by remember { mutableStateOf<StoredMessage?>(null) }
    var confirmReset by remember { mutableStateOf(false) }
    var searchAsList by remember { mutableStateOf(false) }
    var searchIndex by remember { mutableIntStateOf(0) }
    var revealedSpoilers by remember { mutableStateOf(setOf<String>()) }
    var flashId by remember { mutableStateOf<String?>(null) }
    var flashToken by remember { mutableIntStateOf(0) }
    var swipeReplyId by remember { mutableStateOf<String?>(null) }
    var swipeReplyDx by remember { mutableStateOf(0f) }
    var composerHeightPx by remember { mutableIntStateOf(0) }
    var headerHeightPx by remember { mutableIntStateOf(0) }
    val rootCoords = remember { arrayOfNulls<LayoutCoordinates>(1) }
    val rowBounds = remember { HashMap<String, Rect>() }
    val listState = rememberLazyListState()
    val groups = remember(vm.messages) { groupMessages(vm.messages).asReversed() }
    val latestGroups by rememberUpdatedState(groups)
    val emojiKeyboard = rememberEmojiKeyboardState()
    val inputFocus = emojiKeyboard.focusRequester

    LaunchedEffect(Unit) {
        vm.notices.collect { n ->
            val text = when (n) {
                ChatNotice.Copied -> context.getString(R.string.common_copied)
                ChatNotice.RetryFailedPermanently -> context.getString(R.string.chat_retryFailedPermanently)
                ChatNotice.SessionResetDone -> context.getString(R.string.chat_resetSessionDone)
                is ChatNotice.FilesTooLarge -> context.getString(R.string.chat_fileTooLarge)
            }
            Toast.makeText(context, text, Toast.LENGTH_SHORT).show()
        }
    }

    // ---- позиция ленты: восстановить при открытии, сохранить при уходе ----
    var positioned by remember { mutableStateOf(false) }
    LaunchedEffect(vm.loaded) {
        if (!vm.loaded || positioned) return@LaunchedEffect
        app.core.settings.chatScrollAnchor(target.login)?.let { (id, offset) ->
            val index = groups.indexOfFirst { g -> g.any { it.messageId == id } }
            if (index >= 0) listState.scrollToItem(index, offset)
        }
        positioned = true
    }
    DisposableEffect(Unit) {
        onDispose {
            val atBottom = listState.firstVisibleItemIndex == 0 && listState.firstVisibleItemScrollOffset < 40
            val anchor = latestGroups.getOrNull(listState.firstVisibleItemIndex)?.first()?.messageId
            app.core.settings.setChatScrollAnchor(target.login, if (atBottom || anchor == null) null else anchor to listState.firstVisibleItemScrollOffset)
        }
    }
    // новое сообщение: своё — всегда вниз; чужое — если и так были внизу
    val newestId = groups.firstOrNull()?.key()
    var lastNewestId by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(newestId) {
        val previous = lastNewestId
        lastNewestId = newestId
        if (previous == null || newestId == null || !positioned) return@LaunchedEffect
        val nearBottom = listState.firstVisibleItemIndex <= 1
        if (groups.first().first().isMine || nearBottom) listState.animateScrollToItem(0)
    }
    // видимые вложения: мелкие докачиваются сами
    LaunchedEffect(Unit) {
        snapshotFlow { listState.layoutInfo.visibleItemsInfo.map { it.key } }.debounce(300).collect { keys ->
            vm.onMediaVisible(latestGroups.filter { it.key() in keys }.flatten())
        }
    }

    fun jumpTo(messageId: String) {
        val index = groups.indexOfFirst { g -> g.any { it.messageId == messageId } }
        if (index < 0) return
        scope.launch {
            listState.animateScrollToItem(index, -with(density) { 160.dp.roundToPx() })
            flashId = groups[index].key()
            flashToken++
        }
    }

    val searchMatches = if (vm.searchQuery != null) vm.searchMatches() else emptyList()
    val currentMatch = searchMatches.getOrNull(searchIndex)
    LaunchedEffect(currentMatch?.messageId, searchAsList) {
        if (currentMatch != null && !searchAsList) {
            val index = groups.indexOfFirst { g -> g.any { it.messageId == currentMatch.messageId } }
            if (index >= 0) listState.animateScrollToItem(index, -with(density) { 160.dp.roundToPx() })
        }
    }

    fun handleBack() {
        when {
            menu != null -> menu = null
            vm.selectionMode -> vm.clearSelection()
            vm.searchQuery != null -> vm.closeSearch()
            emojiKeyboard.emojiMode -> emojiKeyboard.closeEmoji()
            else -> onBack()
        }
    }
    BackHandler(enabled = vm.selectionMode || vm.searchQuery != null || emojiKeyboard.emojiMode, onBack = ::handleBack)

    fun openMenu(group: List<StoredMessage>, anchor: Offset) {
        val rep = group.rep()
        val ids = group.map { it.messageId }
        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
        menu = MenuTarget(rep, ids, anchor, vm.groupStatus(ids))
    }

    fun onMenuAction(t: MenuTarget, action: MessageAction) {
        menu = null
        val msg = t.msg
        when (action) {
            MessageAction.REPLY -> vm.startReply(msg)
            MessageAction.COPY -> {
                context.copyToClipboard(msg.text)
                vm.notifyCopied()
            }
            MessageAction.PIN -> vm.setPinned(msg, true)
            MessageAction.UNPIN -> vm.setPinned(msg, false)
            MessageAction.FORWARD -> onForward(listOf(msg.text))
            MessageAction.EDIT -> {
                vm.startEdit(msg)
                inputFocus.requestFocus()
            }
            MessageAction.SELECT -> vm.toggleSelected(t.groupIds)
            MessageAction.DELETE -> deleteIds = t.groupIds
            MessageAction.REPORT -> reportTarget = msg
            MessageAction.CANCEL_SEND -> vm.cancelSend(t.groupIds)
            MessageAction.RETRY_SEND -> vm.retrySend(msg.groupId ?: msg.messageId)
        }
    }

    fun openFile(msg: StoredMessage) = scope.launch {
        val error = runCatching {
            val file = vm.mediaFile(msg, userInitiated = true)
            if (!FileActions.open(context, file, msg.fileName ?: "file")) error("no app")
        }.exceptionOrNull()
        if (error != null) Toast.makeText(context, context.getString(R.string.chat_openFileFailed), Toast.LENGTH_SHORT).show()
    }

    val saveFile = rememberSaveToDownloads { msg -> vm.mediaFile(msg, userInitiated = true) }

    Box(
        Modifier.fillMaxSize().background(colors.background)
            .onGloballyPositioned { rootCoords[0] = it },
    ) {
        // ---------------- лента ----------------
        if (vm.searchQuery != null && searchAsList) {
            SearchResultsList(
                matches = searchMatches,
                topPadding = with(density) { headerHeightPx.toDp() },
                bottomPadding = with(density) { composerHeightPx.toDp() },
            ) { m ->
                searchAsList = false
                searchIndex = searchMatches.indexOf(m).coerceAtLeast(0)
            }
        } else {
            BoxWithConstraints(Modifier.fillMaxSize()) {
                val maxBubble = maxWidth * 0.72f
                val maxText = maxWidth * 0.65f
                LazyColumn(
                    state = listState,
                    reverseLayout = true,
                    // пока не восстановили позицию — не показываем, иначе виден прыжок
                    modifier = Modifier.fillMaxSize().graphicsLayer { alpha = if (positioned) 1f else 0f },
                    contentPadding = PaddingValues(
                        start = 16.dp, end = 16.dp,
                        top = with(density) { headerHeightPx.toDp() } + 8.dp,
                        bottom = with(density) { composerHeightPx.toDp() } + 12.dp,
                    ),
                ) {
                    items(groups, key = { it.key() }) { group ->
                        val rep = group.rep()
                        when {
                            rep.isCallLog -> CallLogRow(rep)
                            rep.isUndecryptable -> UndecryptableRow(rep, peerName)
                            else -> MessageRow(
                                group = group,
                                selectionMode = vm.selectionMode,
                                selected = rep.messageId in vm.selected,
                                dissolving = group.any { it.messageId in vm.dissolving },
                                justReacted = rep.messageId in vm.justReacted,
                                flash = if (flashId == group.key()) flashToken else 0,
                                highlighted = currentMatch != null && group.any { it.messageId == currentMatch.messageId },
                                swipeDx = if (swipeReplyId == rep.messageId) swipeReplyDx else 0f,
                                rootCoords = { rootCoords[0] },
                                onBounds = { rowBounds[group.key()] = it },
                                gestures = RowGestures(
                                    swipeReplyEnabled = !vm.selectionMode && !composerBlocked,
                                    onTap = { anchor ->
                                        if (vm.selectionMode) vm.toggleSelected(group.map { it.messageId }) else openMenu(group, anchor)
                                    },
                                    onDoubleTap = { if (!vm.selectionMode) vm.applyDefaultReaction(rep) },
                                    onLongPress = { vm.toggleSelected(group.map { it.messageId }) },
                                    onDragSelect = { pos ->
                                        // только строки, которые сейчас на экране: у ушедших за край границы устарели
                                        val visible = listState.layoutInfo.visibleItemsInfo.map { it.key }.toSet()
                                        val hit = rowBounds.entries.firstOrNull { it.key in visible && pos.y >= it.value.top && pos.y < it.value.bottom }?.key
                                        hit?.let { key -> latestGroups.firstOrNull { it.key() == key }?.map { it.messageId } }
                                    },
                                    toggleIds = vm::toggleSelected,
                                    onSwipeReply = { dx ->
                                        swipeReplyId = rep.messageId
                                        swipeReplyDx = dx
                                    },
                                    onSwipeReplyFire = {
                                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                        vm.startReply(rep)
                                        inputFocus.requestFocus()
                                    },
                                    onSwipeEnd = { swipeReplyId = null; swipeReplyDx = 0f },
                                ),
                            ) {
                                MessageBubble(
                                    vm = vm,
                                    group = group,
                                    peerName = peerName,
                                    maxBubble = maxBubble,
                                    maxText = maxText,
                                    expandedVideo = maxWidth - 32.dp,
                                    playback = playback,
                                    revealed = revealedSpoilers,
                                    onReveal = { revealedSpoilers = revealedSpoilers + it },
                                    onJump = ::jumpTo,
                                    onOpenViewer = { m -> onOpenMedia(target.login, m.messageId) },
                                    onOpenFile = { openFile(it) },
                                    onSaveFile = saveFile,
                                )
                            }
                        }
                    }
                }
            }
        }

        // ---------------- шапка ----------------
        Column(Modifier.fillMaxWidth().align(Alignment.TopCenter).onSizeChanged { headerHeightPx = it.height }) {
            AnimatedContent(
                targetState = when {
                    vm.selectionMode -> 1
                    vm.searchQuery != null -> 2
                    else -> 0
                },
                transitionSpec = { fadeIn(tween(280)) togetherWith fadeOut(tween(280)) },
                label = "header",
            ) { mode ->
                when (mode) {
                    1 -> SelectionHeader(
                        count = vm.selected.size,
                        onClose = vm::clearSelection,
                        onCopy = {
                            val texts = vm.selectedTexts()
                            if (texts.isNotEmpty()) {
                                context.copyToClipboard(texts.joinToString("\n"))
                                vm.clearSelection()
                                vm.notifyCopied()
                            }
                        },
                        onForward = { vm.selectedTexts().takeIf { it.isNotEmpty() }?.let(onForward) },
                        onDelete = { deleteIds = vm.selected.toList() },
                    )
                    2 -> SearchHeader(vm.searchQuery.orEmpty(), onQuery = { vm.setSearch(it); searchIndex = 0 }, onClose = vm::closeSearch)
                    else -> ChatHeader(
                        vm = vm,
                        peerName = peerName,
                        onBack = onBack,
                        onOpenTransfers = onOpenTransfers,
                        onOpenProfile = { onOpenProfile(vm.peer.accountId, vm.peer.login) },
                        onCall = if (vm.peerDeleted || composerBlocked) null else {
                            { onStartCall(ChatTarget(vm.peer.login, vm.peer.accountId, vm.peer.deviceId)) }
                        },
                        onSearch = vm::openSearch,
                        onResetSession = { confirmReset = true },
                    )
                }
            }
            OngoingCallBanner(peerLogin = target.login, onOpen = onOpenCall)
            AnimatedVisibility(playback.activeId != null, enter = expandVertically() + fadeIn(), exit = shrinkVertically() + fadeOut()) {
                MediaControlBar(playback)
            }
            AnimatedVisibility(vm.pinnedId != null, enter = expandVertically() + fadeIn(), exit = shrinkVertically() + fadeOut()) {
                val pinned = vm.findMessage(vm.pinnedId)
                PinnedBanner(
                    text = pinned?.let { previewOf(context, it) } ?: stringResource(R.string.chat_pinnedMessage),
                    onClick = { vm.pinnedId?.let(::jumpTo) },
                )
            }
        }

        // ---------------- поле ввода ----------------
        Column(Modifier.fillMaxWidth().align(Alignment.BottomCenter).onSizeChanged { composerHeightPx = it.height }) {
            if (vm.searchQuery != null) {
                SearchControls(
                    current = if (searchMatches.isEmpty()) 0 else searchIndex + 1,
                    total = searchMatches.size,
                    asList = searchAsList,
                    onOlder = { if (searchIndex < searchMatches.size - 1) searchIndex++ },
                    onNewer = { if (searchIndex > 0) searchIndex-- },
                    onToggleList = { searchAsList = !searchAsList },
                )
            } else {
                if (!composerBlocked) ComposerBanner(vm, context)
                Composer(
                    vm = vm,
                    recorder = recorder,
                    blockedText = when {
                        vm.blockedByMe && vm.blockingMe -> stringResource(R.string.chat_blockedMutual)
                        vm.blockedByMe -> stringResource(R.string.chat_blockedByMe)
                        vm.blockingMe -> stringResource(R.string.chat_blockingMe)
                        else -> null
                    },
                    emojiMode = emojiKeyboard.emojiMode,
                    focusRequester = inputFocus,
                    onToggleEmoji = emojiKeyboard::toggle,
                    onTextTapped = emojiKeyboard::onFieldFocused,
                    onSendMedia = { files, caption, spoiler -> vm.sendMedia(files.toOutgoing(asFiles = false, spoiler), caption, thumbnailer) },
                    onSendFiles = { files -> vm.sendFiles(files.toOutgoing(asFiles = true), thumbnailer) },
                )
            }
            EmojiKeyboardArea(emojiKeyboard, onEmoji = vm::insertEmoji)
        }

        // ---------------- запись ----------------
        if (recorder.kind == RecKind.VIDEO) VideoNoteLivePreview(recorder, with(density) { composerHeightPx.toDp() })
        if (recorder.phase == RecPhase.DRAGGING) {
            RecordingLockIndicator(
                recorder,
                Modifier.align(Alignment.BottomEnd).padding(end = 18.dp, bottom = with(density) { composerHeightPx.toDp() } + 10.dp),
            )
        }

        // ---------------- меню и диалоги ----------------
        menu?.let { t ->
            MessageContextMenu(
                target = t,
                isPinned = vm.pinnedId == t.msg.messageId,
                showCopy = !t.msg.isMedia && !t.msg.isCallLog,
                showEdit = t.msg.isMine && !t.msg.isMedia && !t.msg.isCallLog && t.msg.groupId == null,
                sortedReactions = vm::sortedReactions,
                onReaction = { emoji ->
                    menu = null
                    vm.pickReaction(t.msg, emoji)
                },
                onAction = { onMenuAction(t, it) },
                onDismiss = { menu = null },
            )
        }
    }

    deleteIds?.let { ids ->
        val anyDelivered = vm.messages.any { it.messageId in ids && (it.status == MessageStatus.SENT || it.status == MessageStatus.READ) }
        DeleteMessagesDialog(
            peerName = peerName,
            peerAccountId = vm.peer.accountId,
            showPeerCheckbox = anyDelivered && !vm.peerDeleted,
            onDismiss = { deleteIds = null },
            onConfirm = { forPeer ->
                deleteIds = null
                vm.delete(ids, forPeer)
            },
        )
    }
    reportTarget?.let { msg ->
        ReportDialog(
            onDismiss = { reportTarget = null },
            onSend = { comment, done -> vm.report(msg, comment, done) },
            onSent = {
                reportTarget = null
                Toast.makeText(context, context.getString(R.string.report_sent), Toast.LENGTH_SHORT).show()
            },
        )
    }
    if (confirmReset) {
        ResetSessionDialog(onDismiss = { confirmReset = false }, onConfirm = {
            confirmReset = false
            vm.resetSession()
        })
    }
}


/** Колбэки жестов строки сообщения. */
class RowGestures(
    val swipeReplyEnabled: Boolean,
    val onTap: (anchor: Offset) -> Unit,
    val onDoubleTap: () -> Unit,
    val onLongPress: () -> Unit,
    /** Протяжка после долгого тапа: под пальцем (координаты экрана чата) — какие id переключить. */
    val onDragSelect: (Offset) -> List<String>?,
    val toggleIds: (List<String>) -> Unit,
    val onSwipeReply: (dx: Float) -> Unit,
    val onSwipeReplyFire: () -> Unit,
    val onSwipeEnd: () -> Unit,
)

private enum class Phase { UP, LONG, HSWIPE, CANCEL }

/**
 * Чем окажется касание: отпустили (тап), свайп влево (ответ), вертикальный
 * скролл ленты или чужое касание (ссылка/кнопка внутри пузыря) — отмена.
 * Свайп вправо — тоже отмена: его забирает общий свайп назад ([swipeBack]).
 * Долгий тап — это истечение таймаута вокруг этой функции.
 */
private suspend fun AwaitPointerEventScope.classify(down: PointerInputChange, slop: Float, swipeStart: Array<Offset>): Phase {
    while (true) {
        val ch = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: return Phase.CANCEL
        if (!ch.pressed) return if (ch.isConsumed) Phase.CANCEL else Phase.UP
        if (ch.isConsumed) return Phase.CANCEL
        val d = ch.position - down.position
        if (abs(d.x) > slop && abs(d.x) > abs(d.y) * 1.5f) {
            if (d.x > 0) return Phase.CANCEL
            ch.consume()
            swipeStart[0] = ch.position
            return Phase.HSWIPE
        }
        if (abs(d.y) > slop) return Phase.CANCEL
    }
}

/**
 * Строка сообщения во всю ширину: зона тапа — вся строка, а не только пузырь;
 * галочка выбора — сбоку (слева у чужих, справа у своих); подсветка по
 * переходу — тоже во всю ширину. Распознавание жестов — одним автоматом,
 * чтобы тап, двойной тап, долгий тап с протяжкой и горизонтальный свайп не
 * спорили друг с другом и со скроллом ленты.
 */
@Composable
private fun MessageRow(
    group: List<StoredMessage>,
    selectionMode: Boolean,
    selected: Boolean,
    dissolving: Boolean,
    justReacted: Boolean,
    flash: Int,
    highlighted: Boolean,
    swipeDx: Float,
    rootCoords: () -> LayoutCoordinates?,
    onBounds: (Rect) -> Unit,
    gestures: RowGestures,
    bubble: @Composable () -> Unit,
) {
    val colors = LocalAppColors.current
    val rep = group.rep()
    val isMine = rep.isMine
    val coords = remember { arrayOfNulls<LayoutCoordinates>(1) }
    val screenWidthPx = with(LocalDensity.current) { LocalConfiguration.current.screenWidthDp.dp.toPx() }
    val flashA = flashAlpha(flash)
    // жест не перезапускается от смены режима выбора посреди протяжки — читаем актуальные значения
    val currentSelectionMode by rememberUpdatedState(selectionMode)
    val g by rememberUpdatedState(gestures)
    val animatedDx by animateFloatAsState(swipeDx, tween(if (swipeDx == 0f) 180 else 0), label = "swipe")

    fun toRoot(local: Offset): Offset {
        val root = rootCoords() ?: return local
        val mine = coords[0] ?: return local
        return root.localPositionOf(mine, local)
    }

    Row(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp)
            .jumpFlash(flashA, colors.primary)
            .onGloballyPositioned { c ->
                coords[0] = c
                rootCoords()?.let { root -> onBounds(root.localBoundingBoxOf(c)) }
            }
            .pointerInput(Unit) {
                val slop = viewConfiguration.touchSlop
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val swipeStart = arrayOf(down.position)
                    val phase = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) { classify(down, slop, swipeStart) } ?: Phase.LONG
                    when (phase) {
                        Phase.CANCEL -> Unit
                        Phase.UP -> {
                            if (currentSelectionMode) {
                                g.onTap(toRoot(down.position))
                            } else {
                                val second = withTimeoutOrNull(viewConfiguration.doubleTapTimeoutMillis) { awaitFirstDown() }
                                if (second != null) {
                                    g.onDoubleTap()
                                    // остаток второго тапа никому не нужен
                                    while (true) {
                                        val ev = awaitPointerEvent(PointerEventPass.Initial)
                                        ev.changes.forEach { it.consume() }
                                        if (ev.changes.none { it.pressed }) break
                                    }
                                } else {
                                    g.onTap(toRoot(down.position))
                                }
                            }
                        }
                        Phase.LONG -> {
                            g.onLongPress()
                            var lastIds: List<String>? = group.map { it.messageId }
                            while (true) {
                                val ev = awaitPointerEvent(PointerEventPass.Initial)
                                val ch = ev.changes.firstOrNull { it.id == down.id } ?: break
                                ch.consume()
                                if (!ch.pressed) break
                                val ids = g.onDragSelect(toRoot(ch.position))
                                if (ids != null && ids != lastIds) {
                                    lastIds = ids
                                    g.toggleIds(ids)
                                }
                            }
                        }
                        Phase.HSWIPE -> {
                            val maxOffset = screenWidthPx * 0.10f
                            var fired = false
                            var dx = swipeStart[0].x - down.position.x
                            while (true) {
                                val ev = awaitPointerEvent(PointerEventPass.Initial)
                                val ch = ev.changes.firstOrNull { it.id == down.id } ?: break
                                ch.consume()
                                if (!ch.pressed) break
                                dx = ch.position.x - down.position.x
                                if (dx < 0 && g.swipeReplyEnabled) {
                                    val shown = dx.coerceAtLeast(-maxOffset)
                                    g.onSwipeReply(shown)
                                    if (!fired && shown <= -maxOffset) {
                                        fired = true
                                        g.onSwipeReplyFire()
                                    }
                                }
                            }
                            g.onSwipeEnd()
                        }
                    }
                }
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (!isMine) SelectionSlot(selectionMode, selected)
        if (isMine) Spacer(Modifier.weight(1f))
        Box(Modifier.offset { IntOffset(animatedDx.toInt(), 0) }) {
            Dissolvable(dissolving) {
                Box(Modifier.padding(bottom = if (rep.myReaction != null || rep.peerReaction != null) 8.dp else 0.dp)) {
                    HighlightFrame(highlighted) { bubble() }
                    Box(Modifier.align(if (isMine) Alignment.BottomStart else Alignment.BottomEnd).padding(horizontal = 8.dp).offset(y = 8.dp)) {
                        ReactionBadges(rep.myReaction, rep.peerReaction, justReacted)
                    }
                }
            }
        }
        if (!isMine) Spacer(Modifier.weight(1f))
        if (isMine) SelectionSlot(selectionMode, selected)
    }
}

