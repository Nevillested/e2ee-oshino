package com.oshinobu.app.ui.chat

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.oshinobu.app.R
import com.oshinobu.app.ui.ErrorLine
import com.oshinobu.app.ui.ErrorRed
import com.oshinobu.app.ui.PeerAvatar
import com.oshinobu.app.ui.errorText
import com.oshinobu.app.ui.home.AppDialog
import com.oshinobu.app.ui.home.DialogButton
import com.oshinobu.app.ui.theme.LocalAppColors

/**
 * Удаление сообщений. Галочка "и у собеседника" — только если хотя бы одно
 * из них до него дошло (иначе удалять там нечего).
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
    AppDialog(
        stringResource(R.string.deleteMessage_title),
        onDismiss,
        confirm = { DialogButton(stringResource(R.string.action_delete), ErrorRed) { onConfirm(showPeerCheckbox && alsoForPeer) } },
        dismiss = { DialogButton(stringResource(R.string.common_cancel), onClick = onDismiss) },
    ) {
        if (showPeerCheckbox) {
            Row(Modifier.fillMaxWidth().clickable { alsoForPeer = !alsoForPeer }, verticalAlignment = Alignment.CenterVertically) {
                Checkbox(alsoForPeer, { alsoForPeer = it }, colors = CheckboxDefaults.colors(checkedColor = colors.primary))
                Text(stringResource(R.string.deleteMessage_alsoForPeer), color = colors.textPrimary)
                Spacer(Modifier.width(6.dp))
                PeerAvatar(peerAccountId, 20.dp)
                Spacer(Modifier.width(4.dp))
                Text(peerName, color = colors.textPrimary, fontWeight = FontWeight.SemiBold)
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
