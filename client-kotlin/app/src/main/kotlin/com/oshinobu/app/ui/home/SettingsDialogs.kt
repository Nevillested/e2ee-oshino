package com.oshinobu.app.ui.home

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Face
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material.icons.outlined.Cake
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Photo
import androidx.compose.material.icons.outlined.Pin
import androidx.compose.material.icons.outlined.PrivacyTip
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Timer
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.ui.AuthTextField
import com.oshinobu.app.ui.ErrorLine
import com.oshinobu.app.ui.ErrorRed
import com.oshinobu.app.ui.MutedText
import com.oshinobu.app.ui.errorText
import com.oshinobu.app.ui.lock.BiometricKind
import com.oshinobu.app.ui.lock.Biometrics
import com.oshinobu.app.ui.lock.PinSetupDialog
import com.oshinobu.app.ui.rememberFormState
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.auth.validatePassword
import com.oshinobu.core.net.PrivacySettings
import com.oshinobu.core.service.retryUntilSuccess
import kotlinx.coroutines.launch

private val EmailFormat = Regex("""^[^\s@]+@[^\s@]+\.[^\s@]+$""")

/**
 * Почта для восстановления: показать текущую и удалить (с подтверждением)
 * или добавить — адрес, затем код из письма. Отправленный код можно ввести
 * в течение 25 минут, даже закрыв окно.
 */
@Composable
fun EmailDialog(onClose: () -> Unit) {
    val context = LocalContext.current
    val core = context.app.core
    val colors = LocalAppColors.current
    val scope = rememberCoroutineScope()
    val email by core.myAccount.email.collectAsState()
    var adding by remember { mutableStateOf(core.pendingEmail.get() != null) }
    var confirmRemove by remember { mutableStateOf(false) }

    if (adding) {
        AddEmailDialog(onClose)
        return
    }
    if (confirmRemove) {
        AppDialog(
            stringResource(R.string.email_removeConfirmTitle), onClose,
            confirm = {
                DialogButton(stringResource(R.string.email_removeButton), ErrorRed) {
                    scope.launch {
                        val token = core.session.token ?: return@launch
                        val text = runCatching { core.api.updateEmail(token, "") }.fold(
                            onSuccess = {
                                core.myAccount.setEmail(null)
                                context.getString(R.string.email_removed)
                            },
                            onFailure = { context.errorText(it) },
                        )
                        Toast.makeText(context, text, Toast.LENGTH_SHORT).show()
                        onClose()
                    }
                }
            },
            dismiss = { DialogButton(stringResource(R.string.common_cancel), onClick = onClose) },
        ) { Text(stringResource(R.string.email_removeConfirmBody), color = colors.textMuted) }
        return
    }
    val has = !email.isNullOrEmpty()
    AppDialog(
        stringResource(R.string.email_title), onClose,
        confirm = {
            if (has) DialogButton(stringResource(R.string.email_removeButton), ErrorRed) { confirmRemove = true }
            else DialogButton(stringResource(R.string.email_addButton)) { adding = true }
        },
        dismiss = { DialogButton(stringResource(R.string.common_cancel), onClick = onClose) },
    ) { Text(if (has) email.orEmpty() else stringResource(R.string.email_notSet), color = if (has) colors.textPrimary else colors.textMuted) }
}

