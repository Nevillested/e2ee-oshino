package com.oshinobu.app.ui.home

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.outlined.Call
import androidx.compose.material.icons.outlined.EmojiEmotions
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.ui.PeerAvatar
import com.oshinobu.app.ui.chat.BubbleShape
import com.oshinobu.app.ui.chat.HeaderPill
import com.oshinobu.app.ui.chat.MetaRow
import com.oshinobu.app.ui.chat.PillIcon
import com.oshinobu.app.ui.chat.bubble
import com.oshinobu.app.ui.chat.bubbleText
import com.oshinobu.app.ui.theme.AppColors
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.storage.MessageStatus
import com.oshinobu.core.storage.StoredMessage
import java.util.Calendar

/**
 * "Тема" из настроек: экран, который выглядит как переписка с воображаемым
 * Бобом, а снизу — ряд тем. Тап по теме сразу перекрашивает всё приложение,
 * и эту переписку тоже — видно, как будет выглядеть чат, не выходя из настроек.
 */
@Composable
fun ThemeScreen(onBack: () -> Unit) {
    val app = LocalContext.current.app
    val colors = LocalAppColors.current
    val current by app.theme.collectAsState()
    Column(Modifier.fillMaxSize().background(colors.chatBackground)) {
        PreviewHeader(onBack)
        PreviewMessages(Modifier.weight(1f))
        PreviewComposer()
        LazyRow(
            Modifier.fillMaxWidth().background(colors.surface).navigationBarsPadding(),
            contentPadding = PaddingValues(horizontal = 14.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(AppColors.All, key = { it.id }) { theme ->
                ThemeTile(theme, selected = theme.id == current.id) { app.setTheme(theme) }
            }
        }
    }
}

/** Шапка как в чате: назад (работает), Боб "в сети", звонок и меню (для вида). */
@Composable
private fun PreviewHeader(onBack: () -> Unit) {
    val colors = LocalAppColors.current
    Row(Modifier.statusBarsPadding().padding(start = 12.dp, end = 12.dp, top = 8.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        HeaderPill {
            Row {
                PillIcon(Icons.AutoMirrored.Filled.ArrowBack, onClick = onBack)
                PillIcon(Icons.Filled.SwapVert) {}
            }
        }
        Spacer(Modifier.width(8.dp))
        Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
            HeaderPill {
                Row(Modifier.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    PeerAvatar(null, 32.dp)
                    Spacer(Modifier.width(8.dp))
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(stringResource(R.string.themePreview_peerName), color = colors.textPrimary, fontWeight = FontWeight.Medium)
                        Text(stringResource(R.string.presence_online), fontSize = 12.sp, color = colors.textPrimary.copy(alpha = 0.7f))
                    }
                }
            }
        }
        Spacer(Modifier.width(8.dp))
        HeaderPill {
            Row {
                PillIcon(Icons.Outlined.Call) {}
                PillIcon(Icons.Filled.MoreVert) {}
            }
        }
    }
}

/** Восемь сообщений, по очереди — от Боба и ему; время — сегодняшнее утро. */
@Composable
private fun PreviewMessages(modifier: Modifier) {
    val texts = listOf(
        R.string.themePreview_msg1, R.string.themePreview_msg2, R.string.themePreview_msg3, R.string.themePreview_msg4,
        R.string.themePreview_msg5, R.string.themePreview_msg6, R.string.themePreview_msg7, R.string.themePreview_msg8,
    ).map { stringResource(it) }
    val messages = remember(texts) {
        val start = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 10)
            set(Calendar.MINUTE, 12)
        }.timeInMillis
        texts.mapIndexed { i, text ->
            StoredMessage(
                "preview-$i", text, isMine = i % 2 == 1, timestamp = start + i * 60_000L,
                status = if (i == texts.lastIndex) MessageStatus.SENT else MessageStatus.READ,
            )
        }
    }
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.Bottom) {
        messages.forEach { PreviewBubble(it) }
        Spacer(Modifier.size(8.dp))
    }
}

/** Пузырь — те же форма, цвета и строка времени, что в настоящем чате. */
@Composable
private fun PreviewBubble(msg: StoredMessage) {
    val colors = LocalAppColors.current
    Box(Modifier.fillMaxWidth().padding(vertical = 2.dp), contentAlignment = if (msg.isMine) Alignment.CenterEnd else Alignment.CenterStart) {
        Column(
            Modifier.padding(vertical = 4.dp).widthIn(max = 280.dp).background(colors.bubble(msg.isMine), BubbleShape)
                .padding(horizontal = 14.dp, vertical = 10.dp),
            horizontalAlignment = Alignment.End,
        ) {
            Text(msg.text, color = colors.bubbleText(msg.isMine), fontSize = 16.sp, modifier = Modifier.align(Alignment.Start))
            Spacer(Modifier.size(4.dp))
            MetaRow(msg)
        }
    }
}

/** Поле ввода — для вида. */
@Composable
private fun PreviewComposer() {
    val colors = LocalAppColors.current
    Row(
        Modifier.padding(horizontal = 6.dp, vertical = 4.dp).fillMaxWidth().background(colors.surface, RoundedCornerShape(24.dp))
            .heightIn(min = 52.dp).padding(start = 10.dp, end = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Outlined.EmojiEmotions, null, tint = colors.textMuted)
        Spacer(Modifier.width(12.dp))
        Text(stringResource(R.string.chat_messageHint), color = colors.textMuted, fontSize = 16.sp, modifier = Modifier.weight(1f))
        Icon(Icons.Filled.AttachFile, null, tint = colors.textMuted)
        Spacer(Modifier.width(16.dp))
        Icon(Icons.Outlined.Mic, null, tint = colors.textMuted)
    }
}

/**
 * Плитка темы — крошечная переписка в её цветах (фон, чужой и свой пузырь,
 * полоска поля ввода) и название под ней; выбранная — в рамке акцента текущей темы.
 */
@Composable
private fun ThemeTile(theme: AppColors, selected: Boolean, onClick: () -> Unit) {
    val colors = LocalAppColors.current
    val shape = RoundedCornerShape(14.dp)
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.width(78.dp).clip(shape).clickable(onClick = onClick)) {
        Column(
            Modifier.size(78.dp, 104.dp)
                .border(if (selected) 3.dp else 1.dp, if (selected) colors.primary else colors.textMuted.copy(alpha = 0.35f), shape)
                .padding(if (selected) 3.dp else 1.dp).clip(RoundedCornerShape(11.dp)).background(theme.chatBackground)
                .padding(7.dp),
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Box(Modifier.width(40.dp).height(12.dp).background(theme.surface, RoundedCornerShape(6.dp)))
            Box(Modifier.align(Alignment.End).width(46.dp).height(12.dp).background(theme.bubbleMine, RoundedCornerShape(6.dp)))
            Box(Modifier.width(32.dp).height(12.dp).background(theme.surface, RoundedCornerShape(6.dp)))
            Spacer(Modifier.weight(1f))
            Row(
                Modifier.fillMaxWidth().height(14.dp).background(theme.surface, RoundedCornerShape(7.dp)).padding(horizontal = 5.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Spacer(Modifier.weight(1f))
                Box(Modifier.size(6.dp).background(theme.primary, RoundedCornerShape(3.dp)))
            }
        }
        Text(
            stringResource(theme.title), color = if (selected) colors.primary else colors.textPrimary, fontSize = 12.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal, textAlign = TextAlign.Center, maxLines = 2,
            modifier = Modifier.padding(top = 6.dp, bottom = 2.dp),
        )
    }
}
