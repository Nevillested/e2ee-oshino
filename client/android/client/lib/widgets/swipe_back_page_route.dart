import 'package:flutter/material.dart';

/// Длительность "доезда" после отпускания пальца (и обычного pop без
/// жеста) — см. handleDragEnd/reverseTransitionDuration.
const _kTransitionDuration = Duration(milliseconds: 340);

/// Открытие тапом раньше вело себя отдельно от возврата (свой,
/// "телеграмный" стиль — фейд + небольшой сдвиг вместо слайда через весь
/// экран, ветвление по animation.status), но пользователь эту анимацию не
/// видел вообще ни при каком её увеличении — значит, дело было либо в
/// самом ветвлении, либо ещё в чём-то. Единый со сдвигом механизм (тот же
/// SlideTransition, что и у возврата), нарочно замедленный до 900мс,
/// подтвердил, что анимация РАБОТАЕТ и ВИДНА — теперь просто возвращаем
/// длительность в комфортный диапазон (короче, чем диагностические
/// 900мс, но всё ещё заметно длиннее, чем полностью незаметные прежние
/// варианты).
const _kPushTransitionDuration = Duration(milliseconds: 550);

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

  /// true, пока палец физически ведёт жест И пока идёт "доезд" после его
  /// отпускания (см. handleDragEnd) — всё это время анимация должна идти
  /// без ДОПОЛНИТЕЛЬНОЙ кривой (см. _LiveOrCurvedAnimation): у доезда уже
  /// есть своя кривая, зашитая прямо в animateTo/animateBack, и повторное
  /// применение кривой поверх уже искривлённого значения ломает монотонность
  /// темпа. Кривая из buildTransitions нужна только для "настоящих", идущих
  /// по времени переходов САМИ ПО СЕБЕ — открытие тапом и обычный системный
  /// pop.
  bool _liveDrag = false;

  /// Счётчик жестов — нужен, чтобы отложенный колбэк settleDone() от
  /// ПРЕДЫДУЩЕГО доезда не мог ошибочно сбросить _liveDrag, если пользователь
  /// уже успел начать новый жест до того, как старый доезд доиграл до конца.
  int _dragGeneration = 0;

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
  Duration get transitionDuration => _kPushTransitionDuration;

  @override
  Duration get reverseTransitionDuration => _kTransitionDuration;

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
    // easeInOut, а не easeOut: у easeOut производная (скорость) МАКСИМАЛЬНА
    // ровно в самом начале (по определению "ease OUT" — влетает сразу на
    // полной скорости и затормаживает к концу) — субъективно это и
    // читалось как "слишком быстрый старт". easeInOut разгоняется и
    // тормозит одинаково плавно С ОБЕИХ сторон, пик скорости — только в
    // середине.
    final effective = _LiveOrCurvedAnimation(
      parent: animation,
      curve: Curves.easeInOut,
      isLive: () => _liveDrag,
    );
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(effective),
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
        ).animate(effective),
        child: child,
      ),
    );
  }

  // --- Точки входа для жеста, которым чужой виджет (см. SwipeBackDetector)
  // напрямую двигает animation controller этого route. navigator/controller
  // — публичные геттеры самого TransitionRoute, ничего приватного/хрупкого
  // тут не используется.

  void handleDragStart() {
    _dragGeneration++;
    _liveDrag = true;
    navigator?.didStartUserGesture();
  }

  /// deltaFraction — смещение пальца за этот кадр в долях ширины экрана
  /// (положительное — вправо, "к закрытию"). Линейно, 1:1 с пальцем —
  /// именно поэтому во время живого жеста кривая отключена (см. _liveDrag):
  /// кривая, применённая к УЖЕ линейному значению, делает самое начало
  /// движения почти незаметным, а отклик — "тугим".
  void handleDragUpdate(double deltaFraction) {
    controller?.value -= deltaFraction;
  }

  /// velocityFraction — скорость пальца в момент отпускания, в долях
  /// ширины экрана в секунду.
  void handleDragEnd(double velocityFraction) {
    final ctrl = controller;
    final nav = navigator;
    if (ctrl == null || nav == null) {
      _liveDrag = false;
      return;
    }

    // _liveDrag остаётся true на всё время "доезда" — сама кривая уже
    // задана ниже, в animateTo/animateBack, и buildTransitions не должен
    // искривлять их результат ещё раз (см. комментарий там). Возвращаем
    // обычный (curved) режим только когда доезд по-настоящему завершился —
    // на этот момент controller.value уже 0 или 1, где кривая ничего не
    // меняет, так что сброс не даёт видимого скачка. Проверка поколения —
    // на случай, если пользователь успел начать новый жест до того, как
    // этот колбэк сработал: тогда сбрасывать _liveDrag уже нельзя, это
    // сломало бы уже идущий новый жест.
    final myGeneration = _dragGeneration;
    void settleDone() {
      if (_dragGeneration == myGeneration) _liveDrag = false;
    }

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
        ctrl
            .animateBack(
              0.0,
              duration: _kTransitionDuration,
              curve: Curves.easeInOut,
            )
            .whenComplete(settleDone);
      } else {
        settleDone();
      }
    } else {
      ctrl
          .animateTo(
            1.0,
            duration: _kTransitionDuration,
            curve: Curves.easeInOut,
          )
          .whenComplete(settleDone);
    }
    nav.didStopUserGesture();
  }
}

/// Animation<double>, который либо прозрачно отдаёт значение родителя как
/// есть (во время живого перетаскивания пальцем — isLive() == true), либо
/// пропускает его через кривую (во всех остальных случаях — обычный
/// программный переход, идущий по времени, где кривая уместна и нужна для
/// красивого ускорения/замедления). AnimationWithParentMixin — тот же
/// приём, которым внутри Flutter устроен сам CurvedAnimation, просто с
/// возможностью на лету решать, применять кривую или нет.
class _LiveOrCurvedAnimation extends Animation<double>
    with AnimationWithParentMixin<double> {
  _LiveOrCurvedAnimation({
    required this.parent,
    required this.curve,
    required this.isLive,
  });

  @override
  final Animation<double> parent;
  final Curve curve;
  final bool Function() isLive;

  @override
  double get value {
    final v = parent.value;
    if (isLive()) return v;
    return curve.transform(v.clamp(0.0, 1.0));
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
