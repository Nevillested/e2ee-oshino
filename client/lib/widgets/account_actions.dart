import 'package:call_ring_plugin/call_ring_plugin.dart';
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../crypto/key_store.dart';
import '../l10n/app_strings.dart';
import '../screens/welcome_screen.dart';
import '../services/my_avatar_store.dart';
import '../services/websocket_service.dart';
import '../session.dart';
import '../theme/app_theme.dart';

Future<void> _wipeLocalDataAndGoToWelcome(BuildContext context) async {
  WebSocketService.instance.disconnect();

  // Отвязываем push-токен ЭТОГО устройства от аккаунта, пока сессия ещё
  // жива — иначе он остаётся в базе на старом device_id, и если на этом
  // же телефоне потом войдут в ДРУГОЙ аккаунт, сообщения прежнему
  // аккаунту всё ещё будят этот телефон пушем (см. unregisterPushToken).
  // Best-effort: не блокируем выход из аккаунта, если сети сейчас нет.
  final token = await Session.getToken();
  final deviceId = await KeyStore.getStoredDeviceId();
  if (token != null && deviceId != null) {
    try {
      await ApiClient().unregisterPushToken(token, deviceId);
    } catch (_) {}
  }

  await Session.clearToken();
  await KeyStore.clearAll();
  await CallRingPlugin.clearCredentials();
  MyAvatarStore.reset();
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
      title: Text(
        tr('account.logoutTitle'),
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: Text(
        tr('account.logoutBody'),
        style: TextStyle(color: AppColors.textMuted),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(tr('common.cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(
            tr('account.logoutConfirm'),
            style: const TextStyle(color: Colors.red),
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
      title: Text(
        tr('account.deleteTitle'),
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: Text(
        tr('account.deleteBody'),
        style: TextStyle(color: AppColors.textMuted),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(tr('common.cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(
            tr('account.deleteConfirm'),
            style: const TextStyle(color: Colors.red),
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
      SnackBar(content: Text(tr('account.deleteOfflineError'))),
    );
    return;
  }

  await _wipeLocalDataAndGoToWelcome(context);
}
