import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Анимация удаления сообщения "как в Телеге" (её реальное название там —
/// Snap Effect / vaporize, вдохновлено щелчком Таноса) — пузырь рассыпается
/// на множество мелких частиц, которые сдувает ветром в одну сторону, а не
/// разлетаются во все стороны взрывом.
///
/// Вызывается, пока сам пузырь ещё числится в списке (просто спрятан —
/// Opacity 0, см. _dissolvingMessageIds в chat_screen.dart), ровно на его
/// месте — со стороны выглядит так, будто сообщение само рассыпается в
/// пыль, а не мгновенно исчезает и только потом на его месте что-то
/// появляется. Возвращённый Future завершается, когда частицы долетели —
/// вызывающая сторона ждёт его и только ПОСЛЕ по-настоящему убирает
/// сообщение из списка, чтобы соседние сообщения сдвинулись на
/// освободившееся место именно в этот момент, а не раньше.
///
/// [image] — уже отрисованный снимок пузыря (см. RepaintBoundary.toImage в
/// chat_screen.dart), [rect] — его положение/размер в глобальных
/// координатах на момент удаления.
Future<void> showShatterEffect(
  BuildContext context, {
  required ui.Image image,
  required Rect rect,
}) {
  final completer = Completer<void>();
  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _ShatterEffect(
      image: image,
      rect: rect,
      onComplete: () {
        entry.remove();
        image.dispose();
        completer.complete();
      },
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

class _Particle {
  final Rect srcRect;
  final Offset origin;
  final Size size;
  final double speed;
  final double rotationSpeed;
  final double delay;

  _Particle({
    required this.srcRect,
    required this.origin,
    required this.size,
    required this.speed,
    required this.rotationSpeed,
    required this.delay,
  });
}

class _ShatterEffect extends StatefulWidget {
  final ui.Image image;
  final Rect rect;
  final VoidCallback onComplete;

  const _ShatterEffect({
    required this.image,
    required this.rect,
    required this.onComplete,
  });

  @override
  State<_ShatterEffect> createState() => _ShatterEffectState();
}

class _ShatterEffectState extends State<_ShatterEffect>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<_Particle> _particles;
  late final Offset _windDirection;

  // Мелкая пыль, а не крупные осколки — "множество частиц", как просил
  // пользователь, а не десяток заметных кусков. Сетка ещё крупнее прежней —
  // частиц больше, и каждая мельче.
  static const _cols = 44;
  static const _rows = 28;

  @override
  void initState() {
    super.initState();
    final random = Random();
    // Один общий "порыв ветра" на весь эффект — по большей части влево, и
    // лишь немного вверх (не строго диагональ), с небольшим случайным
    // наклоном вокруг этого направления (узкий конус), а не индивидуальное
    // направление у каждой частицы: именно общее направление и отличает
    // "ветер сдувает" от "взрыв во все стороны".
    final windAngle = (-8 * pi / 9) + (random.nextDouble() - 0.5) * (pi / 9);
    _windDirection = Offset(cos(windAngle), sin(windAngle));
    _particles = _buildParticles(random);
    _controller =
        AnimationController(
          vsync: this,
          // Чуть быстрее прежнего (было 1500мс).
          duration: const Duration(milliseconds: 1250),
        )..forward().whenComplete(() {
          if (mounted) widget.onComplete();
        });
  }

  List<_Particle> _buildParticles(Random random) {
    final cellW = widget.rect.width / _cols;
    final cellH = widget.rect.height / _rows;
    final imgScaleX = widget.image.width / widget.rect.width;
    final imgScaleY = widget.image.height / widget.rect.height;

    // Направление "поперёк ветра" — по нему считаем задержку старта каждой
    // частицы, чтобы пыль сходила не вся разом, а сплошной волной с одного
    // края на другой (ровно как в реальном Snap Effect/Таносе), а не единым
    // хлопком.
    final sweepAxis = Offset(-_windDirection.dy, _windDirection.dx);

    final particles = <_Particle>[];
    for (var row = 0; row < _rows; row++) {
      for (var col = 0; col < _cols; col++) {
        final origin = Offset(col * cellW, row * cellH);
        final center =
            origin + Offset(cellW / 2, cellH / 2) - widget.rect.size.center(Offset.zero);
        final sweepProjection = center.dx * sweepAxis.dx + center.dy * sweepAxis.dy;
        final sweepRange = (widget.rect.width.abs() + widget.rect.height.abs());
        final sweepT = (sweepProjection / sweepRange) + 0.5; // ~0..1 по фронту волны

        particles.add(
          _Particle(
            srcRect: Rect.fromLTWH(
              origin.dx * imgScaleX,
              origin.dy * imgScaleY,
              cellW * imgScaleX,
              cellH * imgScaleY,
            ),
            origin: origin,
            size: Size(cellW, cellH),
            // Разброс скорости — не все частицы летят с одинаковой
            // скоростью, иначе пыль двигалась бы неестественно ровным
            // строем.
            speed: 0.7 + random.nextDouble() * 0.8,
            rotationSpeed: (random.nextDouble() - 0.5) * 2.2,
            delay: (sweepT.clamp(0.0, 1.0) * 0.45) + random.nextDouble() * 0.2,
          ),
        );
      }
    }
    return particles;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fromRect(
      rect: widget.rect,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return CustomPaint(
              size: widget.rect.size,
              painter: _ShatterPainter(
                image: widget.image,
                particles: _particles,
                windDirection: _windDirection,
                t: _controller.value,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ShatterPainter extends CustomPainter {
  final ui.Image image;
  final List<_Particle> particles;
  final Offset windDirection;
  final double t;

  _ShatterPainter({
    required this.image,
    required this.particles,
    required this.windDirection,
    required this.t,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      final localT = ((t - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
      if (localT <= 0) continue;
      final eased = Curves.easeIn.transform(localT);
      // Было 130 — в полтора раза меньше, чтобы пыль улетала не так далеко.
      // Немного дальше прежнего (было 130/1.5 ≈ 87).
      final travel = 115.0 * p.speed * eased;
      final offset = windDirection * travel;
      final rotation = p.rotationSpeed * eased;
      final opacity = 1 - Curves.easeOut.transform(localT);
      // Частицы слегка "истончаются" по мере полёта — не только гаснут, но
      // и чуть съёживаются, как настоящая рассеивающаяся пыль.
      final scale = 1 - eased * 0.35;
      _drawParticle(canvas, p, offset, rotation, opacity, scale);
    }
  }

  void _drawParticle(
    Canvas canvas,
    _Particle p,
    Offset offset,
    double rotation,
    double opacity,
    double scale,
  ) {
    if (opacity <= 0) return;
    final center =
        p.origin + Offset(p.size.width / 2, p.size.height / 2) + offset;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation);
    final dstRect = Rect.fromCenter(
      center: Offset.zero,
      width: p.size.width * scale,
      height: p.size.height * scale,
    );
    final paint = Paint()
      ..filterQuality = FilterQuality.low
      ..color = Color.fromRGBO(255, 255, 255, opacity);
    canvas.drawImageRect(image, p.srcRect, dstRect, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ShatterPainter oldDelegate) =>
      oldDelegate.t != t;
}