@Composable
private fun AddEmailDialog(onClose: () -> Unit) {
    val context = LocalContext.current
    val core = context.app.core
    val colors = LocalAppColors.current
    val scope = rememberCoroutineScope()
    val form = rememberFormState()
    var pending by remember { mutableStateOf(core.pendingEmail.get()) }
    var address by remember { mutableStateOf(pending.orEmpty()) }
    var code by remember { mutableStateOf("") }
    val codeStep = pending != null
    AppDialog(
        stringResource(if (codeStep) R.string.recovery_codeTitle else R.string.email_title),
        onClose,
        confirm = {
            DialogButton(stringResource(if (codeStep) R.string.recovery_confirmCode else R.string.email_sendCode)) {
                if (form.loading) return@DialogButton
                val token = core.session.token ?: return@DialogButton
                if (!codeStep) {
                    val value = address.trim()
                    if (!EmailFormat.matches(value)) {
                        form.error = context.getString(R.string.email_invalid)
                        return@DialogButton
                    }
                    scope.launch {
                        form.run {
                            core.api.requestEmailVerification(token, value)
                            core.pendingEmail.set(value)
                            pending = value
                        }
                    }
                } else {
                    val entered = code.trim()
                    if (entered.isEmpty()) return@DialogButton
                    scope.launch {
                        form.run {
                            core.api.confirmEmailVerification(token, entered)
                            core.pendingEmail.clear()
                            core.myAccount.setEmail(pending)
                            Toast.makeText(context, context.getString(R.string.email_saved), Toast.LENGTH_SHORT).show()
                            onClose()
                        }
                    }
                }
            }
        },
        dismiss = {
            DialogButton(stringResource(R.string.common_cancel)) {
                if (codeStep) core.pendingEmail.clear()
                onClose()
            }
        },
    ) {
        Column {
            if (!codeStep) {
                Text(stringResource(R.string.email_description), color = colors.textMuted, fontSize = 13.sp)
                Spacer(Modifier.height(12.dp))
                AuthTextField(address, { address = it }, stringResource(R.string.email_hint), keyboardType = KeyboardType.Email)
            } else {
                Text("${stringResource(R.string.email_codeSentTo)} $pending", color = colors.textMuted, fontSize = 13.sp)
                Spacer(Modifier.height(12.dp))
                AuthTextField(code, { code = it }, stringResource(R.string.recovery_codeHint), keyboardType = KeyboardType.Number)
            }
            ErrorLine(form.error)
        }
    }
}

/** Смена пароля: новый, повтор, проверка требований. */
@Composable
fun ChangePasswordDialog(onClose: () -> Unit) {
    val context = LocalContext.current
    val core = context.app.core
    val scope = rememberCoroutineScope()
    val form = rememberFormState()
    var password by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    AppDialog(
        stringResource(R.string.changePassword_title), onClose,
        confirm = {
            DialogButton(stringResource(R.string.recovery_save)) {
                if (form.loading) return@DialogButton
                if (password != confirm) {
                    form.error = context.getString(R.string.recovery_passwordsDontMatch)
                    return@DialogButton
                }
                validatePassword(password)?.let {
                    form.error = context.errorText(it)
                    return@DialogButton
                }
                val token = core.session.token ?: return@DialogButton
                scope.launch {
                    form.run {
                        core.api.changePassword(token, password)
                        Toast.makeText(context, context.getString(R.string.changePassword_success), Toast.LENGTH_SHORT).show()
                        onClose()
                    }
                }
            }
        },
        dismiss = { DialogButton(stringResource(R.string.common_cancel), onClick = onClose) },
    ) {
        Column {
            AuthTextField(password, { password = it }, stringResource(R.string.recovery_newPasswordHint), password = true)
            Spacer(Modifier.height(6.dp))
            MutedText(stringResource(R.string.password_requirementsHint), fontSize = 12)
            Spacer(Modifier.height(14.dp))
            AuthTextField(confirm, { confirm = it }, stringResource(R.string.recovery_confirmPasswordHint), password = true)
            ErrorLine(form.error)
        }
    }
}

@Composable
private fun SettingRow(icon: ImageVector?, title: String, subtitle: String?, enabled: Boolean = true, onClick: (() -> Unit)?, trailing: (@Composable () -> Unit)? = null) {
    val colors = LocalAppColors.current
    Row(
        Modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(enabled = enabled, onClick = onClick) else Modifier).padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, null, tint = colors.textMuted)
            Spacer(Modifier.width(16.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, color = if (enabled) colors.textPrimary else colors.textMuted)
            if (subtitle != null) Text(subtitle, color = colors.textMuted, fontSize = 13.sp)
        }
        trailing?.invoke()
    }
}

/** Выбор из списка снизу экрана с галочкой у текущего. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun <T> ChoiceSheet(title: String?, options: List<Pair<T, String>>, current: T, onPick: (T) -> Unit, onDismiss: () -> Unit) {
    val colors = LocalAppColors.current
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = colors.surface) {
        Column(Modifier.navigationBarsPadding().verticalScroll(rememberScrollState())) {
            if (title != null) Text(title, color = colors.textPrimary, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(16.dp))
            options.forEach { (value, label) ->
                Row(
                    Modifier.fillMaxWidth().clickable { onPick(value) }.padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(label, color = colors.textPrimary, modifier = Modifier.weight(1f))
                    if (value == current) Icon(Icons.Filled.Check, null, tint = colors.primary)
                }
            }
        }
    }
}

/**
 * Приватность: кто находит по логину и кто видит фото, день рождения и
 * "о себе". Сохранение повторяется до успеха (как во Flutter).
 */
