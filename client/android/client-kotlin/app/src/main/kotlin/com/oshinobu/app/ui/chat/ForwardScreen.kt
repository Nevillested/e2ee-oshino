package com.oshinobu.app.ui.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.ui.FullScreenLoading
import com.oshinobu.app.ui.PeerAvatar
import com.oshinobu.app.ui.PeerName
import com.oshinobu.app.ui.home.ChatTarget
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.app.ui.translate
import com.oshinobu.core.storage.ChatStore
import com.oshinobu.core.storage.ChatSummary

/** Куда переслать: список чатов; выбор открывает чат с пересылаемым в поле ввода. */
@Composable
fun ForwardScreen(onBack: () -> Unit, onPick: (ChatTarget) -> Unit) {
    val context = LocalContext.current
    val colors = LocalAppColors.current
    val chats by produceState<List<ChatSummary>?>(null) { value = context.app.core.chats.getKnownPeers() }
    Column(Modifier.fillMaxSize().background(colors.background).statusBarsPadding()) {
        Row(Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, null, tint = colors.textPrimary) }
            Text(stringResource(R.string.forward_title), color = colors.textPrimary, fontSize = 20.sp)
        }
        val list = chats
        if (list == null) {
            FullScreenLoading()
            return@Column
        }
        LazyColumn(Modifier.fillMaxSize().navigationBarsPadding()) {
            items(list, key = { it.peerLogin }) { chat ->
                Row(
                    Modifier.fillMaxWidth().clickable {
                        onPick(ChatTarget(chat.peerLogin, chat.lastKnownAccountId.orEmpty(), chat.lastKnownDeviceId.orEmpty()))
                    }.padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    PeerAvatar(chat.lastKnownAccountId, 44.dp)
                    Spacer(Modifier.width(14.dp))
                    Column {
                        val style = TextStyle(color = colors.textPrimary, fontSize = 16.sp)
                        if (chat.isDeleted) Text(stringResource(R.string.home_deletedAccount), style = style)
                        else PeerName(chat.lastKnownAccountId, chat.peerLogin, style)
                        Text(
                            ChatStore.decodePreview(chat.lastMessage, context::translate),
                            color = colors.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
}
