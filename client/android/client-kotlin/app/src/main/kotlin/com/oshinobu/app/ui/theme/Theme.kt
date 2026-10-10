package com.oshinobu.app.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/** Палитра приложения (порт AppColors Flutter-клиента): голубой акцент, тёмная и светлая темы. */
@Immutable
data class AppColors(
    val primary: Color,
    val primaryDark: Color,
    val background: Color,
    val surface: Color,
    val textPrimary: Color,
    val textMuted: Color,
    val isDark: Boolean,
) {
    companion object {
        val Dark = AppColors(
            primary = Color(0xFF2AABEE),
            primaryDark = Color(0xFF229ED9),
            background = Color(0xFF17212B),
            surface = Color(0xFF242F3D),
            textPrimary = Color.White,
            textMuted = Color(0xFF8E99A4),
            isDark = true,
        )
        val Light = AppColors(
            primary = Color(0xFF2AABEE),
            primaryDark = Color(0xFF1D8FC7),
            background = Color(0xFFEEF2F7),
            surface = Color.White,
            textPrimary = Color(0xFF17212B),
            textMuted = Color(0xFF6B7A88),
            isDark = false,
        )
    }
}

val LocalAppColors = staticCompositionLocalOf { AppColors.Dark }

/** Скругление карточек, полей и диалогов во всём приложении. */
val CardShape = RoundedCornerShape(14.dp)

@Composable
fun OshinobuTheme(dark: Boolean, content: @Composable () -> Unit) {
    val colors = if (dark) AppColors.Dark else AppColors.Light
    val scheme = if (dark) {
        darkColorScheme(
            primary = colors.primary,
            onPrimary = Color.White,
            background = colors.background,
            onBackground = colors.textPrimary,
            surface = colors.surface,
            onSurface = colors.textPrimary,
            surfaceVariant = colors.surface,
            onSurfaceVariant = colors.textMuted,
            surfaceContainer = colors.surface,
            surfaceContainerHigh = colors.surface,
        )
    } else {
        lightColorScheme(
            primary = colors.primary,
            onPrimary = Color.White,
            background = colors.background,
            onBackground = colors.textPrimary,
            surface = colors.surface,
            onSurface = colors.textPrimary,
            surfaceVariant = colors.surface,
            onSurfaceVariant = colors.textMuted,
            surfaceContainer = colors.surface,
            surfaceContainerHigh = colors.surface,
        )
    }
    CompositionLocalProvider(LocalAppColors provides colors) {
        MaterialTheme(
            colorScheme = scheme,
            shapes = Shapes(small = CardShape, medium = CardShape, large = CardShape),
            content = content,
        )
    }
}
