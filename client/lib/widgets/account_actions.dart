import 'package:call_ring_plugin/call_ring_plugin.dart';
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../crypto/key_store.dart';
import '../screens/welcome_screen.dart';
import '../services/websocket_service.dart';
import '../session.dart';
import '../theme/app_theme.dart';

Future<void> _wipeLocalDataAndGoToWelcome(BuildContext context) async {
  WebSocketService.instance.disconnect();
  await Session.clearToken();
  await KeyStore.clearAll();
  await CallRingPlugin.clearCredentials();
  if (!context.mounted) return;
  Navigator.pushAndRemoveUntil(
    context,
    MaterialPageRoute(builder: (context) => const WelcomeScreen()),
    (route) => false,
  );
}

Future<void> confirmLogout(BuildContext context) async {
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
  // ignore: use_build_context_synchronously
  await _wipeLocalDataAndGoToWelcome(context);
}

Future<void> confirmDeleteAccount(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text(
        'Удалить аккаунт?',
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: const Text(
        'Аккаунт будет безвозвратно удалён с сервера. Собеседники увидят '
        'вас как «Удалённый аккаунт». Это действие нельзя отменить.',
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
            'Удалить аккаунт навсегда',
            style: TextStyle(color: Colors.red),
          ),
        ),
      ],
    ),
  );

  if (confirmed != true) return;

  final token = await Session.getToken();
  if (token == null) return;

  bool success = false;
  try {
    success = await ApiClient().deleteAccount(token);
  } catch (_) {
    success = false;
  }

  if (!context.mounted) return;

  if (!success) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Нет соединения с сервером — удаление аккаунта возможно только онлайн',
        ),
      ),
    );
    return;
  }

  await _wipeLocalDataAndGoToWelcome(context);
}

void showSettingsSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.surface,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text(
              'Выйти из аккаунта',
              style: TextStyle(color: Colors.red),
            ),
            onTap: () {
              Navigator.pop(sheetContext);
              confirmLogout(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: const Text(
              'Удалить аккаунт',
              style: TextStyle(color: Colors.red),
            ),
            onTap: () {
              Navigator.pop(sheetContext);
              confirmDeleteAccount(context);
            },
          ),
        ],
      ),
    ),
  );
}
