package com.oshinobu.app.ui.chat

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.SystemClock
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.scrollBy
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
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
import androidx.compose.ui.layout.positionOnScreen
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
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
import com.oshinobu.app.ui.reactionHaptic
import com.oshinobu.app.ui.rememberPeerDisplayName
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.net.StickerInfo
import com.oshinobu.core.service.ForwardItem
import com.oshinobu.core.storage.MessageStatus
import com.oshinobu.core.storage.StoredMessage
import kotlin.math.abs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** Подписи вложений для панели передач — в языке интерфейса на момент открытия чата. */
data class MediaLabels(val photo: String, val video: String, val file: String, val voice: String, val videoNote: String, val sticker: String) {
    fun of(m: StoredMessage) = m.fileName ?: when {
        m.isVoice -> voice
        m.isVideoNote -> videoNote
        m.isVideo -> video
        m.isFile -> file
        else -> photo
    }

    /** Цитата в ответе: у стикера текста нет — подпись. */
    fun quote(m: StoredMessage): String = if (m.isSticker) sticker else m.text
}

@Composable
fun rememberMediaLabels(): MediaLabels {
    val context = LocalContext.current
    return remember {
        MediaLabels(
            context.getString(R.string.media_photo), context.getString(R.string.media_video), context.getString(R.string.media_file),
            context.getString(R.string.media_voiceNote), context.getString(R.string.media_videoNote),
            context.getString(R.string.sticker_preview),
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
    m.isSticker -> context.getString(R.string.sticker_preview)
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
    forwarded: List<ForwardItem>,
    onBack: () -> Unit,
    onOpenTransfers: () -> Unit,
    onOpenProfile: (accountId: String, login: String) -> Unit,
    onForward: (List<ForwardItem>) -> Unit,
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
        ChatViewModel(app.core, app.routerHost, target.login, target.accountId, target.deviceId, forwarded, labels)
    }
    val thumbnailer = remember { AndroidVideoThumbnailer(app.core.dirs.support) }
    // плеер — общий на приложение: вышли из чата — играет дальше (панель и окошко в списке чатов)
    val playback = LocalPlayback.current
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
    var stickerPreview by remember { mutableStateOf<StickerInfo?>(null) }
    var stickerPackFor by remember { mutableStateOf<String?>(null) }
    var stickerUpload by remember { mutableStateOf(false) }
    val wallpapers by app.core.wallpapers.all.collectAsState()
    var wallpaperDraft by remember { mutableStateOf<WallpaperDraft?>(null) }
    var wallpaperForPeer by remember { mutableStateOf(true) }
    var wallpaperBusy by remember { mutableStateOf(false) }
    var flashId by remember { mutableStateOf<String?>(null) }
    // когда началась подсветка сообщения [flashId] (uptime); 0 — нет
    var flashStartedAt by remember { mutableLongStateOf(0L) }
    var jumpJob by remember { mutableStateOf<Job?>(null) }
    var swipeReplyId by remember { mutableStateOf<String?>(null) }
    var swipeReplyDx by remember { mutableStateOf(0f) }
    var composerHeightPx by remember { mutableIntStateOf(0) }
    var headerHeightPx by remember { mutableIntStateOf(0) }
    val rootCoords = remember { arrayOfNulls<LayoutCoordinates>(1) }
    // протяжка выбора после долгого нажатия: где палец (координаты экрана чата) и последняя строка под ним
    var dragSelectPos by remember { mutableStateOf<Offset?>(null) }
    val dragLastIds = remember { arrayOfNulls<List<String>>(1) }
    val rowBounds = remember { HashMap<String, Rect>() }
    val listState = rememberLazyListState()
    val groups = remember(vm.messages) { groupMessages(vm.messages).asReversed() }
    val latestGroups by rememberUpdatedState(groups)
    val emojiKeyboard = rememberEmojiKeyboardState(withStickers = true)
    val inputFocus = emojiKeyboard.focusRequester

    LaunchedEffect(Unit) { vm.reactionPulses.collect { context.reactionHaptic() } }
    LaunchedEffect(Unit) {
        vm.notices.collect { n ->
            val text = when (n) {
                ChatNotice.Copied -> context.getString(R.string.common_copied)
                ChatNotice.RetryFailedPermanently -> context.getString(R.string.chat_retryFailedPermanently)
                ChatNotice.SessionResetDone -> context.getString(R.string.chat_resetSessionDone)
                is ChatNotice.FilesTooLarge -> context.getString(R.string.chat_fileTooLarge)
                ChatNotice.ForwardFailed -> context.getString(R.string.chat_forwardFailed)
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

    /**
     * Переход к сообщению (закреп, цитата) — непрерывная прокрутка, как в
     * Telegram: лента разгоняется, едет, пока сообщение не покажется, и плавно
     * тормозит у него (со скорости, на которой ехала). Только совсем далёкое
     * (больше [JUMP_TELEPORT_ITEMS] сообщений) — сначала перескок на полтора
     * экрана до него, иначе прокрутка шла бы секундами. [target] — где
     * окажется нижний край группы [index] над низом ленты; false — не доехали.
     */
    suspend fun scrollSmoothlyTo(index: Int, target: Int): Boolean {
        val viewport = listState.layoutInfo.viewportSize.height.coerceAtLeast(1)
        fun shown() = listState.layoutInfo.visibleItemsInfo.firstOrNull { it.index == index }
        // лента снизу вверх: индексы больше — выше (старее), туда — scrollBy(+)
        if (shown() == null && abs(index - listState.firstVisibleItemIndex) > JUMP_TELEPORT_ITEMS) {
            val above = index > listState.firstVisibleItemIndex
            listState.scrollToItem(index, -(target + (if (above) 1 else -1) * viewport * 3 / 2))
        }
        val maxStep = viewport * JUMP_MAX_SPEED_PER_FRAME
        var step = 0f
        while (shown() == null) {
            val dir = if (index > listState.firstVisibleItemIndex) 1f else -1f
            step = minOf(maxStep, step + maxStep * 0.12f)
            withFrameNanos { }
            if (listState.scrollBy(dir * step) == 0f) break
        }
        val item = shown() ?: return false
        val remaining = (item.offset - target).toFloat()
        // тормозим до нуля со скорости [step] за кадр: путь = скорость · время / 2
        val duration = if (step > 0f) (2f * abs(remaining) / step * 16.7f).toInt().coerceIn(250, 900) else JUMP_SCROLL_MS
        listState.animateScrollBy(remaining, tween(duration, easing = if (step > 0f) LinearOutSlowInEasing else FastOutSlowInEasing))
        return true
    }

    fun jumpTo(messageId: String) {
        val index = groups.indexOfFirst { g -> g.any { it.messageId == messageId } }
        if (index < 0) return
        jumpJob?.cancel()
        jumpJob = scope.launch {
            // где окажется сообщение: его нижний край — на 160dp выше низа ленты
            if (!scrollSmoothlyTo(index, with(density) { 160.dp.roundToPx() })) return@launch
            flashId = groups.getOrNull(index)?.key()
            flashStartedAt = SystemClock.uptimeMillis()
        }
    }

    /** Кнопка «вниз»: до самого нового сообщения той же прокруткой, что и переход к закрепу. */
    fun jumpToBottom() {
        jumpJob?.cancel()
        jumpJob = scope.launch {
            scrollSmoothlyTo(0, 0)
            // добрать остаток, если нижнее сообщение выше экрана ленты
            if (listState.firstVisibleItemIndex != 0 || listState.firstVisibleItemScrollOffset != 0) {
                listState.animateScrollToItem(0)
            }
        }
    }
    // последнее сообщение целиком ушло за низ ленты — показать кнопку «вниз»
    val showScrollDown by remember { derivedStateOf { positioned && listState.firstVisibleItemIndex > 0 } }

    val searchMatches = if (vm.searchQuery != null) vm.searchMatches() else emptyList()
    val currentMatch = searchMatches.getOrNull(searchIndex)
    LaunchedEffect(currentMatch?.messageId, searchAsList) {
        if (currentMatch != null && !searchAsList) {
            val index = groups.indexOfFirst { g -> g.any { it.messageId == currentMatch.messageId } }
            if (index >= 0) listState.animateScrollToItem(index, -with(density) { 160.dp.roundToPx() })
        }
    }

    val wallpaperFailed = stringResource(R.string.error_wallpaperFailed)
    val keyboard = LocalSoftwareKeyboardController.current
    val wallpaperPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            wallpaperDraft = try {
                context.loadWallpaperDraft(uri)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                app.core.logger.error("Wallpaper: picked image unreadable: $e")
                Toast.makeText(context, wallpaperFailed, Toast.LENGTH_SHORT).show()
                return@launch
            }
            wallpaperForPeer = true
            // превью — на весь чат: клавиатуры не мешают
            keyboard?.hide()
            emojiKeyboard.closeEmoji()
        }
    }

    fun setWallpaper(peerAccountId: String, draft: WallpaperDraft, forPeer: Boolean) {
        wallpaperBusy = true
        scope.launch {
            try {
                app.core.wallpapers.set(peerAccountId, draft.croppedJpeg(), forPeer)
                wallpaperDraft = null
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                app.core.logger.error("Wallpaper: set failed: $e")
                Toast.makeText(context, wallpaperFailed, Toast.LENGTH_SHORT).show()
            } finally {
                wallpaperBusy = false
            }
        }
    }

    fun removeWallpaper(peerAccountId: String) {
        scope.launch {
            try {
                app.core.wallpapers.remove(peerAccountId)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                app.core.logger.error("Wallpaper: remove failed: $e")
                Toast.makeText(context, wallpaperFailed, Toast.LENGTH_SHORT).show()
            }
        }
    }

    fun handleBack() {
        when {
            menu != null -> menu = null
            wallpaperDraft != null -> if (!wallpaperBusy) wallpaperDraft = null
            vm.selectionMode -> vm.clearSelection()
            vm.searchQuery != null -> vm.closeSearch()
            emojiKeyboard.emojiMode -> emojiKeyboard.closeEmoji()
            else -> onBack()
        }
    }
    BackHandler(enabled = vm.selectionMode || vm.searchQuery != null || emojiKeyboard.emojiMode || wallpaperDraft != null, onBack = ::handleBack)

    fun openMenu(group: List<StoredMessage>, anchor: Offset) {
        val rep = group.rep()
        val ids = group.map { it.messageId }
        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
        menu = MenuTarget(rep, ids, anchor, vm.groupStatus(ids))
    }

    /** Выбор или снятие выбора — с коротким откликом вибрацией. */
    fun toggleSelection(ids: List<String>) {
        vm.toggleSelected(ids)
        haptics.performHapticFeedback(HapticFeedbackType.VirtualKey)
    }

    /** id сообщений строки под точкой экрана; только строки на экране — у ушедших за край границы устарели. */
    fun groupIdsAt(pos: Offset): List<String>? {
        val visible = listState.layoutInfo.visibleItemsInfo.map { it.key }.toSet()
        val hit = rowBounds.entries.firstOrNull { it.key in visible && pos.y >= it.value.top && pos.y < it.value.bottom }?.key
        return hit?.let { key -> latestGroups.firstOrNull { it.key() == key }?.map { it.messageId } }
    }

    /** Палец протяжкой зашёл на новую строку — переключить её выбор. */
    fun dragSelectAt(pos: Offset) {
        val ids = groupIdsAt(pos) ?: return
        if (ids != dragLastIds[0]) {
            dragLastIds[0] = ids
            toggleSelection(ids)
        }
    }

    // Автопрокрутка при протяжке выбора: палец у верхнего края ленты — листаем к
    // более старым (выше), у нижнего — к новым; чем ближе к краю, тем быстрее.
    // После каждого сдвига под неподвижным пальцем оказывается новая строка.
    LaunchedEffect(dragSelectPos != null) {
        if (dragSelectPos == null) return@LaunchedEffect
        val edge = with(density) { 72.dp.toPx() }
        val maxStep = with(density) { 14.dp.toPx() }
        while (true) {
            val pos = dragSelectPos ?: break
            val top = headerHeightPx.toFloat()
            val bottom = (rootCoords[0]?.size?.height ?: 0).toFloat() - composerHeightPx
            val step = when {
                pos.y < top + edge -> maxStep * ((top + edge - pos.y) / edge).coerceIn(0f, 1f)
                pos.y > bottom - edge -> -maxStep * ((pos.y - (bottom - edge)) / edge).coerceIn(0f, 1f)
                else -> 0f
            }
            // лента перевёрнута (новые внизу): положительный сдвиг — к более старым
            if (step != 0f && listState.scrollBy(step) != 0f) dragSelectAt(pos)
            withFrameNanos { }
        }
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
            MessageAction.FORWARD -> onForward(vm.forwardItemsOf(vm.messages.filter { it.messageId in t.groupIds }))
            MessageAction.EDIT -> {
                vm.startEdit(msg)
                inputFocus.requestFocus()
            }
            MessageAction.SELECT -> {
                vm.toggleSelected(t.groupIds)
                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
            }
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
        Modifier.fillMaxSize()
            .onGloballyPositioned { rootCoords[0] = it }
            // Протяжка выбора — здесь, над всем экраном, а не в строке: строка, с
            // которой начали, при автопрокрутке уходит за край и перестаёт получать
            // касания. Пока протяжка идёт, касание целиком наше — лента не листается пальцем.
            .pointerInput(Unit) {
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                    while (true) {
                        val ev = awaitPointerEvent(PointerEventPass.Initial)
                        if (dragSelectPos == null) {
                            if (ev.changes.none { it.pressed }) break
                            continue
                        }
                        ev.changes.forEach { it.consume() }
                        val ch = ev.changes.first()
                        if (!ch.pressed) {
                            dragSelectPos = null
                            dragLastIds[0] = null
                            break
                        }
                        dragSelectPos = ch.position
                        dragSelectAt(ch.position)
                    }
                }
            },
    ) {
        ChatBackdrop(vm.peer.accountId?.let { wallpapers[it] }, wallpaperDraft, Modifier.matchParentSize())

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
                val expandedVideo = maxWidth - 32.dp
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
                        // удалённое (уже рассыпалось) уходит сразу, остальные плавно съезжают на его
                        // место и встают — без пружины и отскока; появление и уход — без затухания
                        Box(Modifier.animateItem(fadeInSpec = null, placementSpec = tween(MESSAGE_SHIFT_MS, easing = FastOutSlowInEasing), fadeOutSpec = null)) {
                            when {
                                rep.isCallLog -> CallLogRow(rep)
                                rep.isUndecryptable -> UndecryptableRow(rep, peerName)
                                else -> MessageRow(
                                    group = group,
                                    selectionMode = vm.selectionMode,
                                    selected = rep.messageId in vm.selected,
                                    dissolving = group.any { it.messageId in vm.dissolving },
                                    flash = if (flashId == group.key()) flashStartedAt else 0L,
                                    highlighted = currentMatch != null && group.any { it.messageId == currentMatch.messageId },
                                    swipeDx = if (swipeReplyId == rep.messageId) swipeReplyDx else 0f,
                                    rootCoords = { rootCoords[0] },
                                    onBounds = { rowBounds[group.key()] = it },
                                    gestures = RowGestures(
                                        swipeReplyEnabled = !vm.selectionMode && !composerBlocked,
                                        isListScrolling = { listState.isScrollInProgress },
                                        onTap = { anchor ->
                                            if (vm.selectionMode) toggleSelection(group.map { it.messageId }) else openMenu(group, anchor)
                                        },
                                        onDoubleTap = { if (!vm.selectionMode) vm.applyDefaultReaction(rep) },
                                        onLongPress = { pos ->
                                            // вход в режим выбора (или выбор ещё одной строки) — и дальше протяжка
                                            val ids = group.map { it.messageId }
                                            vm.toggleSelected(ids)
                                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                            dragLastIds[0] = ids
                                            dragSelectPos = pos
                                        },
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
                                        justReacted = rep.messageId in vm.justReacted,
                                        peerName = peerName,
                                        maxBubble = maxBubble,
                                        maxText = maxText,
                                        expandedVideo = expandedVideo,
                                        playback = playback,
                                        revealed = revealedSpoilers,
                                        onReveal = { revealedSpoilers = revealedSpoilers + it },
                                        onJump = ::jumpTo,
                                        onOpenViewer = { m -> onOpenMedia(target.login, m.messageId) },
                                        onOpenFile = { openFile(it) },
                                        onSaveFile = saveFile,
                                        onOpenStickerPack = { stickerPackFor = it },
                                    )
                                }
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
                        // скачать — только одно голосовое или видеосообщение
                        onSave = vm.selected.singleOrNull()
                            ?.let { id -> vm.messages.firstOrNull { it.messageId == id } }
                            ?.takeIf { it.isVoice || it.isVideoNote }
                            ?.let { msg -> { saveFile(msg); vm.clearSelection() } },
                        onCopy = {
                            val texts = vm.selectedTexts()
                            if (texts.isNotEmpty()) {
                                context.copyToClipboard(texts.joinToString("\n"))
                                vm.clearSelection()
                                vm.notifyCopied()
                            }
                        },
                        onForward = { vm.selectedForwardItems().takeIf { it.isNotEmpty() }?.let(onForward) },
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
                        onPickWallpaper = if (vm.peerDeleted || vm.peer.accountId == null) null else {
                            { wallpaperPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
                        },
                        onRemoveWallpaper = vm.peer.accountId?.takeIf { it in wallpapers }?.let { id -> { removeWallpaper(id) } },
                    )
                }
            }
            OngoingCallBanner(peerLogin = target.login, onOpen = onOpenCall)
            // панель плеера — только если играет сообщение из этого чата
            AnimatedVisibility(
                playback.activeId != null && vm.messages.any { it.messageId == playback.activeId },
                enter = expandVertically() + fadeIn(), exit = shrinkVertically() + fadeOut(),
            ) {
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
                    stickersPanel = emojiKeyboard.stickersPage && vm.searchQuery == null,
                    focusRequester = inputFocus,
                    onToggleEmoji = emojiKeyboard::toggle,
                    onTextTapped = emojiKeyboard::onFieldFocused,
                    onSendMedia = { files, caption, spoiler -> vm.sendMedia(files.toOutgoing(asFiles = false, spoiler), caption, thumbnailer) },
                    onSendFiles = { files -> vm.sendFiles(files.toOutgoing(asFiles = true), thumbnailer) },
                )
            }
            EmojiKeyboardArea(
                emojiKeyboard,
                onEmoji = vm::insertEmoji,
                stickers = if (composerBlocked || vm.searchQuery != null) null else { bottomPadding ->
                    StickerPanel(
                        bottomPadding = bottomPadding,
                        onSend = vm::sendSticker,
                        onPreview = { stickerPreview = it },
                        onAddPack = { stickerUpload = true },
                    )
                },
            )
        }

        // Кнопка «вниз» — над полем ввода, когда последнее сообщение ушло из вида
        AnimatedVisibility(
            showScrollDown && !vm.selectionMode && !(vm.searchQuery != null && searchAsList),
            modifier = Modifier.align(Alignment.BottomEnd)
                .padding(end = 12.dp, bottom = with(density) { composerHeightPx.toDp() } + 12.dp),
            enter = fadeIn(tween(160)) + scaleIn(tween(160), initialScale = 0.8f),
            exit = fadeOut(tween(140)) + scaleOut(tween(140), targetScale = 0.8f),
        ) {
            ScrollDownButton(onClick = ::jumpToBottom)
        }

        // Режим выбора: «Ответить»/«Переслать» — поверх ленты, над полем ввода;
        // в высоту поля не входят, поэтому ленту не сдвигают.
        AnimatedVisibility(
            vm.selectionMode && vm.searchQuery == null,
            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = with(density) { composerHeightPx.toDp() }),
            enter = fadeIn(tween(160)) + slideInVertically(tween(200)) { it / 2 },
            exit = fadeOut(tween(140)) + slideOutVertically(tween(160)) { it / 2 },
        ) {
            val selectedGroups = groups.filter { g -> g.any { it.messageId in vm.selected } }
            val forwardItems = vm.selectedForwardItems()
            SelectionActions(
                // ответить можно только на одно сообщение
                canReply = selectedGroups.size == 1 && !composerBlocked,
                canForward = forwardItems.isNotEmpty(),
                onReply = {
                    val target = selectedGroups.singleOrNull()?.rep() ?: return@SelectionActions
                    vm.clearSelection()
                    vm.startReply(target)
                    inputFocus.requestFocus()
                },
                onForward = { onForward(forwardItems) },
            )
        }

        // выбранная картинка — фоном всего чата, снизу — "Установить как фон чата"
        val draft = wallpaperDraft
        val draftPeer = vm.peer.accountId
        if (draft != null && draftPeer != null) {
            // пальцы двигают и масштабируют картинку, а не листают ленту
            WallpaperGestures(draft, Modifier.matchParentSize())
            WallpaperPreviewBar(
                peerAccountId = draftPeer,
                peerName = peerName,
                canSetForPeer = !composerBlocked,
                forPeer = wallpaperForPeer,
                onForPeerChange = { wallpaperForPeer = it },
                busy = wallpaperBusy,
                onSet = { setWallpaper(draftPeer, draft, wallpaperForPeer && !composerBlocked) },
                onCancel = { wallpaperDraft = null },
                modifier = Modifier.align(Alignment.BottomCenter),
            )
        }

        // ---------------- запись ----------------
        if (recorder.kind == RecKind.VIDEO) VideoNoteLivePreview(recorder, with(density) { composerHeightPx.toDp() })
        if (recorder.phase == RecPhase.DRAGGING) {
            RecordingLockIndicator(
                recorder,
                Modifier.align(Alignment.BottomEnd).padding(end = 18.dp, bottom = with(density) { composerHeightPx.toDp() } + 10.dp),
            )
        }

        // долгое нажатие на стикер в панели — он крупно поверх чата
        StickerPreviewOverlay(stickerPreview)

        // ---------------- меню и диалоги ----------------
        menu?.let { t ->
            MessageContextMenu(
                target = t,
                isPinned = vm.pinnedId == t.msg.messageId,
                showCopy = !t.msg.isMedia && !t.msg.isCallLog && !t.msg.isSticker,
                showEdit = t.msg.isMine && !t.msg.isMedia && !t.msg.isCallLog && !t.msg.isSticker && t.msg.groupId == null,
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
    stickerPackFor?.let { id ->
        StickerPackSheet(id, onSend = if (composerBlocked) null else vm::sendSticker, onDismiss = { stickerPackFor = null })
    }
    if (stickerUpload) StickerUploadDialog(onClose = { stickerUpload = false })
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
    /** Лента прокручивается (в т.ч. по инерции) — тап, который её останавливает, не считается. */
    val isListScrolling: () -> Boolean,
    val onTap: (anchor: Offset) -> Unit,
    val onDoubleTap: () -> Unit,
    /** Долгий тап: где палец (координаты экрана чата). Дальнейшую протяжку ведёт экран чата. */
    val onLongPress: (Offset) -> Unit,
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
    flash: Long,
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
            // удаляют — место строки сразу схлопывается, соседние съезжают, пока она рассыпается
            .collapseOnDissolve(dissolving)
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
                    // лента ещё ехала — этот тап только её останавливает, меню не открываем
                    val stoppedScroll = g.isListScrolling()
                    val swipeStart = arrayOf(down.position)
                    val phase = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) { classify(down, slop, swipeStart) } ?: Phase.LONG
                    when (phase) {
                        Phase.CANCEL -> Unit
                        Phase.UP -> if (!stoppedScroll) {
                            if (currentSelectionMode) {
                                g.onTap(toRoot(down.position))
                            } else {
                                // ждём второго тапа (реакция) до 220 мс от первого касания, как Telegram,
                                // а не системные 300 мс после отпускания: меню открывается быстрее
                                val wait = (DOUBLE_TAP_WINDOW_MS - (SystemClock.uptimeMillis() - down.uptimeMillis)).coerceAtLeast(0)
                                val second = if (wait == 0L) null else withTimeoutOrNull(wait) { awaitFirstDown() }
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
                        // остаток касания (протяжку) забирает экран чата — см. pointerInput корня
                        Phase.LONG -> g.onLongPress(toRoot(down.position))
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
                // реакции — в нижней строке самого сообщения, рядом со временем
                HighlightFrame(highlighted) { bubble() }
            }
        }
        if (!isMine) Spacer(Modifier.weight(1f))
        if (isMine) SelectionSlot(selectionMode, selected)
    }
}

