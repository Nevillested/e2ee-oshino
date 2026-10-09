package com.oshinobu.app.ui.home

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Done
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.ui.AvatarImage
import com.oshinobu.app.ui.ErrorRed
import com.oshinobu.app.ui.PeerAvatar
import com.oshinobu.app.ui.PeerName
import com.oshinobu.app.ui.call.OngoingCallBanner
import com.oshinobu.app.ui.errorText
import com.oshinobu.app.ui.theme.CardShape
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.app.ui.translate
import com.oshinobu.core.format.formatChatTime
import com.oshinobu.core.net.ConnectionStatus
import com.oshinobu.core.optString
import com.oshinobu.core.storage.ChatStore
import com.oshinobu.core.storage.ChatSummary
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs

/** Открыть чат: логин, account_id и (последний известный) device_id собеседника. */
data class ChatTarget(val login: String, val accountId: String, val deviceId: String)

private enum class Tab { CHATS, SETTINGS, PROFILE }

/** Главный экран: три вкладки (чаты, настройки, профиль), поиск собеседника по логину. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    onSignedOut: () -> Unit,
    onOpenChat: (ChatTarget) -> Unit,
    onOpenTransfers: () -> Unit,
    onOpenCall: () -> Unit,
) {
    val core = LocalContext.current.app.core
    val colors = LocalAppColors.current
    RequestNotificationPermissions()
    var tab by rememberSaveable { mutableStateOf(Tab.CHATS) }
    var previousTab by remember { mutableStateOf(Tab.CHATS) }
    var searchOpen by rememberSaveable { mutableStateOf(false) }
    var searchQuery by rememberSaveable { mutableStateOf("") }

    fun selectTab(t: Tab) {
        if (t == tab) return
        searchOpen = false
        searchQuery = ""
        previousTab = tab
        tab = t
    }

    // вошли с этим аккаунтом на другом устройстве — сессия здесь больше не действует
    LaunchedEffect(Unit) {
        core.ws.sessionInvalidated.collect {
            core.signOutLocally()
            onSignedOut()
        }
    }
    ForegroundStateReporter()

    BackHandler(enabled = searchOpen || tab != Tab.CHATS) {
        if (searchOpen) searchOpen = false else selectTab(Tab.CHATS)
    }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            Column {
                when (tab) {
                    Tab.CHATS -> TopAppBar(
                        title = {
                            // статус подключения; поиск вырастает справа поверх него
                            AnimatedContent(
                                searchOpen,
                                transitionSpec = {
                                    (fadeIn() + expandHorizontally(expandFrom = Alignment.End)) togetherWith
                                        (fadeOut() + shrinkHorizontally(shrinkTowards = Alignment.End))
                                },
                                label = "homeTitle",
                            ) { open -> if (open) SearchField(searchQuery) { searchQuery = it } else ConnectionStatusText() }
                        },
                        actions = {
                            IconButton(onClick = onOpenTransfers) {
                                Icon(Icons.Filled.SwapVert, contentDescription = stringResource(R.string.transfers_title))
                            }
                            IconButton(onClick = { searchOpen = !searchOpen; searchQuery = "" }) {
                                Icon(if (searchOpen) Icons.Filled.Close else Icons.Filled.Search, contentDescription = null)
                            }
                        },
                        colors = barColors(),
                    )
                    Tab.SETTINGS -> TopAppBar(title = { Text(stringResource(R.string.settings_title)) }, colors = barColors())
                    Tab.PROFILE -> TopAppBar(title = {}, colors = barColors())
                }
                OngoingCallBanner(peerLogin = null, onOpen = onOpenCall)
            }
        },
    ) { padding ->
        val forward = tab.ordinal > previousTab.ordinal
        Box(
            Modifier
                .padding(padding)
                .fillMaxSize()
                .pointerInput(Unit) {
                    // свайп влево/вправо — соседняя вкладка по кругу
                    var total = 0f
                    detectHorizontalDragGestures(
                        onDragStart = { total = 0f },
                        onHorizontalDrag = { _, dx -> total += dx },
                        onDragEnd = {
                            if (abs(total) > 60.dp.toPx()) {
                                val n = Tab.entries.size
                                val next = if (total < 0) (tab.ordinal + 1) % n else (tab.ordinal - 1 + n) % n
                                selectTab(Tab.entries[next])
                            }
                        },
                    )
                },
        ) {
            AnimatedContent(
                targetState = tab,
                transitionSpec = {
                    val dir = if (forward) 1 else -1
                    (slideInHorizontally { it / 4 * dir } + fadeIn()) togetherWith (slideOutHorizontally { -it / 4 * dir } + fadeOut())
                },
                label = "tabs",
            ) { current ->
                when (current) {
                    Tab.CHATS -> ChatList(onOpenChat)
                    Tab.SETTINGS -> SettingsTab(onSignedOut = onSignedOut)
                    Tab.PROFILE -> ProfileTab()
                }
            }
            if (searchOpen && tab == Tab.CHATS) {
                SearchResults(
                    query = searchQuery,
                    onOpenChat = {
                        searchOpen = false
                        onOpenChat(it)
                    },
                    // свой логин → вкладка своего профиля (чата «Заметки» больше нет)
                    onOpenSelf = { selectTab(Tab.PROFILE) },
                )
            }
            HomeTabs(tab, ::selectTab, Modifier.align(Alignment.BottomCenter))
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun barColors() = LocalAppColors.current.let {
    TopAppBarDefaults.topAppBarColors(containerColor = it.background, titleContentColor = it.textPrimary, actionIconContentColor = it.textPrimary)
}

/** Сервер показывает "в сети" только пока приложение на экране; на экране — убираем уведомления. */
@Composable
private fun ForegroundStateReporter() {
    val app = LocalContext.current.app
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> {
                    app.core.ws.sendForegroundState(true)
                    NotificationManagerCompat.from(app).cancelAll()
                }
                Lifecycle.Event.ON_PAUSE -> app.core.ws.sendForegroundState(false)
                else -> Unit
            }
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
}

