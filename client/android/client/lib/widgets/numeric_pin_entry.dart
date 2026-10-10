import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Точки введённых цифр + цифровая клавиатура — используется и на экране
/// блокировки (app_lock_screen.dart, известная заранее длина кода), и при
/// настройке нового кода (app_lock_settings_screen.dart, длина 4..8 сама
/// определяется тем, сколько цифр ввёл пользователь).
class NumericPinEntry extends StatelessWidget {
  final String value;
  final int maxLength;
  final ValueChanged<String> onChanged;
  final bool showError;

  const NumericPinEntry({
    super.key,
    required this.value,
    required this.onChanged,
    this.maxLength = 8,
    this.showError = false,
  });

  void _tapDigit(String d) {
    if (value.length >= maxLength) return;
    onChanged(value + d);
  }

  void _backspace() {
    if (value.isEmpty) return;
    onChanged(value.substring(0, value.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 16,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < value.length; i++)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 5),
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: showError ? Colors.redAccent : AppColors.primary,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 32),
        _row(const ['1', '2', '3']),
        const SizedBox(height: 14),
        _row(const ['4', '5', '6']),
        const SizedBox(height: 14),
        _row(const ['7', '8', '9']),
        const SizedBox(height: 14),
        _row(const ['', '0', '⌫']),
      ],
    );
  }

  Widget _row(List<String> digits) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [for (final d in digits) _key(d)],
    );
  }

  Widget _key(String d) {
    if (d.isEmpty) return const SizedBox(width: 64, height: 64);
    final isBackspace = d == '⌫';
    return SizedBox(
      width: 64,
      height: 64,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: isBackspace ? _backspace : () => _tapDigit(d),
          child: Center(
            child: isBackspace
                ? Icon(Icons.backspace_outlined, color: AppColors.textPrimary)
                : Text(
                    d,
                    style: TextStyle(
                      fontSize: 26,
                      color: AppColors.textPrimary,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
