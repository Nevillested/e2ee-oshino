package com.oshinobu.app.ui.chat

import androidx.activity.compose.BackHandler
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.oshinobu.app.R
import com.oshinobu.app.ui.emoji.allEmojis
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.storage.MessageStatus
import com.oshinobu.core.storage.StoredMessage

enum class MessageAction { REPLY, COPY, PIN, UNPIN, FORWARD, EDIT, SELECT, DELETE, REPORT, CANCEL_SEND, RETRY_SEND }

/** Открытое контекстное меню: сообщение (или представитель группы), её id и точка тапа в координатах экрана чата. */
data class MenuTarget(val msg: StoredMessage, val groupIds: List<String>, val anchor: Offset, val groupStatus: String?)

private val CellSize = 47.dp
private const val Columns = 5
private val MenuWidth = CellSize * Columns
private val ActionHeight = 44.dp
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
    LaunchedEffect(Unit) { appear.animateTo(1f, tween(160, easing = FastOutSlowInEasing)) }
    BackHandler(onBack = onDismiss)

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val density = LocalDensity.current
        val estimatedHeight = (if (withReactions) CellSize else 0.dp) + ActionHeight * actions.size
        val margin = 8.dp
        val offset = with(density) {
            val w = MenuWidth.toPx()
            val h = (if (expanded) CellSize * 6 else estimatedHeight).toPx()
            val m = margin.toPx()
            val x = (if (msg.isMine) target.anchor.x - w else target.anchor.x).coerceIn(m, (constraints.maxWidth - w - m).coerceAtLeast(m))
            val y = target.anchor.y.coerceIn(m, (constraints.maxHeight - h - m).coerceAtLeast(m))
            IntOffset(x.toInt(), y.toInt())
        }
        Box(
            Modifier.fillMaxSize().graphicsLayer { alpha = appear.value }.background(Color.Black.copy(alpha = 0.25f))
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss),
        )
        Column(
            Modifier
                .offset { offset }
                .graphicsLayer {
                    alpha = appear.value
                    scaleX = 0.85f + 0.15f * appear.value
                    scaleY = 0.85f + 0.15f * appear.value
                    transformOrigin = TransformOrigin(if (msg.isMine) 1f else 0f, 0f)
                }
                .width(MenuWidth)
                .clip(RoundedCornerShape(16.dp))
                .background(colors.surface)
                .animateContentSize(tween(260)),
        ) {
            if (withReactions) {
                Box(Modifier.fillMaxWidth().height(if (expanded) CellSize * 6 else CellSize)) {
                    LazyVerticalGrid(GridCells.Fixed(Columns), userScrollEnabled = expanded) {
                        items(emojis) { emoji ->
                            Box(
                                Modifier.size(CellSize).padding(3.dp).clip(CircleShape)
                                    .background(if (emoji == msg.myReaction) colors.primary.copy(alpha = 0.25f) else Color.Transparent)
                                    .clickable { onReaction(emoji) },
                                contentAlignment = Alignment.Center,
                            ) { Text(emoji, fontSize = 23.sp) }
                        }
                    }
                    Box(
                        Modifier.align(Alignment.TopEnd).size(CellSize).background(colors.surface).clickable { expanded = !expanded },
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(if (expanded) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown, null, tint = colors.textMuted)
                    }
                }
            }
            if (!expanded) {
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
