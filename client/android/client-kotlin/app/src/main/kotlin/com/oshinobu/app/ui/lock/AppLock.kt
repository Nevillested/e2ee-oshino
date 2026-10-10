package com.oshinobu.app.ui.lock

import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import androidx.activity.compose.BackHandler
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Backspace
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.ui.PrimaryButton
import com.oshinobu.app.ui.theme.LocalAppColors
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

private val ErrorColor = Color(0xFFFF5252)

/** Какой вид биометрии есть на устройстве (для подписи и иконки). */
enum class BiometricKind { FACE, FINGERPRINT, GENERIC }

object Biometrics {
    /** null — биометрии нет или она не настроена. */
    fun kind(context: Context): BiometricKind? {
        val ok = BiometricManager.from(context).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK) == BiometricManager.BIOMETRIC_SUCCESS
        if (!ok) return null
        val pm = context.packageManager
        val face = pm.hasSystemFeature(PackageManager.FEATURE_FACE)
        val finger = pm.hasSystemFeature(PackageManager.FEATURE_FINGERPRINT)
        return when {
            face && !finger -> BiometricKind.FACE
            finger && !face -> BiometricKind.FINGERPRINT
            else -> BiometricKind.GENERIC
        }
    }

    /** Системный запрос биометрии; true — подтверждено. */
    suspend fun authenticate(context: Context, title: String, cancel: String): Boolean {
        val activity = context.findActivity() ?: return false
        return suspendCancellableCoroutine { cont ->
            val prompt = BiometricPrompt(
                activity,
                ContextCompat.getMainExecutor(activity),
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        if (cont.isActive) cont.resume(true)
                    }

                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        if (cont.isActive) cont.resume(false)
                    }
                },
            )
            prompt.authenticate(
                BiometricPrompt.PromptInfo.Builder()
                    .setTitle(title)
                    .setNegativeButtonText(cancel)
                    .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_WEAK)
                    .build(),
            )
            cont.invokeOnCancellation { prompt.cancelAuthentication() }
        }
    }

    private tailrec fun Context.findActivity(): FragmentActivity? = when (this) {
        is FragmentActivity -> this
        is ContextWrapper -> baseContext.findActivity()
        else -> null
    }
}

/** Точки введённых цифр и цифровая клавиатура 3×4. */
@Composable
fun PinPad(value: String, maxLength: Int, showError: Boolean, onChange: (String) -> Unit) {
    val colors = LocalAppColors.current
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Row(Modifier.height(16.dp), horizontalArrangement = Arrangement.Center) {
            repeat(value.length) {
                Box(Modifier.padding(horizontal = 5.dp).size(12.dp).background(if (showError) ErrorColor else colors.primary, CircleShape))
            }
        }
        Spacer(Modifier.height(32.dp))
        listOf(listOf("1", "2", "3"), listOf("4", "5", "6"), listOf("7", "8", "9"), listOf("", "0", "⌫")).forEachIndexed { i, row ->
            if (i > 0) Spacer(Modifier.height(14.dp))
            Row(Modifier.width(280.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
                row.forEach { key ->
                    Box(
                        Modifier.size(72.dp).then(
                            when (key) {
                                "" -> Modifier
                                "⌫" -> Modifier.clickable(enabled = value.isNotEmpty()) { onChange(value.dropLast(1)) }
                                else -> Modifier.background(colors.surface, CircleShape).clickable(enabled = value.length < maxLength) { onChange(value + key) }
                            },
                        ),
                        contentAlignment = Alignment.Center,
                    ) {
                        when (key) {
                            "" -> Unit
                            "⌫" -> Icon(Icons.AutoMirrored.Outlined.Backspace, null, tint = colors.textMuted)
                            else -> Text(key, color = colors.textPrimary, fontSize = 26.sp)
                        }
                    }
                }
            }
        }
    }
}

/**
 * Экран блокировки: PIN (проверяется, как только введено нужное число
 * цифр) и, если включено, биометрия — сразу при показе и по кнопке; после
 * трёх неудач биометрии остаётся только PIN.
 */