/** Сообщения съезжают на место удалённого. */
private const val MESSAGE_SHIFT_MS = 300

/** Лента доезжает до закрепа/цитаты, если оно уже на экране. */
private const val JUMP_SCROLL_MS = 700

/** Дальше этого (в сообщениях) к закрепу/цитате — сначала перескок. */
private const val JUMP_TELEPORT_ITEMS = 60

/** Наибольшая скорость прокрутки к закрепу — доля экрана за кадр (≈3 экрана в секунду). */
private const val JUMP_MAX_SPEED_PER_FRAME = 0.05f

/** Окно двойного тапа (реакция) — от первого касания; одиночный тап (меню) — не раньше. Как в Telegram. */
private const val DOUBLE_TAP_WINDOW_MS = 220L

/** Квадратная кнопка со скруглёнными углами и стрелкой вниз — к последнему сообщению. */
@Composable
private fun ScrollDownButton(onClick: () -> Unit) {
    val colors = LocalAppColors.current
    Box(
        Modifier.size(44.dp).shadow(4.dp, RoundedCornerShape(12.dp)).clip(RoundedCornerShape(12.dp))
            .background(colors.surface).clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.Filled.KeyboardArrowDown, stringResource(R.string.chat_scrollToBottom), tint = colors.textPrimary)
    }
}
