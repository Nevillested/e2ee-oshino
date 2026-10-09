package com.oshinobu.app.ui.chat

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CallMade
import androidx.compose.material.icons.automirrored.filled.CallMissed
import androidx.compose.material.icons.automirrored.filled.CallReceived
import androidx.compose.material.icons.filled.Done
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasurePolicy
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.oshinobu.app.R
import com.oshinobu.app.ui.theme.AppColors
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.format.formatChatTime
import com.oshinobu.core.storage.MessageStatus
import com.oshinobu.core.storage.StoredMessage

val BubbleShape = RoundedCornerShape(14.dp)
private val ReplyAccent = Color(0xFFFFC04D)

fun AppColors.bubble(isMine: Boolean): Color = if (isMine) primary else surface
fun AppColors.bubbleText(isMine: Boolean): Color = if (isMine) Color.White else textPrimary
fun AppColors.bubbleMuted(isMine: Boolean): Color = if (isMine) Color.White.copy(alpha = 0.7f) else textMuted

/** Ссылка заметна и на своём (синем), и на чужом пузыре. */
private fun linkColor(isMine: Boolean) = if (isMine) Color(0xFFFFD54F) else Color(0xFF2AABEE)

/** Как у большинства мессенджеров: от http(s):// или www. до ближайшего пробела. */
private val UrlRegex = Regex("""((https?://)|(www\.))\S+""", RegexOption.IGNORE_CASE)

/** Текст со ссылками-кнопками (открываются во внешнем приложении). */
fun linkified(text: String, isMine: Boolean): AnnotatedString = buildAnnotatedString {
    var cursor = 0
    for (m in UrlRegex.findAll(text)) {
        append(text.substring(cursor, m.range.first))
        val url = m.value
        val target = if (url.startsWith("http", ignoreCase = true)) url else "https://$url"
        withLink(LinkAnnotation.Url(target, TextLinkStyles(SpanStyle(color = linkColor(isMine))))) { append(url) }
        cursor = m.range.last + 1
    }
    append(text.substring(cursor))
}

@Composable
fun StatusIcon(status: String, onColoredBubble: Boolean = true) {
    val colors = LocalAppColors.current
    val mod = Modifier.size(13.dp)
    when (status) {
        MessageStatus.FAILED -> Icon(Icons.Filled.ErrorOutline, null, mod, tint = Color(0xFFFF5252))
        MessageStatus.SENDING, MessageStatus.QUEUED ->
            Icon(Icons.Filled.Schedule, null, mod, tint = if (onColoredBubble) Color.White.copy(alpha = 0.7f) else colors.textMuted)
        MessageStatus.READ -> Icon(Icons.Filled.DoneAll, null, mod, tint = Color.White)
        else -> Icon(Icons.Filled.Done, null, mod, tint = Color(0xFF40C4FF))
    }
}

/** Время, отметка правки и статус доставки. [onColoredBubble] = false — для видео-кружков (лежат прямо на фоне). */
@Composable
fun MetaRow(msg: StoredMessage, onColoredBubble: Boolean = true, status: String = msg.status, timestamp: Long = msg.timestamp) {
    val colors = LocalAppColors.current
    val muted = if (onColoredBubble) colors.bubbleMuted(msg.isMine) else colors.textMuted
    Row(verticalAlignment = Alignment.CenterVertically) {
        if (msg.edited) {
            Icon(Icons.Filled.Edit, null, Modifier.size(11.dp), tint = muted)
            Spacer(Modifier.width(3.dp))
        }
        Text(formatChatTime(timestamp), color = muted, fontSize = 10.sp)
        if (msg.isMine) {
            Spacer(Modifier.width(4.dp))
            StatusIcon(status, onColoredBubble)
        }
    }
}

/**
 * Текст и метаданные (время/статус) в одном блоке: если на последней строке
 * текста хватает места — метаданные встают туда же, иначе — отдельной
 * строкой справа снизу (как в Telegram/WhatsApp).
 */
