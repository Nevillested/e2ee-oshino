package com.oshinobu.app.ui.auth

import com.oshinobu.app.ui.AppLoadingIndicator
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.widget.Toast
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.ui.AuthTextField
import com.oshinobu.app.ui.ErrorLine
import com.oshinobu.app.ui.ErrorRed
import com.oshinobu.app.ui.FormScreen
import com.oshinobu.app.ui.Gap
import com.oshinobu.app.ui.MutedText
import com.oshinobu.app.ui.PrimaryButton
import com.oshinobu.app.ui.SecondaryButton
import com.oshinobu.app.ui.errorText
import com.oshinobu.app.ui.rememberFormState
import com.oshinobu.app.ui.theme.CardShape
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.auth.totpSecret
import com.oshinobu.core.auth.validateLogin
import com.oshinobu.core.auth.validatePassword
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** Зачем восстанавливаем доступ: пароль или приложение-аутентификатор (TOTP). */
enum class RecoveryPurpose { PASSWORD, TOTP }

private const val SUPPORT_EMAIL = "support@oshino.space"

/** Ссылка на документ сайта на языке интерфейса. */
private fun Context.siteDocUrl(doc: String): String {
    val lang = if (resources.configuration.locales[0].language == "ru") "ru" else "en"
    return "https://ee2e.oshino.space/$doc/$lang/"
}

fun Context.copyToClipboard(text: String, toast: String) {
    getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("", text))
    Toast.makeText(this, toast, Toast.LENGTH_SHORT).show()
}

@Composable
fun WelcomeScreen(onLogin: () -> Unit, onRegister: () -> Unit) {
    val colors = LocalAppColors.current
    Column(
        Modifier.fillMaxSize().background(colors.background).padding(horizontal = 32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Oshinobu", fontSize = 32.sp, fontWeight = FontWeight.Bold, color = colors.textPrimary)
        Gap(48)
        PrimaryButton(stringResource(R.string.welcome_login), onLogin)
        Gap(12)
        SecondaryButton(stringResource(R.string.welcome_register), onRegister)
    }
}

/** Вход: логин + пароль + код TOTP. Язык интерфейса берётся из аккаунта. */
@Composable
fun LoginScreen(onBack: () -> Unit, onLoggedIn: () -> Unit, onRecover: (RecoveryPurpose) -> Unit) {
    val context = LocalContext.current
    val core = context.app.core
    val scope = rememberCoroutineScope()
    val focus = LocalFocusManager.current
    val form = rememberFormState()
    var login by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var totp by rememberSaveable { mutableStateOf("") }

    FormScreen(stringResource(R.string.login_title), onBack) {
        AuthTextField(login, { login = it }, stringResource(R.string.auth_loginHint))
        Gap()
        AuthTextField(password, { password = it }, stringResource(R.string.auth_passwordHint), password = true)
        Gap()
        AuthTextField(totp, { totp = it }, stringResource(R.string.auth_totpHint), keyboardType = KeyboardType.Number)
        ErrorLine(form.error)
        Gap(24)
        PrimaryButton(stringResource(R.string.welcome_login), loading = form.loading, onClick = {
            focus.clearFocus()
            scope.launch {
                form.run {
                    val result = core.api.login(login.trim(), password, totp.trim())
                    core.session.token = result.token
                    core.session.login = login.trim()
                    val language = if (result.language == "ru") "ru" else "en"
                    core.settings.setLocale(language)
                    core.startSession()
                    context.app.applyLocale(language)
                    onLoggedIn()
                }
            }
        })
        Gap(10)
        TextButton(onClick = { onRecover(RecoveryPurpose.PASSWORD) }, enabled = !form.loading, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.recovery_forgotPassword))
        }
        TextButton(onClick = { onRecover(RecoveryPurpose.TOTP) }, enabled = !form.loading, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.recovery_forgotTotp))
        }
    }
}

