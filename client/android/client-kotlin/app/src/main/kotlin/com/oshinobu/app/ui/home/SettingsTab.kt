package com.oshinobu.app.ui.home

import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.CleaningServices
import androidx.compose.material.icons.filled.DeleteForever
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material.icons.outlined.Email
import androidx.compose.material.icons.outlined.EmojiEmotions
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Palette
import androidx.compose.material.icons.outlined.PhonelinkLock
import androidx.compose.material.icons.outlined.PrivacyTip
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.ui.ErrorRed
import com.oshinobu.app.ui.emoji.allEmojis
import com.oshinobu.app.ui.theme.CardShape
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.app.ui.translate
import com.oshinobu.core.format.formatFileSize
import com.oshinobu.core.storage.UiSettings
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** Пункты настроек открываются окнами поверх вкладки (как во Flutter-клиенте). */
private enum class SettingsDialog { EMAIL, PASSWORD, PRIVACY, APP_LOCK, ABOUT, THEME, LANGUAGE, FONT, REACTION, CLEAR_CACHE, LOGOUT, DELETE_ACCOUNT }

@Composable
fun SettingsTab(onSignedOut: () -> Unit) {
    var dialog by remember { mutableStateOf<SettingsDialog?>(null) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        SettingsItem(Icons.Outlined.Email, Color(0xFF2AABEE), R.string.settings_email) { dialog = SettingsDialog.EMAIL }
        SettingsItem(Icons.Outlined.Lock, Color(0xFFFF9F0A), R.string.settings_changePassword) { dialog = SettingsDialog.PASSWORD }
        SettingsItem(Icons.Outlined.EmojiEmotions, Color(0xFFFF6482), R.string.settings_defaultReaction) { dialog = SettingsDialog.REACTION }
        SettingsItem(Icons.Outlined.Language, Color(0xFF32C769), R.string.settings_language) { dialog = SettingsDialog.LANGUAGE }
        SettingsItem(Icons.Outlined.Palette, Color(0xFFAF52DE), R.string.settings_theme) { dialog = SettingsDialog.THEME }
        SettingsItem(Icons.Filled.TextFields, Color(0xFF5AC8FA), R.string.settings_fontSize) { dialog = SettingsDialog.FONT }
        SettingsItem(Icons.Outlined.PrivacyTip, Color(0xFF34C759), R.string.settings_privacy) { dialog = SettingsDialog.PRIVACY }
        SettingsItem(Icons.Outlined.PhonelinkLock, Color(0xFF5E5CE6), R.string.settings_appLock) { dialog = SettingsDialog.APP_LOCK }
        SettingsItem(Icons.Filled.CleaningServices, Color(0xFF00C7BE), R.string.settings_clearCache) { dialog = SettingsDialog.CLEAR_CACHE }
        SettingsItem(Icons.Outlined.Info, Color(0xFF8E8E93), R.string.settings_about) { dialog = SettingsDialog.ABOUT }
        SettingsItem(Icons.AutoMirrored.Filled.Logout, Color(0xFFFF3B30), R.string.settings_logout, danger = true) { dialog = SettingsDialog.LOGOUT }
        SettingsItem(Icons.Filled.DeleteForever, Color(0xFFB00020), R.string.settings_deleteAccount, danger = true) { dialog = SettingsDialog.DELETE_ACCOUNT }
        Spacer(Modifier.height(HomeTabsReserve))
    }
    val close = { dialog = null }
    when (dialog) {
        SettingsDialog.EMAIL -> EmailDialog(close)
        SettingsDialog.PASSWORD -> ChangePasswordDialog(close)
        SettingsDialog.PRIVACY -> PrivacyDialog(close)
        SettingsDialog.APP_LOCK -> AppLockSettingsDialog(close)
        SettingsDialog.ABOUT -> AboutDialog(close)
        SettingsDialog.THEME -> ThemeDialog(close)
        SettingsDialog.LANGUAGE -> LanguageDialog(close)
        SettingsDialog.FONT -> FontSizeDialog(close)
        SettingsDialog.REACTION -> DefaultReactionDialog(close)
        SettingsDialog.CLEAR_CACHE -> ClearCacheDialog(close)
        SettingsDialog.LOGOUT -> LogoutDialog(close, onSignedOut)
        SettingsDialog.DELETE_ACCOUNT -> DeleteAccountDialog(close, onSignedOut)
        null -> Unit
    }
}

