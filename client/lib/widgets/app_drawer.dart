import 'package:flutter/material.dart';
import '../crypto/key_store.dart';
import '../screens/welcome_screen.dart';
import '../session.dart';
import '../theme/app_theme.dart';

/// Выдвигающееся слева меню. Пока в нём только выход из аккаунта —
/// остальные пункты добавим позже.
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Выйти из аккаунта?',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: const Text(
          'Ключи шифрования будут удалены с этого устройства. '
          'Без них восстановить переписку будет невозможно.',
          style: TextStyle(color: AppColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Я понимаю, выйти из аккаунта',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!context.mounted) return;

    await Session.clearToken();
    await KeyStore.clearAll();

    if (!context.mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const WelcomeScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      width: MediaQuery.of(context).size.width * 0.8,
      backgroundColor: AppColors.surface,
      child: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: const Text(
                'Выйти из аккаунта',
                style: TextStyle(color: Colors.red),
              ),
              onTap: () => _confirmLogout(context),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}