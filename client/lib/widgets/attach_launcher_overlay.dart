import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

enum AttachMenuChoice { media, files }

const double _kArrowLength = 70.0;
const double _kIconCircleSize = 48.0;
const double _kIconSize = 22.0;

double _safeClampX(double v, double lo, double hi) =>
    lo >= hi ? lo : v.clamp(lo, hi);

/// Короткая анимация-развилка по нажатию на скрепку: экран затемняется, от
/// скрепки выезжают две стрелки к иконкам "Медиа" и "Файлы". Системный
/// диалог выбора файла (file_picker) — отдельный экран ОС, поверх него
/// ничего своего не нарисовать, поэтому вся кастомная часть UI выбора живёт
/// ДО его вызова, здесь. По образцу showChatListContextMenu
/// (chat_list_context_menu.dart) — OverlayEntry, а не showDialog: тап мимо
/// закрывает меню, не задевая остальной Navigator.
Future<AttachMenuChoice?> showAttachLauncherOverlay(
  BuildContext context, {
  required GlobalKey anchorKey,
  // Тот же приём, что и у showMessageContextMenu (message_context_menu.dart)
  // — отдаёт вызывающей стороне функцию принудительного закрытия, чтобы
  // ChatScreen мог перехватить системный back/свайп-назад (см.
  // _closeContextMenu/PopScope/SwipeBackDetector там) и закрыть ЭТОТ оверлей
  // вместо того, чтобы уйти с экрана, оставив его висеть поверх следующего.
  void Function(VoidCallback closeMenu)? onOpened,
}) {
  final renderBox =
      anchorKey.currentContext?.findRenderObject() as RenderBox?;
  if (renderBox == null) return Future.value(null);
  final anchor = renderBox.localToGlobal(
    renderBox.size.center(Offset.zero),
  );

  final completer = Completer<AttachMenuChoice?>();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _AttachLauncherOverlay(
      anchor: anchor,
      onOpened: onOpened,
      onClose: (result) {
        if (!completer.isCompleted) completer.complete(result);
        entry.remove();
      },
    ),
  );
  Overlay.of(context, rootOverlay: true).insert(entry);
  return completer.future;
}

class _AttachLauncherOverlay extends StatefulWidget {
  final Offset anchor;
  final void Function(VoidCallback closeMenu)? onOpened;
  final void Function(AttachMenuChoice? result) onClose;

  const _AttachLauncherOverlay({
    required this.anchor,
    required this.onOpened,
    required this.onClose,
  });

  @override
  State<_AttachLauncherOverlay> createState() =>
      _AttachLauncherOverlayState();
}

