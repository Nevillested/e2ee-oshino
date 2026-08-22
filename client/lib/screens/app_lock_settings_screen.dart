import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import '../services/app_lock_store.dart';
import '../services/biometric_auth.dart';
import '../theme/app_theme.dart';
import '../widgets/theme_reactive.dart';
import 'pin_setup_screen.dart';

const _timeoutOptions = [30, 60, 120, 300, 600, 900, 1800, 3600, 7200];

/// "Вход в приложение" — статус/таймаут/PIN/биометрия, всё локально (см.
/// AppLockStore — ничего из этого не уходит на сервер).
class AppLockSettingsScreen extends StatefulWidget {
  const AppLockSettingsScreen({super.key});

  @override
  State<AppLockSettingsScreen> createState() => _AppLockSettingsScreenState();
}

class _AppLockSettingsScreenState extends State<AppLockSettingsScreen> {
  BiometricCapability? _capability;
  bool _capabilityLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadCapability();
  }

  Future<void> _loadCapability() async {
    final cap = await BiometricAuth.detectCapability();
    if (!mounted) return;
    setState(() {
      _capability = cap;
      _capabilityLoaded = true;
    });
  }

  Future<bool> _ensurePin(BuildContext context) async {
    if (AppLockStore.notifier.value.hasPin) return true;
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const PinSetupScreen()),
    );
    return result == true;
  }

  Future<void> _onToggleEnabled(bool v) async {
    if (v) {
      final ok = await _ensurePin(context);
      if (!ok) return;
      await AppLockStore.setEnabled(true);
    } else {
      await AppLockStore.setEnabled(false);
    }
  }

  Future<void> _onToggleBiometric(bool v) async {
    if (v) {
      final ok = await _ensurePin(context);
      if (!ok) return;
      await AppLockStore.setBiometricEnabled(true);
    } else {
      await AppLockStore.setBiometricEnabled(false);
    }
  }

  Future<void> _onTapPin() async {
    final hasPin = AppLockStore.notifier.value.hasPin;
    if (!hasPin) {
      final ok = await _ensurePin(context);
      if (ok) setState(() {});
      return;
    }
    final action = await showModalBottomSheet<_PinAction>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => const _PinActionSheet(),
    );
    if (!mounted || action == null) return;
    if (action == _PinAction.change) {
      final ok = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => const PinSetupScreen()),
      );
      if (ok == true) setState(() {});
    } else if (action == _PinAction.remove) {
      await AppLockStore.removePin();
      setState(() {});
    }
  }

  Future<void> _onTapTimeout() async {
    final current = AppLockStore.notifier.value.timeoutSeconds;
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _TimeoutSheet(current: current),
    );
    if (picked != null) {
      await AppLockStore.setTimeoutSeconds(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ThemeReactive(builder: (context) => _build(context));
  }

  Widget _build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('applock.title'))),
      body: ValueListenableBuilder<AppLockSettings>(
        valueListenable: AppLockStore.notifier,
        builder: (context, settings, _) {
          return ListView(
            children: [
              SwitchListTile(
                value: settings.enabled,
                onChanged: _onToggleEnabled,
                activeThumbColor: AppColors.primary,
                title: Text(
                  tr('applock.status'),
                  style: TextStyle(color: AppColors.textPrimary),
                ),
                subtitle: Text(
                  settings.enabled ? tr('applock.on') : tr('applock.off'),
                  style: TextStyle(color: AppColors.textMuted),
                ),
              ),
              ListTile(
                enabled: settings.enabled,
                leading: Icon(Icons.timer_outlined, color: AppColors.textMuted),
                title: Text(
                  tr('applock.timeout'),
                  style: TextStyle(color: AppColors.textPrimary),
                ),
                subtitle: Text(
                  tr('applock.timeout.${settings.timeoutSeconds}'),
                  style: TextStyle(color: AppColors.textMuted),
                ),
                onTap: settings.enabled ? _onTapTimeout : null,
              ),
              const Divider(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(
                  tr('applock.unlockMethod'),
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ListTile(
                leading: Icon(Icons.pin_outlined, color: AppColors.textMuted),
                title: Text(
                  tr('applock.pin'),
                  style: TextStyle(color: AppColors.textPrimary),
                ),
                subtitle: Text(
                  settings.hasPin
                      ? tr('applock.pinSet')
                      : tr('applock.pinNotSet'),
                  style: TextStyle(color: AppColors.textMuted),
                ),
                onTap: _onTapPin,
              ),
              if (_capabilityLoaded && _capability != null)
                SwitchListTile(
                  value: settings.biometricEnabled,
                  onChanged: _onToggleBiometric,
                  activeThumbColor: AppColors.primary,
                  secondary: Icon(
                    _capability == BiometricCapability.face
                        ? Icons.face_outlined
                        : Icons.fingerprint,
                    color: AppColors.textMuted,
                  ),
                  title: Text(
                    _capability == BiometricCapability.face
                        ? tr('applock.face')
                        : _capability == BiometricCapability.fingerprint
                        ? tr('applock.fingerprint')
                        : tr('applock.biometric'),
                    style: TextStyle(color: AppColors.textPrimary),
                  ),
                  subtitle: settings.hasPin
                      ? null
                      : Text(
                          tr('applock.needPinFirst'),
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                ),
            ],
          );
        },
      ),
    );
  }
}

enum _PinAction { change, remove }

class _PinActionSheet extends StatelessWidget {
  const _PinActionSheet();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) > 200) Navigator.pop(context);
      },
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              ListTile(
                leading: Icon(Icons.edit_outlined, color: AppColors.primary),
                title: Text(
                  tr('applock.changePin'),
                  style: TextStyle(color: AppColors.textPrimary),
                ),
                onTap: () => Navigator.pop(context, _PinAction.change),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: Text(
                  tr('applock.removePin'),
                  style: const TextStyle(color: Colors.redAccent),
                ),
                onTap: () => Navigator.pop(context, _PinAction.remove),
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimeoutSheet extends StatelessWidget {
  final int current;

  const _TimeoutSheet({required this.current});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) > 200) Navigator.pop(context);
      },
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              for (final seconds in _timeoutOptions)
                ListTile(
                  title: Text(
                    tr('applock.timeout.$seconds'),
                    style: TextStyle(color: AppColors.textPrimary),
                  ),
                  trailing: seconds == current
                      ? Icon(Icons.check, color: AppColors.primary)
                      : null,
                  onTap: () => Navigator.pop(context, seconds),
                ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}