@Composable
private fun SettingsItem(icon: ImageVector, tint: Color, title: Int, danger: Boolean = false, onClick: () -> Unit) {
    val colors = LocalAppColors.current
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(30.dp).background(tint, RoundedCornerShape(8.dp)), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = Color.White, modifier = Modifier.size(18.dp))
        }
        Spacer(Modifier.width(16.dp))
        Text(stringResource(title), color = if (danger) ErrorRed else colors.textPrimary, fontSize = 16.sp)
    }
}

/** Диалог в стиле приложения: поверхность, скругление 14. */
@Composable
fun AppDialog(
    title: String,
    onDismiss: () -> Unit,
    confirm: @Composable () -> Unit,
    dismiss: (@Composable () -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    val colors = LocalAppColors.current
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = colors.surface,
        shape = CardShape,
        title = { Text(title, color = colors.textPrimary) },
        text = content,
        confirmButton = confirm,
        dismissButton = dismiss,
    )
}

@Composable
fun DialogButton(text: String, color: Color = LocalAppColors.current.primary, onClick: () -> Unit) {
    TextButton(onClick = onClick) { Text(text, color = color) }
}

@Composable
private fun ThemeDialog(onClose: () -> Unit) {
    val app = LocalContext.current.app
    val colors = LocalAppColors.current
    val dark by app.darkTheme.collectAsState()
    AppDialog(stringResource(R.string.theme_title), onClose, confirm = { DialogButton(stringResource(R.string.common_done), onClick = onClose) }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(if (dark) R.string.theme_dark else R.string.theme_light), color = colors.textPrimary, modifier = Modifier.weight(1f))
            Switch(
                checked = !dark,
                onCheckedChange = { light -> app.setDarkTheme(!light) },
                colors = SwitchDefaults.colors(checkedTrackColor = colors.primary),
            )
        }
    }
}

@Composable
private fun LanguageDialog(onClose: () -> Unit) {
    val context = LocalContext.current
    val colors = LocalAppColors.current
    val notice = stringResource(R.string.language_restartNotice)
    fun choose(tag: String) {
        onClose()
        context.app.setLanguage(tag)
        Toast.makeText(context, notice, Toast.LENGTH_SHORT).show()
    }
    AppDialog(stringResource(R.string.language_title), onClose, confirm = { DialogButton(stringResource(R.string.common_cancel), onClick = onClose) }) {
        Column {
            for ((tag, label) in listOf("ru" to R.string.language_russian, "en" to R.string.language_english)) {
                Text(
                    stringResource(label),
                    color = colors.textPrimary,
                    fontSize = 17.sp,
                    modifier = Modifier.fillMaxWidth().clickable { choose(tag) }.padding(vertical = 12.dp),
                )
            }
        }
    }
}

@Composable
private fun FontSizeDialog(onClose: () -> Unit) {
    val app = LocalContext.current.app
    val colors = LocalAppColors.current
    val scale by app.textScale.collectAsState()
    val steps = UiSettings.TEXT_SCALE_STEPS
    AppDialog(stringResource(R.string.fontSize_title), onClose, confirm = { DialogButton(stringResource(R.string.common_done), onClick = onClose) }) {
        Column {
            Text(stringResource(R.string.fontSize_preview), color = colors.textPrimary)
            Spacer(Modifier.height(12.dp))
            Slider(
                value = steps.indexOf(scale).coerceAtLeast(0).toFloat(),
                onValueChange = { app.setTextScale(steps[it.toInt().coerceIn(0, steps.lastIndex)]) },
                valueRange = 0f..steps.lastIndex.toFloat(),
                steps = steps.size - 2,
                colors = SliderDefaults.colors(thumbColor = colors.primary, activeTrackColor = colors.primary),
            )
        }
    }
}

