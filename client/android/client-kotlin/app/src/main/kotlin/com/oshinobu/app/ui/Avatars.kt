package com.oshinobu.app.ui

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Person
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
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import com.oshinobu.app.app
import com.oshinobu.app.ui.theme.LocalAppColors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.withContext

/** JPEG/PNG-байты → картинка (декодирование вне главного потока). */
@Composable
fun rememberImage(bytes: ByteArray?): ImageBitmap? {
    val image by produceState<ImageBitmap?>(null, bytes) {
        value = bytes?.let { b -> withContext(Dispatchers.Default) { BitmapFactory.decodeByteArray(b, 0, b.size)?.asImageBitmap() } }
    }
    return image
}

/** Круглый аватар из байтов; нет картинки — силуэт на поверхности. */
@Composable
fun AvatarImage(bytes: ByteArray?, size: Dp, modifier: Modifier = Modifier) {
    val colors = LocalAppColors.current
    val image = rememberImage(bytes)
    Box(modifier.size(size).clip(CircleShape).background(colors.surface), contentAlignment = Alignment.Center) {
        if (image != null) {
            Image(image, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.size(size))
        } else {
            Icon(Icons.Filled.Person, contentDescription = null, tint = colors.textMuted, modifier = Modifier.size(size * 0.6f))
        }
    }
}

/** Аватар собеседника по account_id: сразу из памяти/диска, затем — обновление с сервера. */
@Composable
fun PeerAvatar(accountId: String?, size: Dp, modifier: Modifier = Modifier) {
    val avatars = LocalContext.current.app.core.avatars
    var bytes by remember(accountId) { mutableStateOf(accountId?.let { avatars.peek(it) }) }
    LaunchedEffect(accountId) {
        if (accountId.isNullOrEmpty()) return@LaunchedEffect
        bytes = avatars.get(accountId)
        avatars.changes.filter { it == accountId }.collect { bytes = avatars.get(accountId) }
    }
    AvatarImage(bytes, size, modifier)
}

/** Отображаемое имя собеседника (display_name из профиля), пока не загрузилось — логин. */
@Composable
fun PeerName(accountId: String?, login: String, style: TextStyle, modifier: Modifier = Modifier) {
    Text(rememberPeerDisplayName(accountId, login), style = style, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = modifier)
}

@Composable
fun rememberPeerDisplayName(accountId: String?, login: String): String {
    val profiles = LocalContext.current.app.core.peerProfiles
    var name by remember(accountId, login) { mutableStateOf(accountId?.let { profiles.peek(it)?.displayName } ?: login) }
    LaunchedEffect(accountId, login) {
        if (accountId.isNullOrEmpty()) return@LaunchedEffect
        profiles.get(accountId, login)?.let { name = it.displayName }
        profiles.changes.filter { it == accountId }.collect {
            name = profiles.get(accountId, login)?.displayName ?: login
        }
    }
    return name
}
