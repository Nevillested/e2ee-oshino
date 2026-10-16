package com.oshinobu.app.ui.chat

import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.automirrored.outlined.Forward
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.CheckCircleOutline
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Flag
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionOnScreen
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import com.oshinobu.app.R
import com.oshinobu.app.ui.emoji.allEmojis
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.storage.MessageStatus
import com.oshinobu.core.storage.StoredMessage
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

enum class MessageAction { REPLY, COPY, PIN, UNPIN, FORWARD, EDIT, SELECT, DELETE, REPORT, CANCEL_SEND, RETRY_SEND }

/** Открытое контекстное меню: сообщение (или представитель группы), её id и точка тапа в координатах экрана чата. */
data class MenuTarget(val msg: StoredMessage, val groupIds: List<String>, val anchor: Offset, val groupStatus: String?)

/** Ячейка эмодзи; в ряду — [RowEmojis] эмодзи и стрелка, в раскрытой сетке — [GridColumns] в ряд. */
private val EmojiCell = 42.dp
private const val RowEmojis = 6
private const val GridColumns = 7
private val BarPadding = 6.dp
private val BarWidth = EmojiCell * (RowEmojis + 1) + BarPadding * 2
private val BarHeight = EmojiCell + BarPadding * 2
private val GridHeight = EmojiCell * 6 + BarPadding * 2
private val ActionsWidth = 232.dp
private val ActionHeight = 44.dp
private val PanelGap = 8.dp
private val Danger = Color(0xFFFF5252)

private data class ActionItem(val icon: ImageVector, val label: Int, val action: MessageAction, val danger: Boolean = false)

private fun actionsFor(isMine: Boolean, showCopy: Boolean, showEdit: Boolean, isPinned: Boolean, status: String?): List<ActionItem> = when (status) {
    MessageStatus.SENDING -> listOf(ActionItem(Icons.Filled.Close, R.string.action_cancelSend, MessageAction.CANCEL_SEND, danger = true))
    MessageStatus.FAILED -> listOf(
        ActionItem(Icons.Filled.Refresh, R.string.action_retrySend, MessageAction.RETRY_SEND),
        ActionItem(Icons.Filled.Close, R.string.action_cancelSend, MessageAction.CANCEL_SEND, danger = true),
    )
    else -> buildList {
        add(ActionItem(Icons.AutoMirrored.Filled.Reply, R.string.action_reply, MessageAction.REPLY))
        if (showCopy) add(ActionItem(Icons.Outlined.ContentCopy, R.string.action_copy, MessageAction.COPY))
        add(
            if (isPinned) ActionItem(Icons.Outlined.PushPin, R.string.action_unpin, MessageAction.UNPIN)
            else ActionItem(Icons.Outlined.PushPin, R.string.action_pin, MessageAction.PIN),
        )
        add(ActionItem(Icons.AutoMirrored.Outlined.Forward, R.string.action_forward, MessageAction.FORWARD))
        if (showEdit) add(ActionItem(Icons.Outlined.Edit, R.string.action_edit, MessageAction.EDIT))
        add(ActionItem(Icons.Outlined.CheckCircleOutline, R.string.action_select, MessageAction.SELECT))
        add(ActionItem(Icons.Outlined.Delete, R.string.action_delete, MessageAction.DELETE, danger = true))
        if (!isMine) add(ActionItem(Icons.Outlined.Flag, R.string.action_report, MessageAction.REPORT, danger = true))
    }
}

/** Окно меню — во весь экран, от его левого верхнего угла. */
private object WindowOrigin : PopupPositionProvider {
    override fun calculatePosition(anchorBounds: IntRect, windowSize: IntSize, layoutDirection: LayoutDirection, popupContentSize: IntSize) = IntOffset.Zero
}

/** Без фокуса (клавиатура и поле ввода остаются), во весь экран; "назад" и тап мимо — сами. */
private val MenuWindowProperties = PopupProperties(
    flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
    dismissOnBackPress = false,
    dismissOnClickOutside = false,
    usePlatformDefaultWidth = false,
)

/**
 * Контекстное меню сообщения поверх чата: панель реакций (частые первыми,
 * стрелка раскрывает все) и действия. Своё сообщение — меню левее точки
 * тапа, чужое — правее; всегда в пределах экрана. В процессе отправки —
 * только "отменить", после сбоя — "повторить"/"отменить", без реакций.
 */
