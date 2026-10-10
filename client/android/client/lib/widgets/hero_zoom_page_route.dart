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
          // fillColor у SharedAxisTransition сам по себе не спасает —
          // непрозрачность ВСЕГО контента (включая этот фон) ramp'ится с
          // той же скоростью, что и остальная анимация (масштаб/fade), то
          // есть довольно медленно. Всё это время старый экран (шапка
          // чата) виден СКВОЗЬ ещё полупрозрачный новый — именно это
          // пользователь видел как мелькающий "прямоугольник" (на самом
          // деле — старая шапка чата, просвечивающая позади). Отдельный
          // фон, который сам доходит до непрозрачности практически сразу
          // (за первые ~15% длительности), перекрывает старый экран рано,
          // пока Hero и масштабирование продолжают анимироваться уже
          // поверх сплошного фона.
          return Stack(
            children: [
              FadeTransition(
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: const Interval(0.0, 0.15),
                ),
                child: ColoredBox(color: AppColors.background),
              ),
              SharedAxisTransition(
                animation: animation,
                secondaryAnimation: secondaryAnimation,
                transitionType: SharedAxisTransitionType.scaled,
                fillColor: Colors.transparent,
                child: child,
              ),
            ],
          );
        },
        transitionDuration: const Duration(milliseconds: 350),
        reverseTransitionDuration: const Duration(milliseconds: 300),
      );
}