@Composable
private fun HomeTabs(tab: Tab, onSelect: (Tab) -> Unit, modifier: Modifier = Modifier) {
    val colors = LocalAppColors.current
    val avatar by LocalContext.current.app.core.myAccount.avatar.collectAsState()
    val buttonWidth = (LocalConfiguration.current.screenWidthDp / 5).dp
    Row(
        modifier.padding(bottom = 14.dp)
            .clip(RoundedCornerShape(50))
            .background(colors.surface.copy(alpha = 0.92f))
            .border(1.dp, colors.textMuted.copy(alpha = 0.18f), RoundedCornerShape(50))
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        TabButton(tab == Tab.CHATS, stringResource(R.string.nav_chats), buttonWidth, { onSelect(Tab.CHATS) }) { tint ->
            Icon(Icons.AutoMirrored.Outlined.Chat, null, tint = tint, modifier = Modifier.size(20.dp))
        }
        TabButton(tab == Tab.SETTINGS, stringResource(R.string.nav_settings), buttonWidth, { onSelect(Tab.SETTINGS) }) { tint ->
            Icon(Icons.Filled.Tune, null, tint = tint, modifier = Modifier.size(20.dp))
        }
        TabButton(tab == Tab.PROFILE, stringResource(R.string.nav_profile), buttonWidth, { onSelect(Tab.PROFILE) }) { tint ->
            if (avatar != null) AvatarImage(avatar, 20.dp) else Icon(Icons.Outlined.Person, null, tint = tint, modifier = Modifier.size(20.dp))
        }
    }
}

/** Кнопка овальной панели вкладок: значок и подпись; выбранная — подсвеченный овал. */
@Composable
private fun TabButton(selected: Boolean, label: String, width: Dp, onClick: () -> Unit, icon: @Composable (Color) -> Unit) {
    val colors = LocalAppColors.current
    val background by animateColorAsState(if (selected) colors.primary.copy(alpha = 0.16f) else Color.Transparent, tween(220), label = "tabBg")
    val tint = if (selected) colors.primary else colors.textPrimary
    Column(
        Modifier.padding(horizontal = 2.dp).width(width).clip(RoundedCornerShape(50)).background(background)
            .clickable(onClick = onClick).padding(vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        icon(tint)
        Spacer(Modifier.height(2.dp))
        Text(
            label, color = tint, fontSize = 10.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
        )
    }
}

/** Отступ снизу у списков вкладок — под плавающую панель вкладок. */
val HomeTabsReserve = 80.dp

/** Состояние соединения с сервером — вместо заголовка, обновляется само. */
@Composable
private fun ConnectionStatusText() {
    val colors = LocalAppColors.current
    val status by LocalContext.current.app.core.ws.status.collectAsState()
    val text = stringResource(
        when (status) {
            ConnectionStatus.WAITING_FOR_NETWORK -> R.string.connection_waitingForNetwork
            ConnectionStatus.CONNECTING -> R.string.connection_connecting
            ConnectionStatus.CONNECTED -> R.string.connection_connected
            ConnectionStatus.RECONNECTING -> R.string.connection_reconnecting
        },
    )
    AnimatedContent(text, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "connection") { t ->
        Text(t, color = colors.textMuted, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 8.dp))
    }
}

