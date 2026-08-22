import 'dart:async';
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../l10n/app_strings.dart';
import '../services/my_profile_store.dart';
import '../services/retry_until_success.dart';
import '../session.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_settings_tile.dart';
import '../widgets/theme_reactive.dart';

/// Содержимое таба "Профиль" — своё фото/логин/статус/дата рождения.
/// Как и SettingsContent, рендерится БЕЗ своего Scaffold/AppBar — те
/// общие с остальными табами, см. HomePlaceholderScreen.
class MyProfileContent extends StatelessWidget {
  const MyProfileContent({super.key});

  @override
  Widget build(BuildContext context) {
    return ThemeReactive(
      builder: (context) => ValueListenableBuilder<MyProfile?>(
        valueListenable: MyProfileStore.notifier,
        builder: (context, profile, _) {
          if (profile == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            children: [
              const AvatarSettingsTile(),
              ListTile(
                leading: Icon(
                  Icons.badge_outlined,
                  color: AppColors.textMuted,
                ),
                title: Text(
                  tr('profile.login'),
                  style: TextStyle(color: AppColors.textPrimary),
                ),
                subtitle: Text(
                  profile.login,
                  style: TextStyle(color: AppColors.textMuted),
                ),
              ),
              ListTile(
                leading: Icon(
                  Icons.chat_bubble_outline,
                  color: AppColors.textMuted,
                ),
                title: Text(
                  tr('profile.status'),
                  style: TextStyle(color: AppColors.textPrimary),
                ),
                subtitle: Text(
                  profile.status?.isNotEmpty == true
                      ? profile.status!
                      : tr('profile.statusEmpty'),
                  style: TextStyle(color: AppColors.textMuted),
                ),
                trailing: Icon(Icons.edit_outlined, color: AppColors.textMuted),
                onTap: () => _editStatus(context, profile.status),
              ),
              ListTile(
                leading: Icon(Icons.cake_outlined, color: AppColors.textMuted),
                title: Text(
                  tr('profile.birthday'),
                  style: TextStyle(color: AppColors.textPrimary),
                ),
                subtitle: Text(
                  profile.birthday ?? tr('profile.birthdayEmpty'),
                  style: TextStyle(color: AppColors.textMuted),
                ),
                trailing: Icon(Icons.edit_outlined, color: AppColors.textMuted),
                onTap: () => _editBirthday(context, profile.birthday),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _editStatus(BuildContext context, String? current) async {
    final controller = TextEditingController(text: current ?? '');
    final newStatus = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          tr('profile.editStatus'),
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: TextField(
          controller: controller,
          maxLength: 200,
          maxLines: 3,
          autofocus: true,
          style: TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(hintText: tr('profile.statusHint')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('common.cancel')),
          ),
          TextButton(
            // Пустая строка — валидное значение (пользователь стёр весь
            // статус целиком), не блокируем сохранение.
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(tr('common.save')),
          ),
        ],
      ),
    );
    if (newStatus == null) return;

    final token = await Session.getToken();
    if (token == null) return;
    // Сохраняем ТОЛЬКО после подтверждённого сервером сохранения — до
    // этого момента в кэше/на экране остаётся старое значение (см.
    // retryUntilSuccess — при сбое сети пробует снова, а не молча
    // теряет изменение).
    unawaited(
      retryUntilSuccess(() => ApiClient().updateStatus(token, newStatus))
          .then((_) => MyProfileStore.setStatus(newStatus)),
    );
  }

  Future<void> _editBirthday(BuildContext context, String? current) async {
    final initial = current != null
        ? DateTime.tryParse(current)
        : null;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial ?? DateTime(2000),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    if (picked == null) return;
    final formatted =
        '${picked.year.toString().padLeft(4, '0')}-'
        '${picked.month.toString().padLeft(2, '0')}-'
        '${picked.day.toString().padLeft(2, '0')}';

    final token = await Session.getToken();
    if (token == null) return;
    unawaited(
      retryUntilSuccess(() => ApiClient().updateBirthday(token, formatted))
          .then((_) => MyProfileStore.setBirthday(formatted)),
    );
  }
}
