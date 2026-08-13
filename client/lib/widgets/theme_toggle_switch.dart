import 'package:flutter/material.dart';

/// Flutter-приближение присланного переключателя (index.html/style.css/
/// script.js в чате) — тумблер-лампочка: тёмный жёлоб, шарик-"лампочка"
/// внутри тускло-серый в выключенном состоянии и светится тёплым жёлтым,
/// когда включено. Один в один CSS (радиальные градиенты, псевдоэлементы
/// "вилки" слева) переносить не имеет смысла — Flutter рисует эту же идею
/// своими средствами, но дух (тёмный жёлоб + светящийся шарик) сохранён.
class ThemeToggleSwitch extends StatelessWidget {
  final bool isOn;
  final ValueChanged<bool> onChanged;

  const ThemeToggleSwitch({
    super.key,
    required this.isOn,
    required this.onChanged,
  });

  static const double _width = 84;
  static const double _height = 42;
  static const double _thumbSize = 34;
  static const _duration = Duration(milliseconds: 300);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!isOn),
      child: Container(
        width: _width,
        height: _height,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_height / 2),
          color: const Color(0xFF34363B),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
            BoxShadow(
              color: Colors.white.withValues(alpha: 0.04),
              blurRadius: 0,
              spreadRadius: -1,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: AnimatedAlign(
          duration: _duration,
          curve: Curves.easeInOut,
          alignment: isOn ? Alignment.centerRight : Alignment.centerLeft,
          child: AnimatedContainer(
            duration: _duration,
            curve: Curves.easeInOut,
            width: _thumbSize,
            height: _thumbSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                center: const Alignment(-0.3, -0.4),
                colors: isOn
                    ? const [Color(0xFFFFF3C4), Color(0xFFFFC107)]
                    : const [Color(0xFF7A7D82), Color(0xFF48494D)],
              ),
              boxShadow: isOn
                  ? [
                      BoxShadow(
                        color: const Color(0xFFFFC107).withValues(alpha: 0.65),
                        blurRadius: 12,
                        spreadRadius: 1,
                      ),
                    ]
                  : const [],
            ),
          ),
        ),
      ),
    );
  }
}