@Composable
fun PrivacyDialog(onClose: () -> Unit) {
    val context = LocalContext.current
    val core = context.app.core
    val scope = rememberCoroutineScope()
    val profile = core.myAccount.profile.value
    var findByLogin by remember { mutableIntStateOf(profile?.findByLoginVisibility ?: 1) }
    var avatar by remember { mutableIntStateOf(profile?.avatarVisibility ?: 1) }
    var birthday by remember { mutableIntStateOf(profile?.birthdayVisibility ?: 1) }
    var status by remember { mutableIntStateOf(profile?.statusVisibility ?: 1) }
    var saving by remember { mutableStateOf(false) }
    var picking by remember { mutableStateOf<Triple<String, Boolean, (Int) -> Unit>?>(null) }
    var pickingCurrent by remember { mutableIntStateOf(1) }
    val everyone = stringResource(R.string.privacy_everyone)
    val contacts = stringResource(R.string.privacy_contactsOnly)
    val nobody = stringResource(R.string.privacy_nobody)
    fun label(v: Int, allowContacts: Boolean) = when {
        v == 0 -> nobody
        v == 2 && allowContacts -> contacts
        else -> everyone
    }

    AppDialog(
        stringResource(R.string.privacy_title), onClose,
        confirm = {
            DialogButton(stringResource(if (saving) R.string.privacy_saving else R.string.common_save)) {
                if (saving) return@DialogButton
                val token = core.session.token ?: return@DialogButton
                saving = true
                val p = PrivacySettings(findByLogin, avatar, birthday, status)
                scope.launch {
                    retryUntilSuccess { core.api.updatePrivacy(token, p) }
                    core.myAccount.setPrivacy(p)
                    Toast.makeText(context, context.getString(R.string.privacy_saved), Toast.LENGTH_SHORT).show()
                    onClose()
                }
            }
        },
        dismiss = { DialogButton(stringResource(R.string.common_cancel), onClick = onClose) },
    ) {
        Column {
            val rows = listOf(
                Triple(Icons.Outlined.Search, R.string.privacy_findByLogin, false),
                Triple(Icons.Outlined.Photo, R.string.privacy_avatar, true),
                Triple(Icons.Outlined.Cake, R.string.privacy_birthday, true),
                Triple(Icons.Outlined.ChatBubbleOutline, R.string.privacy_status, true),
            )
            val values = listOf(findByLogin, avatar, birthday, status)
            val setters = listOf<(Int) -> Unit>({ findByLogin = it }, { avatar = it }, { birthday = it }, { status = it })
            rows.forEachIndexed { i, (icon, title, allowContacts) ->
                val titleText = stringResource(title)
                SettingRow(icon, titleText, label(values[i], allowContacts), onClick = {
                    pickingCurrent = values[i]
                    picking = Triple(titleText, allowContacts, setters[i])
                })
            }
        }
    }
    picking?.let { (title, allowContacts, set) ->
        val options = buildList {
            add(1 to everyone)
            if (allowContacts) add(2 to contacts)
            add(0 to nobody)
        }
        ChoiceSheet(title, options, pickingCurrent, onPick = { set(it); picking = null }, onDismiss = { picking = null })
    }
}

private val TimeoutOptions = listOf(30, 60, 120, 300, 600, 900, 1800, 3600, 7200)

private fun timeoutLabel(seconds: Int) = when (seconds) {
    30 -> R.string.applock_timeout_30
    60 -> R.string.applock_timeout_60
    120 -> R.string.applock_timeout_120
    300 -> R.string.applock_timeout_300
    600 -> R.string.applock_timeout_600
    900 -> R.string.applock_timeout_900
    1800 -> R.string.applock_timeout_1800
    3600 -> R.string.applock_timeout_3600
    else -> R.string.applock_timeout_7200
}

/**
 * Блокировка приложения: вкл/выкл, через сколько блокировать, PIN (задать,
 * сменить, удалить) и биометрия. Включение требует PIN — если его нет,
 * сначала задаём.
 */