@Composable
fun AppLockScreen(onUnlocked: () -> Unit) {
    val context = LocalContext.current
    val colors = LocalAppColors.current
    val store = context.app.core.appLock
    val settings by store.state.collectAsState()
    val scope = rememberCoroutineScope()
    var pin by remember { mutableStateOf("") }
    var error by remember { mutableStateOf(false) }
    var biometricFails by remember { mutableIntStateOf(0) }
    val reason = stringResource(R.string.applock_useBiometricReason)
    val usePin = stringResource(R.string.applock_usePinInstead)
    val s = settings ?: return

    fun tryBiometric() = scope.launch {
        if (!s.biometricEnabled || biometricFails >= 3) return@launch
        if (Biometrics.authenticate(context, reason, usePin)) onUnlocked() else biometricFails++
    }

    LaunchedEffect(Unit) { tryBiometric() }
    BackHandler { /* заблокировано: назад не пускает к содержимому */ }
    Box(Modifier.fillMaxSize().background(colors.background).clickable(enabled = false) {}, contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Outlined.Lock, null, tint = colors.primary, modifier = Modifier.size(48.dp))
            Spacer(Modifier.height(12.dp))
            Text(
                stringResource(if (error) R.string.applock_wrongPin else R.string.applock_enterPin),
                color = if (error) ErrorColor else colors.textPrimary, fontSize = 16.sp,
            )
            Spacer(Modifier.height(24.dp))
            PinPad(pin, s.pinLength, error) { value ->
                pin = value
                error = false
                if (value.length == s.pinLength) {
                    scope.launch {
                        if (store.verifyPin(value)) {
                            onUnlocked()
                        } else {
                            error = true
                            pin = ""
                        }
                    }
                }
            }
            if (s.biometricEnabled && biometricFails < 3) {
                Spacer(Modifier.height(12.dp))
                TextButton(onClick = { tryBiometric() }) {
                    Icon(Icons.Filled.Fingerprint, null, tint = colors.primary)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.applock_unlockWithBiometric), color = colors.primary)
                }
            }
        }
    }
}

/** Новый PIN: 4–8 цифр, затем повтор; совпало — сохраняем и [onDone] (true). */
@Composable
fun PinSetupDialog(onDone: (Boolean) -> Unit) {
    val colors = LocalAppColors.current
    val store = LocalContext.current.app.core.appLock
    val scope = rememberCoroutineScope()
    var first by rememberSaveable { mutableStateOf<String?>(null) }
    var pin by rememberSaveable { mutableStateOf("") }
    var mismatch by remember { mutableStateOf(false) }
    Dialog(onDismissRequest = { onDone(false) }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().background(colors.background).statusBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { onDone(false) }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, null, tint = colors.textPrimary) }
                Text(stringResource(R.string.applock_pin), color = colors.textPrimary, fontSize = 20.sp)
            }
            Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                val entering = first == null
                Text(
                    stringResource(
                        when {
                            entering -> R.string.applock_newPin
                            mismatch -> R.string.applock_pinMismatch
                            else -> R.string.applock_confirmPin
                        },
                    ),
                    color = if (mismatch && !entering) ErrorColor else colors.textPrimary, fontSize = 16.sp, textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(24.dp))
                if (entering) {
                    PinPad(pin, 8, false) { pin = it }
                    Spacer(Modifier.height(24.dp))
                    PrimaryButton(stringResource(R.string.common_next), enabled = pin.length in 4..8, modifier = Modifier.padding(horizontal = 48.dp), onClick = {
                        first = pin
                        pin = ""
                    })
                } else {
                    val target = first.orEmpty()
                    PinPad(pin, target.length, mismatch) { value ->
                        pin = value
                        mismatch = false
                        if (value.length == target.length) {
                            if (value == target) {
                                scope.launch {
                                    store.setPin(value)
                                    onDone(true)
                                }
                            } else {
                                mismatch = true
                                pin = ""
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * Замок поверх всего приложения: при запуске, если блокировка включена, и
 * после возвращения из фона, если там провели не меньше заданного времени.
 */
@Composable
fun AppLockGate(content: @Composable () -> Unit) {
    val store = LocalContext.current.app.core.appLock
    val settings by store.state.collectAsState()
    var passed by remember { mutableStateOf<Boolean?>(null) }
    var backgroundedAt by remember { mutableLongStateOf(0L) }
    LaunchedEffect(Unit) { passed = !store.load().enabled }
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, event ->
            val s = store.state.value ?: return@LifecycleEventObserver
            when (event) {
                Lifecycle.Event.ON_STOP -> backgroundedAt = System.currentTimeMillis()
                Lifecycle.Event.ON_START -> {
                    val bg = backgroundedAt
                    backgroundedAt = 0
                    if (s.enabled && bg > 0 && System.currentTimeMillis() - bg >= s.timeoutSeconds * 1000L) passed = false
                }
                else -> Unit
            }
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    val gatePassed = passed ?: run {
        Box(Modifier.fillMaxSize().background(Color.Black))
        return
    }
    Box(Modifier.fillMaxSize()) {
        content()
        if (settings?.enabled == true && !gatePassed) AppLockScreen(onUnlocked = { passed = true })
    }
}