@Composable
fun TextWithMeta(text: AnnotatedString, color: Color, maxWidth: Dp, meta: @Composable () -> Unit) {
    val layoutRef = remember { arrayOfNulls<TextLayoutResult>(1) }
    val policy = remember {
        object : MeasurePolicy {
            override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
                val textP = measurables[0].measure(constraints.copy(minWidth = 0))
                val metaP = measurables[1].measure(constraints.copy(minWidth = 0))
                val gap = 6.dp.roundToPx()
                val layout = layoutRef[0]
                val lastLine = (layout?.lineCount ?: 1) - 1
                val lastLineWidth = layout?.let { (it.getLineRight(lastLine) - it.getLineLeft(lastLine)).toInt() } ?: textP.width
                val lineBottom = layout?.getLineBottom(lastLine)?.toInt() ?: textP.height
                val fitsInline = lastLineWidth + gap + metaP.width <= constraints.maxWidth
                val width = (if (fitsInline) maxOf(textP.width, lastLineWidth + gap + metaP.width) else maxOf(textP.width, metaP.width))
                    .coerceIn(constraints.minWidth, constraints.maxWidth)
                val height = if (fitsInline) maxOf(textP.height, lineBottom) else textP.height + metaP.height
                return layout(width, height) {
                    textP.place(0, 0)
                    val metaY = if (fitsInline) lineBottom - metaP.height - 2.dp.roundToPx() else textP.height
                    metaP.place(width - metaP.width, metaY.coerceAtLeast(0))
                }
            }

            // ширина "по содержимому": текст одной строкой плюс метаданные (родитель обрежет до максимума)
            override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
                measurables[0].maxIntrinsicWidth(height) + 6.dp.roundToPx() + measurables[1].maxIntrinsicWidth(height)

            override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
                maxOf(measurables[0].minIntrinsicWidth(height), measurables[1].minIntrinsicWidth(height))
        }
    }
    Layout(
        content = {
            Text(text, color = color, fontSize = 16.sp, onTextLayout = { layoutRef[0] = it })
            Box { meta() }
        },
        modifier = Modifier.widthIn(max = maxWidth),
        measurePolicy = policy,
    )
}

/** Нейтральный ряд по центру — для записей о звонках и заглушек нерасшифрованных сообщений. */
@Composable
private fun CenteredNotice(icon: @Composable () -> Unit, text: String, timestamp: Long, italic: Boolean = false) {
    val colors = LocalAppColors.current
    Box(Modifier.padding(vertical = 4.dp, horizontal = 16.dp), contentAlignment = Alignment.Center) {
        Row(
            Modifier.background(colors.surface, BubbleShape).padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            icon()
            Spacer(Modifier.width(6.dp))
            Text(
                text,
                color = colors.textPrimary,
                fontStyle = if (italic) FontStyle.Italic else FontStyle.Normal,
                modifier = Modifier.weight(1f, fill = false),
            )
            Spacer(Modifier.width(6.dp))
            Text(formatChatTime(timestamp), color = colors.textMuted, fontSize = 10.sp)
        }
    }
}

private fun formatCallDuration(seconds: Long) = "${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')}"

/** Запись о звонке — факт, касающийся обоих, поэтому по центру, а не пузырём одной из сторон. */
@Composable
fun CallLogRow(msg: StoredMessage) {
    val colors = LocalAppColors.current
    val outgoing = msg.callDirection == "outgoing"
    val (icon, label) = when (msg.callOutcome) {
        "answered" -> (if (outgoing) Icons.AutoMirrored.Filled.CallMade else Icons.AutoMirrored.Filled.CallReceived) to
            "${stringResource(R.string.call_answered)} · ${formatCallDuration(msg.callDurationSeconds ?: 0)}"
        "missed" -> Icons.AutoMirrored.Filled.CallMissed to stringResource(R.string.call_missed)
        else -> Icons.AutoMirrored.Filled.CallMade to stringResource(R.string.call_noAnswer)
    }
    val bad = msg.callOutcome == "missed" || msg.callOutcome == "no_answer"
    CenteredNotice(
        icon = { Icon(icon, null, Modifier.size(16.dp), tint = if (bad) Color(0xFFFF5252) else colors.textMuted) },
        text = label,
        timestamp = msg.timestamp,
    )
}

