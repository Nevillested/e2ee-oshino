import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../theme/app_theme.dart';
import 'safe_memory_image.dart';

/// Фото под спойлером (блюр+пыль, см. SpoilerSparkleOverlay ниже) с плавным
/// исчезновением спойлера при раскрытии (ТЗ пользователя: "сейчас он
/// просто резко исчезает") — чёткое фото всегда отрисовано НИЖЕ, спойлер
/// сверху просто плавно растворяется, открывая уже готовую картинку, а не
/// всё дерево виджета скачком меняется местами (как было раньше — жёсткий
/// isHiddenSpoiler ? спойлер : фото в chat_screen.dart).
class SpoilerFadeImage extends StatefulWidget {
  final Uint8List bytes;
  final double side;
  final bool revealed;

  const SpoilerFadeImage({
    super.key,
    required this.bytes,
    required this.side,
    required this.revealed,
  });

  @override
  State<SpoilerFadeImage> createState() => _SpoilerFadeImageState();
}

class _SpoilerFadeImageState extends State<SpoilerFadeImage> {
  // Спойлер-слой убирается из дерева насовсем ПОСЛЕ того, как затухание
  // реально доиграло (см. onEnd ниже), а не сразу по revealed=true —
  // иначе видимого затухания просто не успело бы случиться. Пока слой
  // смонтирован (даже уже прозрачный) — крутится его собственный Ticker
  // (см. SpoilerSparkleOverlay), так что раз анимация раскрытия
  // необратима в рамках сессии экрана (см. _revealedSpoilerIds в
  // chat_screen.dart), после её конца он снимается насовсем.
  late bool _showSpoiler = !widget.revealed;

  @override
  Widget build(BuildContext context) {
    final image = SafeMemoryImage(
      bytes: widget.bytes,
      fit: BoxFit.cover,
      cacheWidth: (widget.side * 2).round(),
    );
    if (!_showSpoiler) return image;
    return Stack(
      fit: StackFit.expand,
      children: [
        image,
        IgnorePointer(
          // Пока не раскрыт — сам тап должен доходить до GestureDetector
          // родителя (handleTap в chat_screen.dart), а не потеряться в
          // этом слое, поэтому ignoring не зависит от revealed.
          child: AnimatedOpacity(
            opacity: widget.revealed ? 0 : 1,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOut,
            onEnd: () {
              if (widget.revealed && mounted) {
                setState(() => _showSpoiler = false);
              }
            },
            // Реальный баг (жалоба пользователя, скриншот): по самому краю
            // тайла было видно чёткое фото сквозь спойлер. Причина —
            // ImageFilter.blur у самой границы даёт частично прозрачные
            // пиксели (блюр "зачерпывает" пустоту снаружи изображения), и
            // сквозь эту прозрачность просвечивал чёткий слой ПОД ним (см.
            // image в самом низу Stack). Непрозрачная подложка ТОЧНО под
            // блюром (а не под всем Stack — иначе перекрыла бы чёткое фото
            // и после раскрытия) закрывает именно эту утечку, сама
            // затухает в общем AnimatedOpacity вместе с блюром.
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: AppColors.surface),
                SpoilerSparkleOverlay(
                  blurredChild: ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: image,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

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
  // РЕАЛЬНЫЙ баг (жалоба пользователя: "анимация не бесшовная") — раньше
  // здесь стоял обычный AnimationController..repeat(): его value — это
  // ПИЛА 0→1→0→1..., с настоящим разрывом (скачком с 1.0 назад на 0.0) в
  // конце каждого 3-секундного круга. В _SparklePainter фаза каждой точки
  // считалась как (value * dot.speed + dot.phase) % 1.0 — а раз dot.speed
  // почти никогда не целое число (см. _generateDots — случайное 0.6..1.5),
  // то (1.0 * speed) % 1 практически никогда не совпадает с (0.0 * speed)
  // % 1 = 0: у КАЖДОЙ точки в момент разрыва мерцание скачком меняло фазу
  // — раз в 3 секунды вся "пыль" видимо дёргалась разом.
  //
  // Правильный источник времени — не значение, которое само периодически
  // обнуляется, а НЕПРЕРЫВНО растущие секунды с момента появления виджета
  // (обычный Ticker, без AnimationController поверх). % 1.0 внутри
  // _SparklePainter при этом остаётся (это устройство самого sin —
  // sin(2π·(x % 1)) математически тождественно sin(2π·x) для любого x, без
  // единого разрыва), но применяется уже к значению, которое само никогда
  // не прыгает назад — значит и результат нигде не прыгает.
  late final Ticker _ticker;
  final _elapsed = ValueNotifier<Duration>(Duration.zero);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) => _elapsed.value = elapsed)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _elapsed.dispose();
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
            animation: _elapsed,
            builder: (context, _) {
              return CustomPaint(
                painter: _SparklePainter(
                  tSeconds: _elapsed.value.inMicroseconds / 1e6,
                ),
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
  // Секунды с момента появления виджета — непрерывно растущие, НИКОГДА не
  // обнуляются сами по себе (в отличие от прежнего t из AnimationController,
  // см. комментарий у _SpoilerSparkleOverlayState). periodSeconds — тот же
  // смысл, что раньше был у duration контроллера: во сколько секунд
  // укладывается "один оборот" при dot.speed == 1.
  final double tSeconds;
  static const _periodSeconds = 3.0;

  _SparklePainter({required this.tSeconds});

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
      final phaseT = (tSeconds / _periodSeconds * dot.speed + dot.phase) % 1.0;
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
      oldDelegate.tSeconds != tSeconds;
}