class _AttachLauncherOverlayState extends State<_AttachLauncherOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    // Постфреймом — как и в showMessageContextMenu: initState стреляет
    // внутри фазы построения дерева, а setState у ChatScreen (которому
    // передаётся эта функция) в эту секунду делать нельзя.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onOpened?.call(() => _close(null));
    });
  }

  void _close(AttachMenuChoice? result) {
    if (_closing) return;
    _closing = true;
    _controller.reverse().whenComplete(() => widget.onClose(result));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    const margin = 28.0;

    // Диагональ 45° в обе стороны от скрепки — длина стрелки
    // (_kArrowLength) фиксирована, но X конечной точки поджимаем к краям
    // экрана, чтобы кружок-иконка не срезался о край на узких телефонах,
    // если скрепка стоит близко к краю композера.
    final leftEnd = Offset(
      _safeClampX(
        widget.anchor.dx - _kArrowLength * math.sqrt1_2,
        margin,
        size.width - margin,
      ),
      widget.anchor.dy - _kArrowLength * math.sqrt1_2,
    );
    final rightEnd = Offset(
      _safeClampX(
        widget.anchor.dx + _kArrowLength * math.sqrt1_2,
        margin,
        size.width - margin,
      ),
      widget.anchor.dy - _kArrowLength * math.sqrt1_2,
    );

    final curved = CurvedAnimation(
      parent: _controller,
      curve: Curves.fastOutSlowIn,
      reverseCurve: Curves.easeIn,
    );

    return AnimatedBuilder(
      animation: curved,
      builder: (context, _) {
        final t = curved.value;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _close(null),
                child: Container(color: Colors.black.withValues(alpha: 0.55 * t)),
              ),
            ),
            // Клон скрепки поверх затемнения — реальная кнопка композера
            // под оверлеем гаснет вместе с фоном, а этот клон в той же
            // точке выглядит так, будто она осталась яркой.
            Positioned(
              left: widget.anchor.dx - 12,
              top: widget.anchor.dy - 12,
              child: Opacity(
                opacity: t,
                child: const Icon(Icons.attach_file, color: Colors.white, size: 24),
              ),
            ),
            // IgnorePointer — CustomPaint без child по умолчанию перехватывает
            // хиты по ВСЕЙ площади своего size (в т.ч. там, где ничего не
            // нарисовано), а тут size: Size.infinite — без этого стрелки
            // глушили тап по затемнению насквозь, и отмена тапом мимо не
            // работала вообще.
            IgnorePointer(
              child: CustomPaint(
                size: Size.infinite,
                painter: _ArrowPainter(
                  start: widget.anchor,
                  end: _pullBack(widget.anchor, leftEnd),
                  progress: t,
                ),
              ),
            ),
            IgnorePointer(
              child: CustomPaint(
                size: Size.infinite,
                painter: _ArrowPainter(
                  start: widget.anchor,
                  end: _pullBack(widget.anchor, rightEnd),
                  progress: t,
                ),
              ),
            ),
            _menuIcon(
              center: leftEnd,
              t: t,
              icon: Icons.perm_media_outlined,
              onTap: () => _close(AttachMenuChoice.media),
            ),
            _menuIcon(
              center: rightEnd,
              t: t,
              icon: Icons.insert_drive_file_outlined,
              onTap: () => _close(AttachMenuChoice.files),
            ),
          ],
        );
      },
    );
  }

  /// Кружок-иконка (радиус _kIconCircleSize/2) центрирован ровно в конце
  /// стрелки — без поджатия наконечник стрелки рисовался бы ПОД иконкой и
  /// был бы не виден (сама иконка рисуется поверх, позже в Stack). Отступаем
  /// точку, до которой реально рисуется линия+наконечник, на радиус кружка
  /// плюс небольшой зазор, чтобы стрелка визуально утыкалась В иконку, а не
  /// пряталась за ней.
  Offset _pullBack(Offset start, Offset end) {
    final dir = end - start;
    final length = dir.distance;
    if (length <= 0) return end;
    final pullback = _kIconCircleSize / 2 + 6;
    if (pullback >= length) return start;
    return end - dir * (pullback / length);
  }

  Widget _menuIcon({
    required Offset center,
    required double t,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Positioned(
      left: center.dx - _kIconCircleSize / 2,
      top: center.dy - _kIconCircleSize / 2,
      child: Opacity(
        opacity: t,
        child: Transform.scale(
          scale: 0.4 + 0.6 * t,
          child: Material(
            color: AppColors.primary,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: _kIconCircleSize,
                height: _kIconCircleSize,
                child: Icon(icon, color: Colors.white, size: _kIconSize),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  final Offset start;
  final Offset end;
  final double progress;

  _ArrowPainter({required this.start, required this.end, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final tip = Offset.lerp(start, end, progress)!;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: progress)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(start, tip, paint);

    if (progress < 0.15) return;
    final direction = (end - start);
    final angle = math.atan2(direction.dy, direction.dx);
    const headLength = 10.0;
    const headAngle = 0.5; // радианы
    final p1 = tip - Offset(
      headLength * math.cos(angle - headAngle),
      headLength * math.sin(angle - headAngle),
    );
    final p2 = tip - Offset(
      headLength * math.cos(angle + headAngle),
      headLength * math.sin(angle + headAngle),
    );
    final headPaint = Paint()
      ..color = Colors.white.withValues(alpha: progress)
      ..style = PaintingStyle.fill;
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(p1.dx, p1.dy)
        ..lineTo(p2.dx, p2.dy)
        ..close(),
      headPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.start != start ||
      oldDelegate.end != end;
}