/** Заглушка на месте сообщения, которое окончательно не удалось расшифровать; без меню. */
@Composable
fun UndecryptableRow(msg: StoredMessage, peerName: String) {
    val colors = LocalAppColors.current
    CenteredNotice(
        icon = { Icon(Icons.Outlined.Lock, null, Modifier.size(16.dp), tint = colors.textMuted) },
        text = stringResource(R.string.chat_undecryptable, peerName),
        timestamp = msg.timestamp,
        italic = true,
    )
}

/**
 * Цитата внутри пузыря (стиль Telegram): своя подложка, полоска слева,
 * сверху — чьё сообщение, ниже — сама цитата. Оригинал удалён — фиксированная
 * надпись, тап ничего не делает; иначе тап переносит к оригиналу.
 */
@Composable
fun ReplyPreview(msg: StoredMessage, original: StoredMessage?, peerName: String, onJump: (String) -> Unit) {
    val preview = msg.replyToPreview ?: return
    val colors = LocalAppColors.current
    val muted = colors.bubbleMuted(msg.isMine)
    Column(
        Modifier
            .padding(bottom = 6.dp)
            .background(Color.Black.copy(alpha = 0.16f), RoundedCornerShape(6.dp))
            .drawBehind { drawRect(muted, size = size.copy(width = 3.dp.toPx())) }
            .then(if (original != null) Modifier.clickable { onJump(original.messageId) } else Modifier)
            .padding(start = 11.dp, end = 8.dp, top = 4.dp, bottom = 4.dp),
    ) {
        if (original != null) {
            Text(
                if (original.isMine) stringResource(R.string.chat_replyYou) else peerName,
                color = ReplyAccent, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        Text(
            if (original == null) stringResource(R.string.chat_replyDeleted) else preview,
            color = muted, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis,
            fontStyle = if (original == null) FontStyle.Italic else FontStyle.Normal,
        )
    }
}

/**
 * Реакции — раздельно: своя (рамка акцентом) и собеседника (приглушённая).
 * Появление/смена — с "хлопком"; [justChanged] — только что поставленная.
 */
@Composable
fun ReactionBadges(myReaction: String?, peerReaction: String?, justChanged: Boolean) {
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        ReactionChip(myReaction, mine = true, justChanged)
        ReactionChip(peerReaction, mine = false, justChanged)
    }
}

@Composable
private fun ReactionChip(emoji: String?, mine: Boolean, justChanged: Boolean) {
    val colors = LocalAppColors.current
    val pop = remember { Animatable(1f) }
    LaunchedEffect(justChanged, emoji) {
        if (justChanged && emoji != null) {
            pop.snapTo(1.35f)
            pop.animateTo(1f, spring(dampingRatio = Spring.DampingRatioMediumBouncy, stiffness = Spring.StiffnessMedium))
        }
    }
    AnimatedContent(
        targetState = emoji,
        transitionSpec = { (scaleIn(tween(220)) + fadeIn(tween(220))) togetherWith (scaleOut(tween(160)) + fadeOut(tween(160))) },
        label = "reaction",
    ) { e ->
        if (e != null) {
            Text(
                e,
                fontSize = 13.sp,
                modifier = Modifier
                    .scale(pop.value)
                    .background(colors.surface, RoundedCornerShape(10.dp))
                    .border(1.dp, if (mine) colors.primary else colors.textMuted.copy(alpha = 0.4f), RoundedCornerShape(10.dp))
                    .padding(horizontal = 5.dp, vertical = 1.dp),
            )
        }
    }
}

/** Плашка размера поверх плитки медиа (левый нижний угол). */
@Composable
fun SizePlaque(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        color = Color.White,
        fontSize = 10.sp,
        fontWeight = FontWeight.Medium,
        modifier = modifier.background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(6.dp)).padding(horizontal = 5.dp, vertical = 2.dp),
    )
}
