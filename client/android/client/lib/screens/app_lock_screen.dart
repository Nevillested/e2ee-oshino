import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import '../services/app_lock_store.dart';
import '../services/biometric_auth.dart';
import '../theme/app_theme.dart';
import '../widgets/numeric_pin_entry.dart';
import '../widgets/theme_reactive.dart';

/// Полноэкранная блокировка — показывается поверх ВСЕГО приложения (см.
/// AppLockGate), пока пользователь не пройдёт вход. Системный back
/// намеренно ничего не делает (PopScope в AppLockGate) — иначе он бы
/// "протекал" в то, что скрыто под этим экраном.
class AppLockScreen extends StatefulWidget {
  final VoidCallback onUnlocked;

  const AppLockScreen({super.key, required this.onUnlocked});

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  String _pin = '';
  bool _error = false;
  int _biometricFailCount = 0;
  bool _biometricLockedOut = false;
  bool _biometricInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometric());
  }

  Future<void> _tryBiometric() async {
    if (_biometricInFlight || _biometricLockedOut) return;
    if (!AppLockStore.notifier.value.biometricEnabled) return;
    _biometricInFlight = true;
    final ok = await BiometricAuth.authenticate(
      tr('applock.useBiometricReason'),
    );
    _biometricInFlight = false;
    if (!mounted) return;
    if (ok) {
      widget.onUnlocked();
      return;
    }
    // См. ТЗ пользователя: 3 неудачные попытки биометрии — дальше только
    // PIN, без повторных системных диалогов до следующего раза, когда
    // экран блокировки откроется заново.
    _biometricFailCount++;
    if (_biometricFailCount >= 3) {
      setState(() => _biometricLockedOut = true);
    }
  }

  Future<void> _onPinChanged(String value) async {
    setState(() {
      _pin = value;
      _error = false;
    });
    final targetLength = AppLockStore.notifier.value.pinLength;
    if (value.length < targetLength) return;
    final ok = await AppLockStore.verifyPin(value);
    if (!mounted) return;
    if (ok) {
      widget.onUnlocked();
      return;
    }
    setState(() {
      _error = true;
      _pin = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    return ThemeReactive(builder: (context) => _build(context));
  }

  Widget _build(BuildContext context) {
    final settings = AppLockStore.notifier.value;
    final showBiometricButton = settings.biometricEnabled && !_biometricLockedOut;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 48, color: AppColors.primary),
                const SizedBox(height: 12),
                Text(
                  _error ? tr('applock.wrongPin') : tr('applock.enterPin'),
                  style: TextStyle(
                    color: _error ? Colors.redAccent : AppColors.textPrimary,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 24),
                NumericPinEntry(
                  value: _pin,
                  maxLength: settings.pinLength,
                  showError: _error,
                  onChanged: _onPinChanged,
                ),
                if (showBiometricButton) ...[
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: _tryBiometric,
                    icon: Icon(Icons.fingerprint, color: AppColors.primary),
                    label: Text(tr('applock.unlockWithBiometric')),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