// ---------------- поиск ----------------

private sealed interface SearchResult {
    data object Self : SearchResult
    data class Found(val target: ChatTarget, val displayName: String?) : SearchResult
    data class NotFound(val message: String) : SearchResult
}

@Composable
private fun SearchField(query: String, onChange: (String) -> Unit) {
    val colors = LocalAppColors.current
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    TextField(
        value = query,
        onValueChange = onChange,
        placeholder = { Text(stringResource(R.string.newChat_loginHint), color = colors.textMuted) },
        singleLine = true,
        modifier = Modifier.fillMaxWidth().focusRequester(focus),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = Color.Transparent,
            unfocusedContainerColor = Color.Transparent,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            focusedTextColor = colors.textPrimary,
            unfocusedTextColor = colors.textPrimary,
            cursorColor = colors.primary,
        ),
    )
}

@Composable
private fun SearchResults(query: String, onOpenChat: (ChatTarget) -> Unit, onOpenSelf: () -> Unit) {
    val context = LocalContext.current
    val core = context.app.core
    val colors = LocalAppColors.current
    val trimmed = query.trim()
    var loading by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<SearchResult?>(null) }
    LaunchedEffect(trimmed) {
        result = null
        if (trimmed.isEmpty()) {
            loading = false
            return@LaunchedEffect
        }
        loading = true
        delay(400) // пока печатают — не дёргаем сервер на каждую букву
        result = try {
            if (trimmed == core.session.login) {
                SearchResult.Self
            } else {
                val profile = core.session.token?.let { core.api.getAccountProfile(it, trimmed) }
                if (profile == null) {
                    SearchResult.NotFound(context.getString(R.string.error_userNotFound))
                } else {
                    val deviceId = profile.devices.firstOrNull()?.optString("device_id") ?: ""
                    if (deviceId.isNotEmpty()) core.peerAccounts.save(deviceId, profile.accountId)
                    SearchResult.Found(ChatTarget(profile.login, profile.accountId, deviceId), profile.displayName.takeIf { it != profile.login })
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            SearchResult.NotFound(context.errorText(e))
        }
        loading = false
    }
    val found = result
    if (!loading && found == null) return
    Surface(
        color = colors.surface,
        shape = CardShape,
        shadowElevation = 6.dp,
        modifier = Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 8.dp),
    ) {
        when (found) {
            null -> Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(Modifier.size(24.dp), color = colors.primary, strokeWidth = 2.dp)
            }
            is SearchResult.NotFound -> Text(found.message, color = colors.textMuted, modifier = Modifier.padding(16.dp))
            is SearchResult.Self -> {
                val myAvatar by core.myAccount.avatar.collectAsState()
                SearchRow(avatar = { AvatarImage(myAvatar, 40.dp) }, title = core.session.login ?: "", subtitle = stringResource(R.string.nav_profile), onClick = onOpenSelf)
            }
            is SearchResult.Found -> SearchRow(
                avatar = { PeerAvatar(found.target.accountId, 40.dp) },
                title = found.displayName ?: found.target.login,
                subtitle = found.displayName?.let { found.target.login },
                onClick = { onOpenChat(found.target) },
            )
        }
    }
}

@Composable
private fun SearchRow(avatar: @Composable () -> Unit, title: String, subtitle: String?, onClick: () -> Unit) {
    val colors = LocalAppColors.current
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        avatar()
        Spacer(Modifier.width(14.dp))
        Column {
            Text(title, color = colors.textPrimary, fontWeight = FontWeight.SemiBold)
            if (subtitle != null) Text(subtitle, color = colors.textMuted, fontSize = 13.sp)
        }
    }
}

