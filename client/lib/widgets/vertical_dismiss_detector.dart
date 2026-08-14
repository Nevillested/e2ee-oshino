import 'package:flutter/material.dart';

/// Оборачивает child в жест "смахнуть вверх/вниз, чтобы закрыть экран" —
/// общая механика для всех полноэкранных превью в приложении: во время
/// свайпа child тащится за пальцем и слегка гаснет; если свайпнули
/// достаточно далеко или быстро — доигрывает уход в ту же сторону и
/// вызывает Navigator.pop, иначе плавно возвращается на место.
class VerticalDismissDetector extends StatefulWidget {
  final Widget child;
  // false, пока фото внутри увеличено (см. MediaViewerScreen) — иначе
  // попытка подвигать увеличенное фото пальцем вверх/вниз наполовину
  // срывалась бы в закрытие просмотрщика, деля жест с этим детектором.
  final bool enabled;
  const VerticalDismissDetector({
    super.key,
    required this.child,
    this.enabled = true,
  });

  @override
  State<VerticalDismissDetector> createState() =>
      _VerticalDismissDetectorState();
}

class _VerticalDismissDetectorState extends State<VerticalDismissDetector>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dragAnimController;
  Animation<Offset>? _offsetAnim;
  Offset _dragOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    _dragAnimController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 220),
        )..addListener(() {
          if (_offsetAnim != null)
            setState(() => _dragOffset = _offsetAnim!.value);
        });
  }

  @override
  void dispose() {
    _dragAnimController.dispose();
    super.dispose();
  }

  void _onVerticalDragStart(DragStartDetails details) =>
      _dragAnimController.stop();

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    setState(() => _dragOffset += Offset(0, details.delta.dy));
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    final screenHeight = MediaQuery.of(context).size.height;
    final velocity = details.primaryVelocity ?? 0;
    final shouldDismiss =
        _dragOffset.dy.abs() > screenHeight * 0.16 || velocity.abs() > 700;

    if (shouldDismiss) {
      final goingDown = velocity != 0 ? velocity > 0 : _dragOffset.dy >= 0;
      _animateOffset(
        Offset(0, goingDown ? screenHeight : -screenHeight),
        thenPop: true,
      );
    } else {
      _animateOffset(Offset.zero, thenPop: false);
    }
  }

  void _animateOffset(Offset target, {required bool thenPop}) {
    _offsetAnim = Tween<Offset>(begin: _dragOffset, end: target).animate(
      CurvedAnimation(parent: _dragAnimController, curve: Curves.easeOut),
    );
    _dragAnimController.forward(from: 0).whenComplete(() {
      if (thenPop && mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final progress = (_dragOffset.dy.abs() / (screenHeight * 0.5)).clamp(
      0.0,
      1.0,
    );
    final opacity = 1.0 - progress * 0.6;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: widget.enabled ? _onVerticalDragStart : null,
      onVerticalDragUpdate: widget.enabled ? _onVerticalDragUpdate : null,
      onVerticalDragEnd: widget.enabled ? _onVerticalDragEnd : null,
      child: Transform.translate(
        offset: _dragOffset,
        child: Opacity(opacity: opacity, child: widget.child),
      ),
    );
  }
}