@Composable
fun MessageContextMenu(
    target: MenuTarget,
    isPinned: Boolean,
    showCopy: Boolean,
    showEdit: Boolean,
    sortedReactions: suspend (List<String>) -> List<String>,
    onReaction: (String) -> Unit,
    onAction: (MessageAction) -> Unit,
    onDismiss: () -> Unit,
    /** Где на экране левый верхний угол экрана чата (в его координатах — [MenuTarget.anchor]). */
    rootOnScreen: Offset,
) {
    val colors = LocalAppColors.current
    val msg = target.msg
    val actions = actionsFor(msg.isMine, showCopy, showEdit, isPinned, target.groupStatus)
    val withReactions = target.groupStatus == null
    var expanded by remember { mutableStateOf(false) }
    val emojis by produceState(allEmojis) { value = sortedReactions(allEmojis) }
    val appear = remember { Animatable(0f) }
    LaunchedEffect(Unit) { appear.animateTo(1f, tween(160, easing = FastOutSlowInEasing)) }
    BackHandler(onBack = onDismiss)

    // отдельным окном: обычные слои экрана лежат под клавиатурой, а всплывающее окно
    // Android кладёт над ней — меню видно и при поднятой клавиатуре (как в Telegram).
    // Клавиатура остаётся: окно не забирает фокус у поля ввода.
    Popup(popupPositionProvider = WindowOrigin, properties = MenuWindowProperties) {
        var originOnScreen by remember { mutableStateOf<Offset?>(null) }
        BoxWithConstraints(Modifier.fillMaxSize().onGloballyPositioned { originOnScreen = it.positionOnScreen() }) {
            val density = LocalDensity.current
            // точка нажатия — в координатах экрана чата; переводим в координаты окна меню
            val anchor = target.anchor + rootOnScreen - (originOnScreen ?: rootOnScreen)
            val panelsWidth = if (withReactions) BarWidth else ActionsWidth
            val estimatedHeight = when {
                expanded -> GridHeight
                withReactions -> BarHeight + PanelGap + ActionHeight * actions.size
                else -> ActionHeight * actions.size
            }
            val margin = 8.dp
            val offset = with(density) {
                val w = panelsWidth.toPx()
                val h = estimatedHeight.toPx()
                val m = margin.toPx()
                val x = (if (msg.isMine) anchor.x - w else anchor.x).coerceIn(m, (constraints.maxWidth - w - m).coerceAtLeast(m))
                val y = anchor.y.coerceIn(m, (constraints.maxHeight - h - m).coerceAtLeast(m))
                IntOffset(x.toInt(), y.toInt())
            }
            Box(
                Modifier.fillMaxSize().graphicsLayer { alpha = appear.value }.background(Color.Black.copy(alpha = 0.25f))
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss),
            )
            // реакции и действия — две отдельные панели (как в Telegram), выровнены по стороне сообщения
            Column(
                Modifier
                    .offset { offset }
                    .width(panelsWidth)
                    .graphicsLayer {
                        alpha = appear.value
                        scaleX = 0.85f + 0.15f * appear.value
                        scaleY = 0.85f + 0.15f * appear.value
                        transformOrigin = TransformOrigin(if (msg.isMine) 1f else 0f, 0f)
                    },
                horizontalAlignment = if (msg.isMine) Alignment.End else Alignment.Start,
            ) {
                if (withReactions) {
                    val shape = RoundedCornerShape(if (expanded) 18.dp else 50.dp)
                    Box(
                        Modifier.width(BarWidth).shadow(6.dp, shape).clip(shape).background(colors.surface)
                            .animateContentSize(tween(260)),
                    ) {
                        if (expanded) {
                            ReactionGrid(emojis, msg.myReaction, onReaction, onCollapse = { expanded = false })
                        } else {
                            ReactionRow(emojis.take(RowEmojis + 1), msg.myReaction, onReaction, onExpand = { expanded = true })
                        }
                    }
                }
                AnimatedVisibility(!expanded, enter = fadeIn(tween(180)) + expandVertically(tween(220)), exit = fadeOut(tween(140)) + shrinkVertically(tween(220))) {
                    Column(
                        Modifier.padding(top = if (withReactions) PanelGap else 0.dp).width(ActionsWidth)
                            .shadow(6.dp, RoundedCornerShape(16.dp)).clip(RoundedCornerShape(16.dp)).background(colors.surface),
                    ) {
                        actions.forEach { item ->
                            Row(
                                Modifier.fillMaxWidth().height(ActionHeight).clickable { onAction(item.action) }.padding(horizontal = 16.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(item.icon, null, Modifier.size(22.dp), tint = if (item.danger) Danger else colors.textMuted)
                                Spacer(Modifier.width(13.dp))
                                Text(stringResource(item.label), color = if (item.danger) Danger else colors.textPrimary, fontSize = 17.sp)
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * Ряд реакций: шесть эмодзи и стрелка. Повести пальцем справа налево — ряд
 * сдвигается и из-под стрелки выезжает седьмой; пока палец на экране, можно
 * вернуть обратно. Отпустили, вытянув больше половины, — раскрывается сетка
 * всех эмодзи (действия прячутся), меньше — ряд возвращается на место.
 */
@Composable
private fun ReactionRow(emojis: List<String>, myReaction: String?, onReaction: (String) -> Unit, onExpand: () -> Unit) {
    val colors = LocalAppColors.current
    val scope = rememberCoroutineScope()
    val cellPx = with(LocalDensity.current) { EmojiCell.toPx() }
    val pull = remember { Animatable(0f) }
    fun release() {
        scope.launch {
            if (pull.value > cellPx / 2) onExpand() else pull.animateTo(0f, spring(dampingRatio = 0.8f, stiffness = 600f))
        }
    }
    Box(
        Modifier.width(BarWidth).height(BarHeight).pointerInput(Unit) {
            detectHorizontalDragGestures(onDragEnd = ::release, onDragCancel = ::release) { change, dx ->
                change.consume()
                // палец влево — вытягиваем; чуть дальше седьмого — с сопротивлением
                scope.launch { pull.snapTo((pull.value - dx).coerceIn(0f, cellPx * 1.25f)) }
            }
        },
    ) {
        Box(Modifier.align(Alignment.CenterStart).padding(start = BarPadding).width(EmojiCell * RowEmojis).height(EmojiCell).clipToBounds()) {
            Row(Modifier.wrapContentWidth(Alignment.Start, unbounded = true).graphicsLayer { translationX = -pull.value }) {
                emojis.forEachIndexed { i, emoji -> EmojiCellView(emoji, emoji == myReaction, i) { onReaction(emoji) } }
            }
        }
        Box(
            Modifier.align(Alignment.CenterEnd).padding(end = BarPadding).size(EmojiCell)
                .graphicsLayer { alpha = 1f - (pull.value / cellPx).coerceIn(0f, 1f) * 0.6f }
                .clip(CircleShape).background(colors.textMuted.copy(alpha = 0.18f)).clickable(onClick = onExpand),
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Filled.KeyboardArrowDown, null, tint = colors.textMuted) }
    }
}

/** Все эмодзи сеткой (раскрытые реакции); стрелка вверх — обратно к ряду и действиям. */
@Composable
private fun ReactionGrid(emojis: List<String>, myReaction: String?, onReaction: (String) -> Unit, onCollapse: () -> Unit) {
    val colors = LocalAppColors.current
    Box(Modifier.width(BarWidth).height(GridHeight).padding(BarPadding)) {
        LazyVerticalGrid(GridCells.Fixed(GridColumns)) {
            itemsIndexed(emojis) { i, emoji -> EmojiCellView(emoji, emoji == myReaction, i.coerceAtMost(GridColumns)) { onReaction(emoji) } }
        }
        Box(
            Modifier.align(Alignment.TopEnd).size(EmojiCell).clip(CircleShape).background(colors.surface).clickable(onClick = onCollapse),
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Filled.KeyboardArrowUp, null, tint = colors.textMuted) }
    }
}

/** Эмодзи-кнопка: при появлении "выпрыгивает" с пружинкой — по очереди слева направо. */
@Composable
private fun EmojiCellView(emoji: String, selected: Boolean, order: Int, onClick: () -> Unit) {
    val colors = LocalAppColors.current
    val pop = remember { Animatable(0.3f) }
    LaunchedEffect(Unit) {
        delay(order * 28L)
        pop.animateTo(1f, spring(dampingRatio = 0.45f, stiffness = 520f))
    }
    Box(
        Modifier.size(EmojiCell)
            .graphicsLayer {
                scaleX = pop.value
                scaleY = pop.value
                alpha = ((pop.value - 0.3f) / 0.7f).coerceIn(0f, 1f)
            }
            .clip(CircleShape)
            .background(if (selected) colors.primary.copy(alpha = 0.25f) else Color.Transparent)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Text(emoji, fontSize = 24.sp) }
}
