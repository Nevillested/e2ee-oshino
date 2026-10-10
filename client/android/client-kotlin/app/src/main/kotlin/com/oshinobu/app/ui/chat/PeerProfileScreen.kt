package com.oshinobu.app.ui.chat

import com.oshinobu.app.ui.AppLoadingIndicator
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Badge
import androidx.compose.material.icons.outlined.Cake
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.ui.PeerAvatar
import com.oshinobu.app.ui.PhotoViewerDialog
import com.oshinobu.app.ui.home.ProfileRow
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.service.PeerProfile
import kotlinx.coroutines.flow.filter

/** Профиль собеседника: аватар (тап — на весь экран), логин, имя, о себе, день рождения. */
@Composable
fun PeerProfileScreen(accountId: String, login: String, onBack: () -> Unit) {
    val core = LocalContext.current.app.core
    val colors = LocalAppColors.current
    // профиль обновляется и пока экран открыт (изменил о себе, сняли блокировку)
    val profile by produceState<Result<PeerProfile?>?>(null, accountId) {
        value = runCatching { core.peerProfiles.get(accountId, login) }
        core.peerProfiles.changes.filter { it == accountId }.collect { value = runCatching { core.peerProfiles.get(accountId, login) } }
    }
    var viewing by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().background(colors.background).statusBarsPadding()) {
        IconButton(onClick = onBack, modifier = Modifier.padding(4.dp)) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, null, tint = colors.textPrimary)
        }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 8.dp)) {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                PeerAvatar(accountId, 128.dp, Modifier.clip(CircleShape).clickable { if (core.avatars.peek(accountId) != null) viewing = true })
            }
            Spacer(Modifier.height(24.dp))
            val loaded = profile
            if (loaded == null) {
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { AppLoadingIndicator(size = 32.dp, color = colors.primary) }
            } else {
                val p = loaded.getOrNull()
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    ProfileRow(Icons.Outlined.Badge, stringResource(R.string.profile_login), login)
                    ProfileRow(Icons.Outlined.Badge, stringResource(R.string.profile_displayName), p?.displayName ?: login)
                    p?.status?.takeIf { it.isNotEmpty() }?.let { ProfileRow(Icons.Outlined.ChatBubbleOutline, stringResource(R.string.profile_status), it) }
                    p?.birthday?.takeIf { it.isNotEmpty() }?.let { ProfileRow(Icons.Outlined.Cake, stringResource(R.string.profile_birthday), it) }
                }
            }
        }
    }
    if (viewing) core.avatars.peek(accountId)?.let { PhotoViewerDialog(it) { viewing = false } }
}
