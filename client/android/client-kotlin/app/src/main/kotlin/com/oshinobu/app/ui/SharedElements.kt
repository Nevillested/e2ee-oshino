package com.oshinobu.app.ui

import androidx.compose.animation.AnimatedVisibilityScope
import androidx.compose.animation.ExperimentalSharedTransitionApi
import androidx.compose.animation.SharedTransitionScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier

/** Слой общих элементов вокруг навигации (см. AppNavigation). */
@OptIn(ExperimentalSharedTransitionApi::class)
val LocalSharedTransitionScope = staticCompositionLocalOf<SharedTransitionScope?> { null }

/** Анимация перехода экрана, на котором стоит элемент (её даёт composable навигации). */
val LocalNavAnimatedScope = staticCompositionLocalOf<AnimatedVisibilityScope?> { null }

/**
 * Аватар собеседника, который при переходе чат ↔ профиль перелетает из
 * шапки чата на место большого фото профиля и обратно (как Hero во
 * Flutter-клиенте). Вне навигации — обычный модификатор.
 */
@OptIn(ExperimentalSharedTransitionApi::class)
@Composable
fun Modifier.sharedPeerAvatar(accountId: String?): Modifier {
    val shared = LocalSharedTransitionScope.current
    val animated = LocalNavAnimatedScope.current
    if (shared == null || animated == null || accountId.isNullOrEmpty()) return this
    return with(shared) { this@sharedPeerAvatar.sharedElement(rememberSharedContentState("peer-avatar-$accountId"), animated) }
}
