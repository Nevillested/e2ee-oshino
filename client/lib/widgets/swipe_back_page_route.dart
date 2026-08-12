import 'package:flutter/material.dart';

/// Полностью самописный интерактивный переход "потянуть экран вправо,
/// открыв предыдущий" — как в Telegram для Android: свайп работает из
/// ЛЮБОЙ точки экрана (не только от края, в отличие от системного жеста
/// и от CupertinoPageRoute), палец напрямую двигает анимацию перехода, и
/// можно как довести жест до конца, так и вернуть его назад, не отпуская
/// палец. Flutter такого готового решения не даёт — здесь тот же самый
/// приём, которым реализован системный edge-свайп у CupertinoPageRoute
/// (controller.value == 1 — экран показан полностью, 0 — полностью скрыт,
/// и это значение можно двигать вручную), просто без ограничения на
/// стартовую точку жеста.
class SwipeBackPageRoute<T> extends PageRoute<T> {
  SwipeBackPageRoute({required this.builder, super.settings});

  final WidgetBuilder builder;

  @override
  bool get opaque => true;

  @override
  bool get barrierDismissible => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 300);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return builder(context);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(curved),
      child: DecoratedBoxTransition(
        decoration: DecorationTween(
          begin: const BoxDecoration(
            boxShadow: [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 12,
                spreadRadius: -2,
              ),
            ],
          ),
          end: const BoxDecoration(
            boxShadow: [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 12,
                spreadRadius: -2,
              ),
            ],
          ),
        ).animate(curved),
        child: child,
      ),
    );
  }

  // --- Точки входа для жеста, которым чужой виджет (см. SwipeBackDetector)
  // напрямую двигает animation controller этого route. navigator/controller
  // — публичные геттеры самого TransitionRoute, ничего приватного/хрупкого
  // тут не используется.

  void handleDragStart() {
    navigator?.didStartUserGesture();
  }

  /// deltaFraction — смещение пальца за этот кадр в долях ширины экрана
  /// (положительное — вправо, "к закрытию").
  void handleDragUpdate(double deltaFraction) {
    controller?.value -= deltaFraction;
  }

  /// velocityFraction — скорость пальца в момент отпускания, в долях
  /// ширины экрана в секунду.
  void handleDragEnd(double velocityFraction) {
    final ctrl = controller;
    final nav = navigator;
    if (ctrl == null || nav == null) return;

    const flingVelocity = 1.0;
    final bool shouldPop;
    if (velocityFraction.abs() >= flingVelocity) {
      shouldPop = velocityFraction > 0;
    } else {
      shouldPop = ctrl.value < 0.5;
    }

    if (shouldPop) {
      if (nav.userGestureInProgress) {
        nav.pop();
      }
      if (ctrl.isAnimating) {
        ctrl.animateBack(
          0.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    } else {
      ctrl.animateTo(
        1.0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
    nav.didStopUserGesture();
  }
}

/// Оборачивает экран, которым управляет SwipeBackPageRoute: ловит
/// горизонтальный свайп из любой точки и напрямую двигает переход. Если
/// поп сейчас заблокирован (enabled=false — например, активен режим
/// выбора сообщений), интерактивная анимация не запускается, но при
/// достаточно длинном свайпе всё равно срабатывает [onBlockedSwipe] — тот
/// же жест должен вести себя предсказуемо, а не просто ничего не делать.
class SwipeBackDetector extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final VoidCallback? onBlockedSwipe;

  const SwipeBackDetector({
    super.key,
    required this.child,
    this.enabled = true,
    this.onBlockedSwipe,
  });

  @override
  State<SwipeBackDetector> createState() => _SwipeBackDetectorState();
}

class _SwipeBackDetectorState extends State<SwipeBackDetector> {
  SwipeBackPageRoute<dynamic>? _route;
  double _accumDx = 0;

  void _onDragStart(DragStartDetails details) {
    _accumDx = 0;
    _route = null;
    if (!widget.enabled) return;

    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    if (route is SwipeBackPageRoute && navigator.canPop()) {
      _route = route;
      route.handleDragStart();
    }
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _accumDx += details.delta.dx;
    final route = _route;
    if (route == null) return;
    final width = MediaQuery.of(context).size.width;
    if (width <= 0) return;
    route.handleDragUpdate(details.delta.dx / width);
  }

  void _onDragEnd(DragEndDetails details) {
    final route = _route;
    _route = null;
    if (route != null) {
      final width = MediaQuery.of(context).size.width;
      final velocityFraction = width > 0
          ? details.velocity.pixelsPerSecond.dx / width
          : 0.0;
      route.handleDragEnd(velocityFraction);
      return;
    }
    if (!widget.enabled && _accumDx > 80) {
      widget.onBlockedSwipe?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      child: widget.child,
    );
  }
}
