package com.oshinobu.app.ui.chat

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.focus.FocusManager
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.SoftwareKeyboardController
import androidx.compose.ui.unit.dp
import com.oshinobu.app.app
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.abs

/**
 * Панель эмодзи на месте клавиатуры — общий механизм поля сообщения и подписи
 * к медиа. Переход эмодзи ↔ клавиатура не двигает поле ввода: панель
 * занимает ровно высоту клавиатуры; клавиатура при переключении наезжает на
 * панель или уезжает с неё, а из покоя панель выезжает сама.
 */
@Stable
class EmojiKeyboardState internal constructor(
    private val keyboard: SoftwareKeyboardController?,
    private val focusManager: FocusManager,
    initialKeyboardHeightPx: Int,
) {
    /** Поле ввода: им фокусируемся при возврате к клавиатуре. */
    val focusRequester = FocusRequester()

    var emojiMode by mutableStateOf(false)
        private set

    /** Высота клавиатуры (запоминается между запусками): панель эмодзи той же высоты. */
    var keyboardHeightPx by mutableIntStateOf(initialKeyboardHeightPx)
        internal set

    /** Возвращаемся к клавиатуре: место панели держится, пока она не поднимется. */
    internal var awaitingKeyboard by mutableStateOf(false)

    /** Сколько места под полем держит панель эмодзи. */
    internal val reserve = Animatable(0f)

    /** Кнопка эмодзи/клавиатура у поля. */
    fun toggle() {
        if (emojiMode) {
            awaitingKeyboard = true
            emojiMode = false
            focusRequester.requestFocus()
            keyboard?.show()
        } else {
            // снимаем фокус: тап по полю снова сфокусирует его и вернёт клавиатуру
            focusManager.clearFocus()
            emojiMode = true
        }
    }

    /** Поле получило фокус (тап по нему): клавиатура поднимается на место панели. */
    fun onFieldFocused() {
        if (emojiMode) {
            awaitingKeyboard = true
            emojiMode = false
        }
    }

    /** Убрать панель ("назад"). */
    fun closeEmoji() {
        emojiMode = false
    }
}

@OptIn(FlowPreview::class)
@Composable
fun rememberEmojiKeyboardState(): EmojiKeyboardState {
    val app = LocalContext.current.app
    val density = LocalDensity.current
    val keyboard = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current
    val state = remember {
        EmojiKeyboardState(keyboard, focusManager, with(density) { app.core.settings.keyboardHeight().dp.roundToPx() })
    }
    val imeInsets = WindowInsets.ime
    LaunchedEffect(Unit) {
        snapshotFlow { imeInsets.getBottom(density) }.debounce(250).collect { h ->
            if (h > with(density) { 120.dp.roundToPx() } && abs(h - state.keyboardHeightPx) > 1) {
                state.keyboardHeightPx = h
                app.core.settings.setKeyboardHeight(with(density) { h.toDp().value.toDouble() })
            }
        }
    }
    LaunchedEffect(state.awaitingKeyboard) {
        if (!state.awaitingKeyboard) return@LaunchedEffect
        // ждём, пока клавиатура поднимется (аппаратная клавиатура не поднимется — тогда по таймауту)
        withTimeoutOrNull(1_500) { snapshotFlow { imeInsets.getBottom(density) }.first { it >= state.keyboardHeightPx - 4 } }
        state.awaitingKeyboard = false
    }
    // переключение клавиатура ↔ эмодзи зону не меняет; из покоя панель выезжает за 220 мс
    val target = if (state.emojiMode || state.awaitingKeyboard) state.keyboardHeightPx.toFloat() else 0f
    LaunchedEffect(target) {
        if (imeInsets.getBottom(density) > 0) state.reserve.snapTo(target) else state.reserve.animateTo(target, tween(220))
    }
    return state
}

/**
 * Место под полем ввода: высота = max(клавиатура, панель эмодзи, отступ
 * навигации + 5dp) и считается на этапе раскладки — в том же кадре, что и
 * анимация клавиатуры, поэтому поле движется ровно с ней, без отставания на
 * кадр. Панель эмодзи лежит сверху зоны и строится заранее, пока открыта
 * клавиатура (её под клавиатурой не видно): иначе первая отрисовка сетки
 * съедает кадры, и клавиатура "исчезает" без анимации.
 */
@Composable
fun EmojiKeyboardArea(state: EmojiKeyboardState, onEmoji: (String) -> Unit) {
    val density = LocalDensity.current
    val ime = WindowInsets.ime
    val nav = WindowInsets.navigationBars
    val keyboardUp by remember { derivedStateOf { ime.getBottom(density) > 0 } }
    val emojiShown by remember { derivedStateOf { state.reserve.value > 0f || keyboardUp } }
    Box(
        Modifier.fillMaxWidth().clipToBounds().layout { measurable, constraints ->
            val h = maxOf(ime.getBottom(this), state.reserve.value.toInt(), nav.getBottom(this) + 5.dp.roundToPx())
            val placeable = measurable.measure(constraints.copy(minHeight = 0, maxHeight = state.keyboardHeightPx.coerceAtLeast(h)))
            layout(constraints.maxWidth, h) { placeable.place(0, 0) }
        },
    ) {
        if (emojiShown) {
            // построена заранее, но видна только в режиме эмодзи
            Box(Modifier.graphicsLayer { alpha = if (state.reserve.value > 0f) 1f else 0f }) {
                EmojiPanel(height = with(density) { state.keyboardHeightPx.toDp() }, onEmoji = onEmoji)
            }
        }
    }
}