@Composable
fun AppLockSettingsDialog(onClose: () -> Unit) {
    val context = LocalContext.current
    val store = context.app.core.appLock
    val colors = LocalAppColors.current
    val scope = rememberCoroutineScope()
    val state by store.state.collectAsState()
    val biometric = remember { Biometrics.kind(context) }
    var pinSetup by remember { mutableStateOf<(suspend () -> Unit)?>(null) }
    var pinActions by remember { mutableStateOf(false) }
    var timeoutPicker by remember { mutableStateOf(false) }
    val s = state ?: return

    /** Нужен PIN: есть — сразу [then], нет — сначала задать. */
    fun withPin(then: suspend () -> Unit) {
        if (s.hasPin) scope.launch { then() } else pinSetup = then
    }

    AppDialog(stringResource(R.string.applock_title), onClose, confirm = { DialogButton(stringResource(R.string.common_done), onClick = onClose) }) {
        Column {
            SettingRow(
                null, stringResource(R.string.applock_status), stringResource(if (s.enabled) R.string.applock_on else R.string.applock_off), onClick = null,
                trailing = {
                    Switch(s.enabled, { on -> if (on) withPin { store.setEnabled(true) } else scope.launch { store.setEnabled(false) } },
                        colors = SwitchDefaults.colors(checkedTrackColor = colors.primary))
                },
            )
            SettingRow(Icons.Outlined.Timer, stringResource(R.string.applock_timeout), stringResource(timeoutLabel(s.timeoutSeconds)), enabled = s.enabled, onClick = { timeoutPicker = true })
            HorizontalDivider(Modifier.padding(vertical = 8.dp), color = colors.textMuted.copy(alpha = 0.2f))
            Text(stringResource(R.string.applock_unlockMethod), color = colors.textMuted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            SettingRow(
                Icons.Outlined.Pin, stringResource(R.string.applock_pin),
                stringResource(if (s.hasPin) R.string.applock_pinSet else R.string.applock_pinNotSet),
                onClick = { if (s.hasPin) pinActions = true else pinSetup = {} },
            )
            if (biometric != null) {
                SettingRow(
                    if (biometric == BiometricKind.FACE) Icons.Filled.Face else Icons.Filled.Fingerprint,
                    stringResource(
                        when (biometric) {
                            BiometricKind.FACE -> R.string.applock_face
                            BiometricKind.FINGERPRINT -> R.string.applock_fingerprint
                            BiometricKind.GENERIC -> R.string.applock_biometric
                        },
                    ),
                    if (s.hasPin) null else stringResource(R.string.applock_needPinFirst),
                    onClick = null,
                    trailing = {
                        Switch(s.biometricEnabled, { on -> if (on) withPin { store.setBiometricEnabled(true) } else scope.launch { store.setBiometricEnabled(false) } },
                            colors = SwitchDefaults.colors(checkedTrackColor = colors.primary))
                    },
                )
            }
        }
    }
    pinSetup?.let { then ->
        PinSetupDialog { ok ->
            pinSetup = null
            if (ok) scope.launch { then() }
        }
    }
    if (pinActions) {
        val change = stringResource(R.string.applock_changePin)
        val remove = stringResource(R.string.applock_removePin)
        ChoiceSheet(null, listOf(0 to change, 1 to remove), -1, onPick = {
            pinActions = false
            if (it == 0) pinSetup = {} else scope.launch { store.removePin() }
        }, onDismiss = { pinActions = false })
    }
    if (timeoutPicker) {
        val options = TimeoutOptions.map { it to context.getString(timeoutLabel(it)) }
        ChoiceSheet(null, options, s.timeoutSeconds, onPick = {
            timeoutPicker = false
            scope.launch { store.setTimeoutSeconds(it) }
        }, onDismiss = { timeoutPicker = false })
    }
}

/** О приложении: версия и ссылки на условия и политику (на языке интерфейса). */
@Composable
fun AboutDialog(onClose: () -> Unit) {
    val context = LocalContext.current
    val lang = if (context.app.core.settings.locale() == "ru") "ru" else "en"
    val version = remember {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
        "${info.versionName} ($code)"
    }
    fun open(url: String) = runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
    AppDialog(stringResource(R.string.about_title), onClose, confirm = { DialogButton(stringResource(R.string.common_done), onClick = onClose) }) {
        Column {
            SettingRow(Icons.Outlined.Info, stringResource(R.string.about_version), version, onClick = null)
            SettingRow(Icons.Outlined.Description, stringResource(R.string.about_terms), null, onClick = { open("https://ee2e.oshino.space/terms/$lang/") })
            SettingRow(Icons.Outlined.PrivacyTip, stringResource(R.string.about_privacy), null, onClick = { open("https://ee2e.oshino.space/privacy/$lang/") })
        }
    }
}