// ---------------- список чатов ----------------

@Composable
private fun ChatList(onOpenChat: (ChatTarget) -> Unit) {
    val core = LocalContext.current.app.core
    var chats by remember { mutableStateOf<List<ChatSummary>>(emptyList()) }
    LaunchedEffect(Unit) {
        chats = core.chats.getKnownPeers()
        core.chats.changes.collect { chats = core.chats.getKnownPeers() }
    }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = HomeTabsReserve)) {
        items(chats, key = { it.peerLogin }) { chat ->
            ChatRow(chat, onOpen = {
                onOpenChat(ChatTarget(chat.peerLogin, chat.lastKnownAccountId ?: "", chat.lastKnownDeviceId ?: ""))
            })
        }
    }
}

private enum class ChatMenuAction { PIN, UNPIN, MUTE, UNMUTE, BLOCK, UNBLOCK, CLEAR, DELETE }

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ChatRow(chat: ChatSummary, onOpen: () -> Unit) {
    val context = LocalContext.current
    val core = context.app.core
    val colors = LocalAppColors.current
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    var menuOpen by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf<ChatMenuAction?>(null) }
    val unread = chat.unreadCount > 0
    val accent = if (unread) colors.primary else colors.textMuted

    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .background(if (unread) colors.primary.copy(alpha = 0.12f) else Color.Transparent)
                .combinedClickable(
                    onClick = {
                        scope.launch { core.chatActions.refreshPeer(chat.peerLogin) }
                        onOpen()
                    },
                    onLongClick = {
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        menuOpen = true
                    },
                )
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            PeerAvatar(chat.lastKnownAccountId, 54.dp)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                val nameStyle = TextStyle(color = colors.textPrimary, fontSize = 17.sp, fontWeight = if (unread) FontWeight.Bold else FontWeight.SemiBold)
                if (chat.isDeleted) {
                    Text(stringResource(R.string.home_deletedAccount), style = nameStyle)
                } else {
                    PeerName(chat.lastKnownAccountId, chat.peerLogin, nameStyle)
                }
                Text(
                    ChatStore.decodePreview(chat.lastMessage, context::translate),
                    color = colors.textMuted,
                    fontSize = 14.sp,
                    fontWeight = if (unread) FontWeight.SemiBold else FontWeight.Normal,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                if (unread) {
                    Box(Modifier.background(colors.primary, RoundedCornerShape(12.dp)).padding(horizontal = 7.dp, vertical = 2.dp)) {
                        Text(if (chat.unreadCount > 9) "9+" else "${chat.unreadCount}", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                    }
                }
                if (chat.chatPinnedAt != null) Icon(Icons.Filled.PushPin, null, tint = colors.textMuted, modifier = Modifier.size(13.dp))
                if (chat.muted) Icon(Icons.Filled.NotificationsOff, null, tint = colors.textMuted, modifier = Modifier.size(14.dp))
                if (chat.blockedByMe || chat.blockingMe) Icon(Icons.Filled.Block, null, tint = colors.textMuted, modifier = Modifier.size(13.dp))
                if (chat.lastTimestamp > 0) {
                    if (chat.lastMessageIsMine) {
                        Icon(if (chat.lastMessageIsRead) Icons.Filled.DoneAll else Icons.Filled.Done, null, tint = accent, modifier = Modifier.size(14.dp))
                    }
                    Text(formatChatTime(chat.lastTimestamp), color = accent, fontSize = 12.sp, fontWeight = if (unread) FontWeight.Bold else FontWeight.Normal)
                }
            }
        }
        ChatMenu(chat, menuOpen, onDismiss = { menuOpen = false }) { action ->
            menuOpen = false
            when (action) {
                ChatMenuAction.CLEAR, ChatMenuAction.DELETE -> confirm = action
                else -> scope.launch {
                    try {
                        when (action) {
                            ChatMenuAction.PIN -> core.chats.setChatPinned(chat.peerLogin, true)
                            ChatMenuAction.UNPIN -> core.chats.setChatPinned(chat.peerLogin, false)
                            ChatMenuAction.MUTE -> core.chatActions.setMuted(chat, true)
                            ChatMenuAction.UNMUTE -> core.chatActions.setMuted(chat, false)
                            ChatMenuAction.BLOCK -> core.chatActions.setBlocked(chat, true)
                            ChatMenuAction.UNBLOCK -> core.chatActions.setBlocked(chat, false)
                            ChatMenuAction.CLEAR, ChatMenuAction.DELETE -> Unit
                        }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        Toast.makeText(context, context.errorText(e), Toast.LENGTH_SHORT).show()
                    }
                }
            }
        }
    }
    confirm?.let { action ->
        val delete = action == ChatMenuAction.DELETE
        DeleteChatDialog(
            peerName = chat.peerLogin,
            delete = delete,
            onDismiss = { confirm = null },
            onConfirm = { forPeer ->
                confirm = null
                scope.launch { core.chatActions.clearOrDelete(chat, deleteChat = delete, forPeer = forPeer) }
            },
        )
    }
}

