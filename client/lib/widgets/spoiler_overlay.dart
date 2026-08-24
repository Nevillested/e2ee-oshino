import 'dart:math';
import 'package:flutter/material.dart';

/// Заблюренное фото + анимированная "мерцающая пыль" поверх — тот самый
/// эффект спойлера из Телеги (см. скриншот пользователя): не статичный
/// блюр+иконка, а живая рябь мелких белых точек, каждая мигает по своей
/// фазе. Раньше здесь были блюр+затемнение+иконка "глаз"+подпись — Телега
/// вообще не рисует ни иконку, ни текст поверх фото, полагается только на
/// подпись сообщения под пузырём (если она есть).
class SpoilerSparkleOverlay extends StatefulWidget {
  final Widget blurredChild;

  const SpoilerSparkleOverlay({super.key, required this.blurredChild});

  @override
  State<SpoilerSparkleOverlay> createState() => _SpoilerSparkleOverlayState();
}

class _SpoilerSparkleOverlayState extends State<SpoilerSparkleOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // Период произвольный — не должен совпадать с фазами точек (см.
    // _SparklePainter._dots), иначе мерцание выглядело бы одним
    // синхронным "пульсом" вместо живой ряби.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.blurredChild,
        IgnorePointer(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return CustomPaint(
                painter: _SparklePainter(t: _controller.value),
                size: Size.infinite,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Dot {
  final double dx; // 0..1 относительно ширины
  final double dy; // 0..1 относительно высоты
  final double radius;
  final double phase; // сдвиг по времени — чтобы мигали не синхронно
  final double speed; // во сколько раз быстрее/медленнее общего периода

  const _Dot(this.dx, this.dy, this.radius, this.phase, this.speed);
}

class _SparklePainter extends CustomPainter {
  final double t;

  _SparklePainter({required this.t});

  // Один и тот же засеянный список точек на всё время жизни painter'а —
  // фиксированные позиции, "мерцает" только прозрачность, а не сама пыль
  // прыгает по разным местам на каждый кадр (иначе выглядело бы как шум
  // телевизора, а не как живая пыль).
  static final List<_Dot> _dots = _generateDots();

  static List<_Dot> _generateDots() {
    final random = Random(7);
    // Плотность подобрана на глаз под типичный размер фото-пузыря в чате
    // (см. _photoPreview) — заметная "пыль", но не сплошной шум.
    const count = 260;
    return List.generate(count, (_) {
      return _Dot(
        random.nextDouble(),
        random.nextDouble(),
        0.7 + random.nextDouble() * 1.6,
        random.nextDouble(),
        0.6 + random.nextDouble() * 0.9,
      );
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    for (final dot in _dots) {
      // Каждая точка мигает по синусоиде со своей фазой/скоростью —
      // независимое мерцание без синхронных вспышек.
      final phaseT = (t * dot.speed + dot.phase) % 1.0;
      final opacity = (sin(phaseT * 2 * pi) * 0.5 + 0.5);
      // Возводим в степень — большую часть времени точка тусклая/невидима,
      // ярко вспыхивает только на пике (ближе к поведению настоящей пыли,
      // а не ровного дыхания).
      final eased = opacity * opacity * opacity;
      if (eased < 0.03) continue;
      paint.color = Colors.white.withValues(alpha: eased);
      canvas.drawCircle(
        Offset(dot.dx * size.width, dot.dy * size.height),
        dot.radius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SparklePainter oldDelegate) =>
      oldDelegate.t != t;
}
