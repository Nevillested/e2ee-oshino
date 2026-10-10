import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import '../services/app_lock_store.dart';
import '../theme/app_theme.dart';
import '../widgets/numeric_pin_entry.dart';
import '../widgets/theme_reactive.dart';

enum _Step { enter, confirm }

/// Задать/изменить PIN — два шага: ввод (4..8 цифр, длину выбирает сам
/// пользователь) и повтор того же кода той же длины. Возвращает true через
/// Navigator.pop, если PIN успешно сохранён — вызывающая сторона
/// (app_lock_settings_screen.dart) на этом основании включает то, что
/// требовало PIN (саму блокировку или биометрию).
class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key});

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  _Step _step = _Step.enter;
  String _pin = '';
  String _confirmPin = '';
  bool _error = false;

  void _onEnterChanged(String v) {
    setState(() {
      _pin = v;
      _error = false;
    });
  }

  void _submitEnter() {
    if (_pin.length < 4 || _pin.length > 8) return;
    setState(() => _step = _Step.confirm);
  }

  Future<void> _onConfirmChanged(String v) async {
    setState(() {
      _confirmPin = v;
      _error = false;
    });
    if (v.length < _pin.length) return;
    if (v == _pin) {
      await AppLockStore.setPin(_pin);
      if (!mounted) return;
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _error = true;
      _confirmPin = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    return ThemeReactive(builder: (context) => _build(context));
  }

  Widget _build(BuildContext context) {
    final entering = _step == _Step.enter;
    return Scaffold(
      appBar: AppBar(title: Text(tr('applock.pin'))),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  entering
                      ? tr('applock.newPin')
                      : (_error
                            ? tr('applock.pinMismatch')
                            : tr('applock.confirmPin')),
                  style: TextStyle(
                    color: _error ? Colors.redAccent : AppColors.textPrimary,
                    fontSize: 16,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (entering) ...[
                  NumericPinEntry(
                    value: _pin,
                    maxLength: 8,
                    onChanged: _onEnterChanged,
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: (_pin.length >= 4 && _pin.length <= 8)
                        ? _submitEnter
                        : null,
                    child: Text(tr('common.next')),
                  ),
                ] else
                  NumericPinEntry(
                    value: _confirmPin,
                    maxLength: _pin.length,
                    showError: _error,
                    onChanged: _onConfirmChanged,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