@Composable
private fun DefaultReactionDialog(onClose: () -> Unit) {
    val core = LocalContext.current.app.core
    val colors = LocalAppColors.current
    val scope = rememberCoroutineScope()
    var selected by remember { mutableStateOf(UiSettings.DEFAULT_REACTION) }
    LaunchedEffect(Unit) { selected = core.settings.defaultReaction() }
    AppDialog(
        stringResource(R.string.reaction_pickerTitle),
        onClose,
        confirm = {
            DialogButton(stringResource(R.string.common_save)) {
                scope.launch { core.settings.setDefaultReaction(selected) }
                onClose()
            }
        },
        dismiss = { DialogButton(stringResource(R.string.common_cancel), onClick = onClose) },
    ) {
        LazyVerticalGrid(GridCells.Fixed(6), Modifier.height(320.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            items(allEmojis) { emoji ->
                Box(
                    Modifier
                        .size(44.dp)
                        .background(if (emoji == selected) colors.primary.copy(alpha = 0.25f) else Color.Transparent, CardShape)
                        .clickable { selected = emoji },
                    contentAlignment = Alignment.Center,
                ) { Text(emoji, fontSize = 24.sp) }
            }
        }
    }
}

@Composable
private fun ClearCacheDialog(onClose: () -> Unit) {
    val context = LocalContext.current
    val core = context.app.core
    val colors = LocalAppColors.current
    val size = remember { core.media.cacheSize() }
    val emptyText = stringResource(R.string.settings_cacheEmpty)
    LaunchedEffect(size) {
        if (size == 0L) {
            Toast.makeText(context, emptyText, Toast.LENGTH_SHORT).show()
            onClose()
        }
    }
    if (size == 0L) return
    val cleared = stringResource(R.string.settings_cacheCleared)
    AppDialog(
        stringResource(R.string.settings_clearCacheTitle),
        onClose,
        confirm = {
            DialogButton(stringResource(R.string.settings_clearCache)) {
                val count = core.media.clearCache()
                core.logger.log("Settings media cache cleared count=$count freedBytes=$size")
                Toast.makeText(context, cleared, Toast.LENGTH_SHORT).show()
                onClose()
            }
        },
        dismiss = { DialogButton(stringResource(R.string.common_cancel), onClick = onClose) },
    ) {
        Text(stringResource(R.string.settings_clearCacheBody, formatFileSize(size, context::translate)), color = colors.textMuted)
    }
}

@Composable
private fun LogoutDialog(onClose: () -> Unit, onSignedOut: () -> Unit) {
    val core = LocalContext.current.app.core
    val colors = LocalAppColors.current
    val scope = rememberCoroutineScope()
    AppDialog(
        stringResource(R.string.account_logoutTitle),
        onClose,
        confirm = {
            DialogButton(stringResource(R.string.account_logoutConfirm), color = ErrorRed) {
                scope.launch {
                    core.logout()
                    onSignedOut()
                }
            }
        },
        dismiss = { DialogButton(stringResource(R.string.common_cancel), onClick = onClose) },
    ) { Text(stringResource(R.string.account_logoutBody), color = colors.textMuted) }
}

/** Удаление аккаунта: сначала на сервере — без сети не удаляем ничего и локально. */
@Composable
private fun DeleteAccountDialog(onClose: () -> Unit, onSignedOut: () -> Unit) {
    val context = LocalContext.current
    val core = context.app.core
    val colors = LocalAppColors.current
    val scope = rememberCoroutineScope()
    val offline = stringResource(R.string.account_deleteOfflineError)
    AppDialog(
        stringResource(R.string.account_deleteTitle),
        onClose,
        confirm = {
            DialogButton(stringResource(R.string.account_deleteConfirm), color = ErrorRed) {
                scope.launch {
                    val deleted = try {
                        core.session.token?.let { core.api.deleteAccount(it) } ?: false
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: Exception) {
                        false
                    }
                    if (!deleted) {
                        Toast.makeText(context, offline, Toast.LENGTH_LONG).show()
                        onClose()
                        return@launch
                    }
                    core.logout()
                    onSignedOut()
                }
            }
        },
        dismiss = { DialogButton(stringResource(R.string.common_cancel), onClick = onClose) },
    ) { Text(stringResource(R.string.account_deleteBody), color = colors.textMuted) }
}
