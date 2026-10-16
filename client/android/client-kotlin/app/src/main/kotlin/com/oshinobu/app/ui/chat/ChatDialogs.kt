package com.oshinobu.app.ui.chat

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.LocalMinimumInteractiveComponentSize
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import com.oshinobu.app.R
import com.oshinobu.app.ui.ErrorLine
import com.oshinobu.app.ui.ErrorRed
import com.oshinobu.app.ui.PeerAvatar
import com.oshinobu.app.ui.errorText
import com.oshinobu.app.ui.home.AppDialog
import com.oshinobu.app.ui.home.DialogButton
import com.oshinobu.app.ui.theme.CardShape
import com.oshinobu.app.ui.theme.LocalAppColors

/**
 * Удаление сообщений: компактная карточка — вопрос, по центру галочка "и у
 * собеседника" (только если хотя бы одно из них до него дошло — иначе
 * удалять там нечего), внизу "Отмена" слева и "Удалить" справа. Окно без
 * фокуса, как меню сообщения: клавиатура остаётся как была (обычный диалог
 * забирал фокус — она пряталась, а после удаления выскакивала обратно).
 */
@Composable
fun DeleteMessagesDialog(
    peerName: String,
    peerAccountId: String,
    showPeerCheckbox: Boolean,
    onDismiss: () -> Unit,
    onConfirm: (alsoForPeer: Boolean) -> Unit,
) {
    val colors = LocalAppColors.current
    var alsoForPeer by remember { mutableStateOf(false) }
    val appear = remember { Animatable(0f) }
    LaunchedEffect(Unit) { appear.animateTo(1f, tween(160, easing = FastOutSlowInEasing)) }
    BackHandler(onBack = onDismiss)
    Popup(popupPositionProvider = WindowOrigin, properties = MenuWindowProperties) {
        Box(
            Modifier.fillMaxSize().graphicsLayer { alpha = appear.value }.background(Color.Black.copy(alpha = 0.4f))
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss),
            contentAlignment = Alignment.Center,
        ) {
            Column(
                Modifier
                    .graphicsLayer {
                        scaleX = 0.9f + 0.1f * appear.value
                        scaleY = 0.9f + 0.1f * appear.value
                    }
                    .padding(horizontal = 32.dp).widthIn(max = 320.dp)
                    .shadow(8.dp, CardShape).clip(CardShape).background(colors.surface)
                    // тап по карточке — не "мимо"
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
                    .padding(horizontal = 16.dp, vertical = 16.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(stringResource(R.string.deleteMessage_title), color = colors.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                if (showPeerCheckbox) {
                    Spacer(Modifier.height(8.dp))
                    Row(
                        Modifier.clip(RoundedCornerShape(8.dp)).clickable { alsoForPeer = !alsoForPeer }.padding(horizontal = 4.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        CompositionLocalProvider(LocalMinimumInteractiveComponentSize provides 0.dp) {
                            Checkbox(alsoForPeer, { alsoForPeer = it }, colors = CheckboxDefaults.colors(checkedColor = colors.primary))
                        }
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(R.string.deleteMessage_alsoForPeer), color = colors.textPrimary, fontSize = 15.sp)
                        Spacer(Modifier.width(6.dp))
                        PeerAvatar(peerAccountId, 20.dp)
                        Spacer(Modifier.width(4.dp))
                        Text(
                            peerName, color = colors.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false),
                        )
                    }
                }
                Spacer(Modifier.height(14.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedButton(
                        onClick = onDismiss, modifier = Modifier.weight(1f).height(44.dp), shape = CardShape,
                        border = BorderStroke(1.dp, colors.primary),
                    ) { Text(stringResource(R.string.common_cancel), color = colors.primary, fontWeight = FontWeight.SemiBold) }
                    OutlinedButton(
                        onClick = { onConfirm(showPeerCheckbox && alsoForPeer) }, modifier = Modifier.weight(1f).height(44.dp), shape = CardShape,
                        border = BorderStroke(1.dp, ErrorRed),
                    ) { Text(stringResource(R.string.action_delete), color = ErrorRed, fontWeight = FontWeight.SemiBold) }
                }
            }
        }
    }
}

/** Подтверждение ручного сброса шифрования с собеседником. */
@Composable
fun ResetSessionDialog(onDismiss: () -> Unit, onConfirm: () -> Unit) {
    val colors = LocalAppColors.current
    AppDialog(
        stringResource(R.string.chat_resetSessionTitle),
        onDismiss,
        confirm = { DialogButton(stringResource(R.string.chat_resetSessionConfirm), onClick = onConfirm) },
        dismiss = { DialogButton(stringResource(R.string.common_cancel), onClick = onDismiss) },
    ) { Text(stringResource(R.string.chat_resetSessionBody), color = colors.textMuted) }
}

/**
 * Жалоба на сообщение. Сервер не видит переписку — текст сообщения уходит
 * вместе с жалобой добровольно, по решению пользователя.
 */
@Composable
fun ReportDialog(onDismiss: () -> Unit, onSend: (comment: String, onDone: (Throwable?) -> Unit) -> Unit, onSent: () -> Unit) {
    val context = LocalContext.current
    val colors = LocalAppColors.current
    var comment by remember { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    AppDialog(
        stringResource(R.string.report_title),
        onDismiss,
        confirm = {
            DialogButton(stringResource(R.string.common_send)) {
                if (sending) return@DialogButton
                sending = true
                error = null
                onSend(comment.trim()) { e ->
                    sending = false
                    if (e == null) onSent() else error = context.errorText(e)
                }
            }
        },
        dismiss = { DialogButton(stringResource(R.string.common_cancel), onClick = onDismiss) },
    ) {
        Column {
            OutlinedTextField(
                comment, { comment = it },
                placeholder = { Text(stringResource(R.string.report_commentHint), color = colors.textMuted) },
                minLines = 2, maxLines = 5, modifier = Modifier.fillMaxWidth(),
            )
            ErrorLine(error)
        }
    }
}
