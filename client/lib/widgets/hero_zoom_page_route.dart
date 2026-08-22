import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Переход "зум" для экрана чужого профиля (см. PeerProfileScreen) — Hero
/// (см. тег на аватаре в chat_screen.dart/peer_profile_screen.dart) даёт
/// сам "разлёт" аватарки от шапки чата до крупного фото на новом экране,
/// а этот PageRoute отвечает за остальное содержимое страницы вокруг неё
/// (SharedAxisTransitionType.scaled — тот же пакет animations, что уже
/// используется для нижнего таб-бара, отдельной кастомной анимации тут
/// изобретать не пришлось). И push, и системный/кнопочный pop проигрывают
/// один и тот же переход в прямом/обратном направлении — стандартное
/// поведение Navigator для Hero, ничего специально настраивать не нужно.
class HeroZoomPageRoute<T> extends PageRouteBuilder<T> {
  HeroZoomPageRoute({required WidgetBuilder builder})
    : super(
        pageBuilder: (context, animation, secondaryAnimation) =>
            builder(context),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return SharedAxisTransition(
            animation: animation,
            secondaryAnimation: secondaryAnimation,
            transitionType: SharedAxisTransitionType.scaled,
            fillColor: AppColors.background,
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 350),
        reverseTransitionDuration: const Duration(milliseconds: 300),
      );
}
