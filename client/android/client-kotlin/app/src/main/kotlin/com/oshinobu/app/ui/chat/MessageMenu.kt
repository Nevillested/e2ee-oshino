package com.oshinobu.app.ui.chat

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
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.union
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
import androidx.compose.runtime.mutableFloatStateOf
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
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.oshinobu.app.R
import com.oshinobu.app.ui.emoji.allEmojis
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.storage.MessageStatus
import com.oshinobu.core.storage.StoredMessage
import kotlin.math.exp
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
) {
    val colors = LocalAppColors.current
    val msg = target.msg
    val actions = actionsFor(msg.isMine, showCopy, showEdit, isPinned, target.groupStatus)
    val withReactions = target.groupStatus == null
    var expanded by remember { mutableStateOf(false) }
    val emojis by produceState(allEmojis) { value = sortedReactions(allEmojis) }
    val appear = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { appear.animateTo(1f, tween(160, easing = FastOutSlowInEasing)) }
    // закрытие — обратная анимация открытия (панели уменьшаются и гаснут, затемнение уходит),
    // и только потом действие; повторные тапы, пока закрывается, — мимо
    var closing by remember { mutableStateOf(false) }
    fun close(then: () -> Unit) {
        if (closing) return
        closing = true
        scope.launch {
            appear.animateTo(0f, tween(140, easing = FastOutSlowInEasing))
            then()
        }
    }
    BackHandler { close(onDismiss) }

    // слой поверх всего экрана чата (не отдельное окно): всегда во весь экран, закрывает и поле
    // ввода; само меню — в видимой части над клавиатурой. Фокус не трогает — клавиатура как была
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val density = LocalDensity.current
        val anchor = target.anchor
        val panelsWidth = if (withReactions) BarWidth else ActionsWidth
        // место считаем по большей высоте (ряд + действия или раскрытая сетка): раскрытие
        // реакций не сдвигает меню — сетка начинается там же, где был ряд
        val collapsedHeight = if (withReactions) BarHeight + PanelGap + ActionHeight * actions.size else ActionHeight * actions.size
        val estimatedHeight = if (withReactions) maxOf(collapsedHeight, GridHeight) else collapsedHeight
        // меню — в видимой части: не под клавиатурой и не под системными панелями
        val topInset = WindowInsets.statusBars.getTop(density)
        val bottomInset = WindowInsets.ime.union(WindowInsets.navigationBars).getBottom(density)
        val margin = 8.dp
        val offset = with(density) {
            val w = panelsWidth.toPx()
            val h = estimatedHeight.toPx()
            val m = margin.toPx()
            val x = (if (msg.isMine) anchor.x - w else anchor.x).coerceIn(m, (constraints.maxWidth - w - m).coerceAtLeast(m))
            val y = anchor.y.coerceIn(topInset + m, (constraints.maxHeight - bottomInset - h - m).coerceAtLeast(topInset + m))
            IntOffset(x.toInt(), y.toInt())
        }
        Box(
            Modifier.fillMaxSize().graphicsLayer { alpha = appear.value }.background(Color.Black.copy(alpha = 0.25f))
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { close(onDismiss) },
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
            // действия — по центру под рядом реакций (без реакций панель одна — выравнивать не с чем)
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            if (withReactions) {
                val shape = RoundedCornerShape(if (expanded) 18.dp else 50.dp)
                Box(
                    Modifier.width(BarWidth).shadow(6.dp, shape).clip(shape).background(colors.surface)
                        .animateContentSize(tween(260)),
                ) {
                    if (expanded) {
                        ReactionGrid(emojis, msg.myReaction, { e -> close { onReaction(e) } }, onCollapse = { expanded = false })
                    } else {
                        ReactionRow(emojis.take(RowEmojis + 1), msg.myReaction, { e -> close { onReaction(e) } }, onExpand = { expanded = true })
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
                            Modifier.fillMaxWidth().height(ActionHeight).clickable { close { onAction(item.action) } }.padding(horizontal = 16.dp),
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

/**
 * Ряд реакций: шесть эмодзи и стрелка. Повести пальцем справа налево — ряд
 * тянется, как резина (чем дальше, тем туже, и сам ряд чуть растягивается
 * влево), и из-под стрелки выезжает седьмой эмодзи. Выехал целиком —
 * короткая вибрация: отпустишь — раскроется сетка всех эмодзи (действия
 * прячутся). Пока палец на экране, жест обратим; отпустили раньше — ряд
 * пружинисто возвращается.
 */
@Composable
private fun ReactionRow(emojis: List<String>, myReaction: String?, onReaction: (String) -> Unit, onExpand: () -> Unit) {
    val colors = LocalAppColors.current
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    val cellPx = with(LocalDensity.current) { EmojiCell.toPx() }
    // палец прошёл [drag]; ряд сдвинут на [pull] — с нарастающим сопротивлением, как резина
    var drag by remember { mutableFloatStateOf(0f) }
    val pull = remember { Animatable(0f) }
    var armed by remember { mutableStateOf(false) }
    fun rubber(d: Float): Float = RubberLimit * cellPx * (1f - exp(-d / (RubberStiffness * cellPx)))
    fun release() {
        drag = 0f
        scope.launch {
            if (armed) onExpand() else pull.animateTo(0f, spring(dampingRatio = 0.45f, stiffness = 420f))
            armed = false
        }
    }
    Box(
        Modifier.width(BarWidth).height(BarHeight)
            // ряд немного растягивается влево вслед за пальцем — "резина"
            .graphicsLayer {
                scaleX = 1f + (pull.value / cellPx) * 0.06f
                transformOrigin = TransformOrigin(1f, 0.5f)
            }
            .pointerInput(Unit) {
                detectHorizontalDragGestures(onDragEnd = ::release, onDragCancel = ::release) { change, dx ->
                    change.consume()
                    drag = (drag - dx).coerceAtLeast(0f)
                    val p = rubber(drag)
                    val nowArmed = p >= cellPx
                    if (nowArmed && !armed) haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
                    armed = nowArmed
                    scope.launch { pull.snapTo(p) }
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

/** Насколько (в ячейках) ряд можно оттянуть резиной и как туго: чем меньше, тем раньше упирается. */
private const val RubberLimit = 1.4f
private const val RubberStiffness = 1.2f

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