/** Регистрация по инвайт-коду → настройка TOTP. */
@Composable
fun RegisterScreen(onBack: () -> Unit, onRegistered: (login: String, totpUrl: String) -> Unit) {
    val context = LocalContext.current
    val core = context.app.core
    val colors = LocalAppColors.current
    val scope = rememberCoroutineScope()
    val focus = LocalFocusManager.current
    val form = rememberFormState()
    var login by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var invite by rememberSaveable { mutableStateOf("") }

    FormScreen(stringResource(R.string.register_title), onBack) {
        AuthTextField(login, { login = it }, stringResource(R.string.auth_loginHint))
        Gap()
        AuthTextField(password, { password = it }, stringResource(R.string.auth_passwordHint), password = true)
        Gap(6)
        MutedText(stringResource(R.string.password_requirementsHint), fontSize = 12)
        Gap()
        AuthTextField(invite, { invite = it }, stringResource(R.string.auth_inviteCodeHint), keyboardType = KeyboardType.Number)
        ErrorLine(form.error)
        Gap(24)
        PrimaryButton(stringResource(R.string.common_next), loading = form.loading, onClick = {
            focus.clearFocus()
            val invalid = validateLogin(login.trim()) ?: validatePassword(password)
            if (invalid != null) {
                form.error = context.errorText(invalid)
                return@PrimaryButton
            }
            scope.launch {
                form.run {
                    val url = core.api.register(login.trim(), password, invite.trim())
                    onRegistered(login.trim(), url)
                }
            }
        })
        Gap(16)
        val terms = stringResource(R.string.about_terms)
        val privacy = stringResource(R.string.about_privacy)
        val linkStyle = TextLinkStyles(SpanStyle(color = colors.primary, textDecoration = TextDecoration.Underline))
        val agreement = buildAnnotatedString {
            append(stringResource(R.string.register_agreementPrefix))
            withLink(LinkAnnotation.Url(context.siteDocUrl("terms"), linkStyle)) { append(terms) }
            append(stringResource(R.string.register_agreementJoiner))
            withLink(LinkAnnotation.Url(context.siteDocUrl("privacy"), linkStyle)) { append(privacy) }
            append(".")
        }
        Text(
            agreement,
            style = TextStyle(color = colors.textMuted, fontSize = 12.sp, textAlign = TextAlign.Center),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

private fun qrBitmap(content: String, sizePx: Int = 600): Bitmap {
    val matrix = QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, sizePx, sizePx)
    val pixels = IntArray(sizePx * sizePx) { i -> if (matrix[i % sizePx, i / sizePx]) android.graphics.Color.BLACK else android.graphics.Color.WHITE }
    return Bitmap.createBitmap(pixels, sizePx, sizePx, Bitmap.Config.ARGB_8888)
}

/** Подключение приложения-аутентификатора: QR + секрет для ручного ввода + проверочный код. */
@Composable
fun VerifyTotpScreen(login: String, totpUrl: String, onBack: () -> Unit, onVerified: () -> Unit) {
    val context = LocalContext.current
    val core = context.app.core
    val colors = LocalAppColors.current
    val scope = rememberCoroutineScope()
    val form = rememberFormState()
    var code by rememberSaveable { mutableStateOf("") }
    val secret = remember(totpUrl) { totpSecret(totpUrl) }
    val qr = remember(totpUrl) { qrBitmap(totpUrl).asImageBitmap() }

    FormScreen(stringResource(R.string.totp_title), onBack) {
        MutedText(stringResource(R.string.totp_scanInstruction))
        Gap(20)
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Box(Modifier.background(Color.White, CardShape).padding(16.dp)) {
                Image(qr, contentDescription = null, modifier = Modifier.size(200.dp))
            }
        }
        Gap(20)
        MutedText(stringResource(R.string.totp_manualEntry), fontSize = 13)
        Gap(8)
        val copied = stringResource(R.string.totp_codeCopied)
        Row(verticalAlignment = Alignment.CenterVertically) {
            SelectionContainer(Modifier.weight(1f)) {
                Text(secret, color = colors.textPrimary, fontSize = 16.sp, letterSpacing = 1.5.sp)
            }
            IconButton(onClick = { context.copyToClipboard(secret, copied) }) {
                Icon(Icons.Filled.ContentCopy, contentDescription = null, tint = colors.primary)
            }
        }
        Gap(24)
        AuthTextField(code, { code = it }, stringResource(R.string.auth_totpHint), keyboardType = KeyboardType.Number)
        ErrorLine(form.error)
        Gap(24)
        PrimaryButton(stringResource(R.string.totp_confirm), loading = form.loading, onClick = {
            scope.launch {
                form.run {
                    core.api.verifyTotp(login, code.trim())
                    onVerified()
                }
            }
        })
    }
}

/** Как восстанавливать: по коду на почту или без почты (через поддержку). */
@Composable
fun RecoveryChooseScreen(purpose: RecoveryPurpose, onBack: () -> Unit, onHasEmail: () -> Unit, onNoEmail: () -> Unit) {
    FormScreen(stringResource(R.string.recovery_chooseTitle), onBack) {
        Gap(48)
        PrimaryButton(
            stringResource(if (purpose == RecoveryPurpose.PASSWORD) R.string.recovery_hasEmailButton else R.string.recovery_hasEmailButtonTotp),
            onHasEmail,
        )
        Gap()
        SecondaryButton(
            stringResource(if (purpose == RecoveryPurpose.PASSWORD) R.string.recovery_noEmailButton else R.string.recovery_noEmailButtonTotp),
            onNoEmail,
        )
    }
}

/** Запрос кода восстановления на привязанную почту. */
@Composable
fun RecoveryRequestScreen(purpose: RecoveryPurpose, onBack: () -> Unit, onCodeSent: (login: String) -> Unit) {
    val core = LocalContext.current.app.core
    val scope = rememberCoroutineScope()
    val form = rememberFormState()
    var login by rememberSaveable { mutableStateOf("") }
    FormScreen(stringResource(if (purpose == RecoveryPurpose.PASSWORD) R.string.recovery_title else R.string.recovery_titleTotp), onBack) {
        MutedText(stringResource(R.string.recovery_requestSentInfo))
        Gap(20)
        AuthTextField(login, { login = it }, stringResource(R.string.auth_loginHint))
        ErrorLine(form.error)
        Gap(24)
        PrimaryButton(stringResource(R.string.recovery_sendCode), loading = form.loading, enabled = login.isNotBlank(), onClick = {
            scope.launch {
                form.run {
                    core.api.requestPasswordRecovery(login.trim())
                    onCodeSent(login.trim())
                }
            }
        })
    }
}

/** Ввод кода из письма. */
@Composable
fun RecoveryCodeScreen(login: String, onBack: () -> Unit, onVerified: (code: String) -> Unit) {
    val core = LocalContext.current.app.core
    val scope = rememberCoroutineScope()
    val form = rememberFormState()
    var code by rememberSaveable { mutableStateOf("") }
    FormScreen(stringResource(R.string.recovery_codeTitle), onBack) {
        AuthTextField(code, { code = it }, stringResource(R.string.recovery_codeHint), keyboardType = KeyboardType.Password)
        ErrorLine(form.error)
        Gap(24)
        PrimaryButton(stringResource(R.string.recovery_confirmCode), loading = form.loading, enabled = code.isNotBlank(), onClick = {
            scope.launch {
                form.run {
                    core.api.verifyRecoveryCode(login, code.trim())
                    onVerified(code.trim())
                }
            }
        })
    }
}

/** Без почты восстановить нельзя автоматически — только через поддержку. */
@Composable
fun RecoveryNoEmailScreen(purpose: RecoveryPurpose, onBack: () -> Unit) {
    val context = LocalContext.current
    val colors = LocalAppColors.current
    val copied = stringResource(R.string.common_copied)
    FormScreen(stringResource(R.string.recovery_noEmailTitle), onBack) {
        Text(
            stringResource(if (purpose == RecoveryPurpose.PASSWORD) R.string.recovery_noEmailBody else R.string.recovery_noEmailBodyTotp),
            color = colors.textPrimary,
            lineHeight = 20.sp,
        )
        Gap(24)
        SecondaryButton(stringResource(R.string.recovery_copyEmail), { context.copyToClipboard(SUPPORT_EMAIL, copied) })
    }
}

/** Новый пароль по коду восстановления. */
@Composable
fun SetNewPasswordScreen(login: String, code: String, onBack: () -> Unit, onDone: () -> Unit) {
    val context = LocalContext.current
    val core = context.app.core
    val scope = rememberCoroutineScope()
    val form = rememberFormState()
    var password by rememberSaveable { mutableStateOf("") }
    var confirm by rememberSaveable { mutableStateOf("") }
    val success = stringResource(R.string.recovery_success)
    FormScreen(stringResource(R.string.recovery_newPasswordTitle), onBack) {
        AuthTextField(password, { password = it }, stringResource(R.string.recovery_newPasswordHint), password = true)
        Gap(6)
        MutedText(stringResource(R.string.password_requirementsHint), fontSize = 12)
        Gap()
        AuthTextField(confirm, { confirm = it }, stringResource(R.string.recovery_confirmPasswordHint), password = true)
        ErrorLine(form.error)
        Gap(24)
        PrimaryButton(stringResource(R.string.recovery_save), loading = form.loading, onClick = {
            if (password != confirm) {
                form.error = context.getString(R.string.recovery_passwordsDontMatch)
                return@PrimaryButton
            }
            validatePassword(password)?.let {
                form.error = context.errorText(it)
                return@PrimaryButton
            }
            scope.launch {
                form.run {
                    core.api.resetPasswordWithRecoveryCode(login, code, password)
                    Toast.makeText(context, success, Toast.LENGTH_SHORT).show()
                    onDone()
                }
            }
        })
    }
}

/** Новый секрет TOTP по коду восстановления → тот же экран подключения аутентификатора. */
@Composable
fun ResetTotpScreen(login: String, code: String, onBack: () -> Unit, onVerified: () -> Unit) {
    val context = LocalContext.current
    val core = context.app.core
    var totpUrl by rememberSaveable { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableStateOf(0) }
    LaunchedEffect(attempt) {
        error = null
        try {
            totpUrl = core.api.resetTotpWithRecoveryCode(login, code)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = context.errorText(e)
        }
    }
    val url = totpUrl
    if (url != null) {
        VerifyTotpScreen(login, url, onBack, onVerified)
        return
    }
    FormScreen(stringResource(R.string.recovery_titleTotp), onBack) {
        Gap(48)
        if (error == null) {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                AppLoadingIndicator(size = 32.dp, color = LocalAppColors.current.primary)
            }
        } else {
            Text(error!!, color = ErrorRed, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
            Gap(16)
            PrimaryButton(stringResource(R.string.common_retry), { attempt++ })
        }
    }
}
