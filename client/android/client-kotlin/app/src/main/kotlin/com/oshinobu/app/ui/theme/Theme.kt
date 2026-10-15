package com.oshinobu.app.ui.theme

import androidx.annotation.StringRes
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
import com.oshinobu.app.R

/**
 * Тема приложения: все цвета интерфейса. [onPrimary] — текст и значки на
 * акцентном цвете (кнопки, бейджи); свой пузырь — [bubbleMine] с текстом
 * [onBubbleMine], галочка "доставлено" на нём — [sentTick], ссылка — [linkOnMine].
 */
@Immutable
data class AppColors(
    /** Ключ в настройках. */
    val id: String,
    @StringRes val title: Int,
    val primary: Color,
    val primaryDark: Color,
    val onPrimary: Color,
    val background: Color,
    val surface: Color,
    val textPrimary: Color,
    val textMuted: Color,
    /** Фон переписки (у чатов без своих обоев). */
    val chatBackground: Color,
    val bubbleMine: Color,
    val onBubbleMine: Color,
    val sentTick: Color,
    val linkOnMine: Color,
    val isDark: Boolean,
) {
    companion object {
        /** Тёмно-синяя — прежняя тёмная, тема по умолчанию. */
        val Navy = AppColors(
            id = "dark",
            title = R.string.theme_navy,
            primary = Color(0xFF2AABEE),
            primaryDark = Color(0xFF229ED9),
            onPrimary = Color.White,
            background = Color(0xFF17212B),
            surface = Color(0xFF242F3D),
            textPrimary = Color.White,
            textMuted = Color(0xFF8E99A4),
            chatBackground = Color(0xFF17212B),
            bubbleMine = Color(0xFF2AABEE),
            onBubbleMine = Color.White,
            sentTick = Color(0xFF40C4FF),
            linkOnMine = Color(0xFFFFD54F),
            isDark = true,
        )

        /** Белая — прежняя светлая. */
        val White = AppColors(
            id = "light",
            title = R.string.theme_white,
            primary = Color(0xFF2AABEE),
            primaryDark = Color(0xFF1D8FC7),
            onPrimary = Color.White,
            background = Color(0xFFEEF2F7),
            surface = Color.White,
            textPrimary = Color(0xFF17212B),
            textMuted = Color(0xFF6B7A88),
            chatBackground = Color(0xFFDCE6EF),
            bubbleMine = Color(0xFF2AABEE),
            onBubbleMine = Color.White,
            sentTick = Color(0xFFD6F1FF),
            linkOnMine = Color(0xFFFFE082),
            isDark = false,
        )

        /** Чёрная: настоящий чёрный (экономит заряд на OLED), синий акцент. */
        val Black = AppColors(
            id = "black",
            title = R.string.theme_black,
            primary = Color(0xFF0A84FF),
            primaryDark = Color(0xFF0071E3),
            onPrimary = Color.White,
            background = Color.Black,
            surface = Color(0xFF1C1C1E),
            textPrimary = Color.White,
            textMuted = Color(0xFF8E8E93),
            chatBackground = Color.Black,
            bubbleMine = Color(0xFF0A84FF),
            onBubbleMine = Color.White,
            sentTick = Color(0xFFB8DAFF),
            linkOnMine = Color(0xFFFFE082),
            isDark = true,
        )

        /** Жёлто-чёрная: почти чёрный фон, жёлтый акцент; на жёлтом — тёмный текст. */
        val Yellow = AppColors(
            id = "yellow",
            title = R.string.theme_yellow,
            primary = Color(0xFFFFD60A),
            primaryDark = Color(0xFFE6BE00),
            onPrimary = Color(0xFF141414),
            background = Color(0xFF0E0E0C),
            surface = Color(0xFF1F1E1A),
            textPrimary = Color(0xFFF5F2E7),
            textMuted = Color(0xFFA6A28E),
            chatBackground = Color(0xFF0A0A08),
            bubbleMine = Color(0xFFFFD60A),
            onBubbleMine = Color(0xFF141414),
            sentTick = Color(0xFF6B5A00),
            linkOnMine = Color(0xFF0B57D0),
            isDark = true,
        )

        /** Зелёная: тёмные хвойные тона, мятный акцент, свой пузырь — глубокий зелёный. */
        val Green = AppColors(
            id = "green",
            title = R.string.theme_green,
            primary = Color(0xFF3DDC97),
            primaryDark = Color(0xFF2BBF7F),
            onPrimary = Color(0xFF062A1C),
            background = Color(0xFF0F1D18),
            surface = Color(0xFF1A2E26),
            textPrimary = Color(0xFFE7F5EE),
            textMuted = Color(0xFF8DB3A3),
            chatBackground = Color(0xFF0B1712),
            bubbleMine = Color(0xFF1E7A54),
            onBubbleMine = Color.White,
            sentTick = Color(0xFF9EF0C8),
            linkOnMine = Color(0xFFFFE082),
            isDark = true,
        )

        /** Порядок в выборе темы. */
        val All = listOf(Black, White, Yellow, Navy, Green)

        fun byId(id: String?): AppColors = All.firstOrNull { it.id == id } ?: Navy
    }
}

val LocalAppColors = staticCompositionLocalOf { AppColors.Navy }

/** Скругление карточек, полей и диалогов во всём приложении. */
val CardShape = RoundedCornerShape(14.dp)

@Composable
fun OshinobuTheme(colors: AppColors, content: @Composable () -> Unit) {
    val scheme = if (colors.isDark) {
        darkColorScheme(
            primary = colors.primary,
            onPrimary = colors.onPrimary,
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
            onPrimary = colors.onPrimary,
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
