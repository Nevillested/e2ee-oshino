package com.oshinobu.app.ui

import kotlin.math.sin
import kotlin.math.PI
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.geometry.Offset
import androidx.compose.foundation.Canvas
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.LinearEasing
import android.content.Context
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.oshinobu.app.R
import com.oshinobu.app.ui.theme.CardShape
import com.oshinobu.app.ui.theme.LocalAppColors
import kotlinx.coroutines.CancellationException

/** Красный цвет ошибок — один на всё приложение. */
val ErrorRed = Color(0xFFE53935)

/** Экран с заголовком, стрелкой «назад» и прокручиваемым содержимым (формы входа, восстановления, настроек). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FormScreen(title: String, onBack: (() -> Unit)?, content: @Composable ColumnScope.() -> Unit) {
    val colors = LocalAppColors.current
    Scaffold(
        containerColor = colors.background,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text(title) },
                navigationIcon = {
                    if (onBack != null) {
                        IconButton(onClick = onBack) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.common_back))
                        }
                    }
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
                    containerColor = colors.background,
                    titleContentColor = colors.textPrimary,
                    navigationIconContentColor = colors.textPrimary,
                ),
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(24.dp),
            content = content,
        )
    }
}

/** Поле ввода форм входа — заливка цветом поверхности, без рамки, скругление 14. */
@Composable
fun AuthTextField(
    value: String,
    onValueChange: (String) -> Unit,
    hint: String,
    modifier: Modifier = Modifier,
    keyboardType: KeyboardType = KeyboardType.Text,
    password: Boolean = false,
) {
    val colors = LocalAppColors.current
    var hidden by remember { mutableStateOf(true) }
    TextField(
        value = value,
        onValueChange = onValueChange,
        placeholder = { Text(hint, color = colors.textMuted) },
        singleLine = true,
        modifier = modifier.fillMaxWidth(),
        shape = CardShape,
        keyboardOptions = KeyboardOptions(keyboardType = if (password) KeyboardType.Password else keyboardType),
        visualTransformation = if (password && hidden) PasswordVisualTransformation() else VisualTransformation.None,
        trailingIcon = if (password) {
            {
                IconButton(onClick = { hidden = !hidden }) {
                    Icon(if (hidden) Icons.Filled.VisibilityOff else Icons.Filled.Visibility, contentDescription = null, tint = colors.textMuted)
                }
            }
        } else {
            null
        },
        colors = TextFieldDefaults.colors(
            focusedContainerColor = colors.surface,
            unfocusedContainerColor = colors.surface,
            disabledContainerColor = colors.surface,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            disabledIndicatorColor = Color.Transparent,
            focusedTextColor = colors.textPrimary,
            unfocusedTextColor = colors.textPrimary,
            cursorColor = colors.primary,
        ),
    )
}

/** Основная кнопка: на всю ширину, высота 52, во время [loading] — индикатор вместо текста. */
@Composable
fun PrimaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, loading: Boolean = false, enabled: Boolean = true) {
    val colors = LocalAppColors.current
    Button(
        onClick = onClick,
        enabled = enabled && !loading,
        modifier = modifier.fillMaxWidth().heightIn(min = 52.dp),
        shape = CardShape,
        colors = ButtonDefaults.buttonColors(containerColor = colors.primary, contentColor = Color.White),
        contentPadding = PaddingValues(horizontal = 16.dp),
    ) {
        if (loading) {
            AppLoadingIndicator(size = 22.dp, color = Color.White)
        } else {
            Text(text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

/** Второстепенная кнопка с рамкой акцентного цвета. */
@Composable
fun SecondaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    val colors = LocalAppColors.current
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.fillMaxWidth().heightIn(min = 52.dp),
        shape = CardShape,
        border = BorderStroke(1.dp, colors.primary),
    ) {
        Text(text, color = colors.primary, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
fun ErrorLine(text: String?) {
    if (text == null) return
    Spacer(Modifier.height(14.dp))
    Text(text, color = ErrorRed)
}

@Composable
fun MutedText(text: String, fontSize: Int = 14) {
    Text(text, color = LocalAppColors.current.textMuted, fontSize = fontSize.sp)
}

@Composable
fun FullScreenLoading() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        AppLoadingIndicator(size = 32.dp, color = LocalAppColors.current.primary)
    }
}

/** Вертикальный отступ между элементами формы. */
@Composable
fun Gap(height: Int = 14) = Spacer(Modifier.height(height.dp))

/**
 * Состояние формы с одной асинхронной отправкой: ошибка, индикатор и запуск
 * действия, ошибку которого надо показать пользователю.
 */
class FormState(private val context: Context) {
    var loading by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)

    suspend fun run(action: suspend () -> Unit) {
        loading = true
        error = null
        try {
            action()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = context.errorText(e)
        } finally {
            loading = false
        }
    }
}

@Composable
fun rememberFormState(): FormState {
    val context = LocalContext.current
    return remember { FormState(context) }
}

/**
 * Действие, которому нужно разрешение: есть — выполняется сразу, нет —
 * сначала системный запрос, и только при согласии — действие.
 */
@Composable
fun rememberWithPermission(permission: String): (action: () -> Unit) -> Unit {
    val context = LocalContext.current
    var pending by remember { mutableStateOf<(() -> Unit)?>(null) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val action = pending
        pending = null
        if (granted) action?.invoke()
    }
    return { action ->
        if (ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED) {
            action()
        } else {
            pending = action
            launcher.launch(permission)
        }
    }
}

/**
 * Индикатор загрузки — три точки, пульсирующие волной (как AppLoadingIndicator
 * во Flutter-клиенте): масштаб 0.55–1 и прозрачность 0.35–1, период 1.1 с.
 */
@Composable
fun AppLoadingIndicator(modifier: Modifier = Modifier, size: Dp = 24.dp, color: Color = LocalAppColors.current.primary) {
    val t by rememberInfiniteTransition(label = "loading").animateFloat(
        0f, 1f, infiniteRepeatable(tween(1100, easing = LinearEasing)), label = "t",
    )
    Canvas(modifier.size(size)) {
        val dot = this.size.width / 4.2f
        val step = (this.size.width - dot) / 2
        for (i in 0..2) {
            val wave = 0.5f + 0.5f * sin(2 * PI.toFloat() * (t - i * 0.22f))
            drawCircle(
                color.copy(alpha = color.alpha * (0.35f + 0.65f * wave)),
                radius = dot / 2 * (0.55f + 0.45f * wave),
                center = Offset(dot / 2 + i * step, this.size.height / 2),
            )
        }
    }
}