@Composable
private fun ChatMenu(chat: ChatSummary, expanded: Boolean, onDismiss: () -> Unit, onSelect: (ChatMenuAction) -> Unit) {
    val colors = LocalAppColors.current
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss, offset = DpOffset(72.dp, 0.dp), containerColor = colors.surface) {
        @Composable
        fun item(text: Int, action: ChatMenuAction, danger: Boolean = false) = DropdownMenuItem(
            text = { Text(stringResource(text), color = if (danger) ErrorRed else colors.textPrimary) },
            onClick = { onSelect(action) },
        )
        if (chat.chatPinnedAt != null) item(R.string.chatMenu_unpin, ChatMenuAction.UNPIN) else item(R.string.chatMenu_pin, ChatMenuAction.PIN)
        if (chat.muted) item(R.string.chatMenu_unmute, ChatMenuAction.UNMUTE) else item(R.string.chatMenu_mute, ChatMenuAction.MUTE)
        if (chat.blockedByMe) item(R.string.chatMenu_unblock, ChatMenuAction.UNBLOCK) else item(R.string.chatMenu_block, ChatMenuAction.BLOCK)
        HorizontalDivider(color = colors.textMuted.copy(alpha = 0.2f))
        item(R.string.chatMenu_clearHistory, ChatMenuAction.CLEAR, danger = true)
        item(R.string.chatMenu_deleteChat, ChatMenuAction.DELETE, danger = true)
    }
}

/** Подтверждение очистки/удаления — с галочкой "также у собеседника". */
@Composable
fun DeleteChatDialog(peerName: String, delete: Boolean, onDismiss: () -> Unit, onConfirm: (forPeer: Boolean) -> Unit) {
    val colors = LocalAppColors.current
    var forPeer by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = colors.surface,
        shape = CardShape,
        title = {
            Text(stringResource(if (delete) R.string.chatMenu_deleteChatTitle else R.string.chatMenu_clearHistoryTitle), color = colors.textPrimary)
        },
        text = {
            Row(Modifier.fillMaxWidth().clickable { forPeer = !forPeer }, verticalAlignment = Alignment.CenterVertically) {
                Checkbox(checked = forPeer, onCheckedChange = { forPeer = it })
                Text("${stringResource(R.string.deleteMessage_alsoForPeer)} $peerName", color = colors.textPrimary)
            }
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(forPeer) }) {
                Text(stringResource(if (delete) R.string.chatMenu_deleteChatConfirm else R.string.chatMenu_clearHistoryConfirm), color = ErrorRed)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.common_cancel), color = colors.primary) }
        },
    )
}

/**
 * Разрешения, без которых не будет уведомлений и звонков: уведомления
 * (Android 13+) и полноэкранный входящий звонок поверх блокировки
 * (Android 14+ — только переключателем в настройках, туда и отправляем).
 */
@Composable
private fun RequestNotificationPermissions() {
    val context = LocalContext.current
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }
    LaunchedEffect(Unit) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (Build.VERSION.SDK_INT >= 34 && !context.getSystemService(NotificationManager::class.java).canUseFullScreenIntent()) {
            runCatching {
                context.startActivity(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:${context.packageName}")))
            }
        }
    }
}
