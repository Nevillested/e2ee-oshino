import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Единый фирменный индикатор загрузки — три плавно пульсирующие точки.
/// Замена стандартному CircularProgressIndicator ВЕЗДЕ в приложении, кроме
/// мест, где во время скачивания медиа в чате показывается содержательный
/// процент (см. ТЗ пользователя — там анимация не нужна, там правда важно
/// видеть число).
///
/// "Бесшовность" — не декоративное слово, а буквальное требование: фаза
/// каждой точки — это math.sin(2π·(t - phase)) от НЕЗАТУХАЮЩЕГО линейного
/// AnimationController (repeat() без reverse). sin периодична и непрерывна,
/// поэтому в момент, когда контроллер перескакивает с t=1 обратно на t=0,
/// значение синуса не скачет (sin(0) == sin(2π)) — визуально анимация идёт
/// непрерывной волной без единого рывка на стыке цикла. Обычный
/// AnimationController(...)..repeat(reverse: true) такой гарантии не даёт:
/// на развороте скорость мгновенно меняет знак, и глаз это ловит как
/// микро-заминку.
class AppLoadingIndicator extends StatefulWidget {
  final double size;
  final Color? color;

  const AppLoadingIndicator({super.key, this.size = 24, this.color});

  @override
  State<AppLoadingIndicator> createState() => _AppLoadingIndicatorState();
}

class _AppLoadingIndicatorState extends State<AppLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    final dot = widget.size / 4.2;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(3, (i) {
              final phase = i * 0.22;
              final wave = 0.5 + 0.5 * math.sin(2 * math.pi * (t - phase));
              final scale = 0.55 + 0.45 * wave;
              final opacity = 0.35 + 0.65 * wave;
              return Opacity(
                opacity: opacity,
                child: Transform.scale(
                  scale: scale,
                  child: Container(
                    width: dot,
                    height: dot,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
