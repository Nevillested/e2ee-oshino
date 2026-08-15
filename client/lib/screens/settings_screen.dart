import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/account_actions.dart';
import '../widgets/avatar_settings_tile.dart';
import '../widgets/default_reaction_dialog.dart';
import '../widgets/email_dialog.dart';
import '../widgets/font_size_dialog.dart';
import '../widgets/language_dialog.dart';
import '../widgets/theme_dialog.dart';
import 'change_password_screen.dart';

/// Содержимое "обратной стороны" HomePlaceholderScreen (см.
/// _buildFlippableBody там) — сам список пунктов настроек, без Scaffold и
/// AppBar: они у HomePlaceholderScreen общие с чатами, меняется только
/// заголовок/содержимое.
class SettingsContent extends StatelessWidget {
  const SettingsContent({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const AvatarSettingsTile(),
        ListTile(
          leading: Icon(Icons.email_outlined, color: AppColors.textMuted),
          title: Text(
            tr('settings.email'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          onTap: () => showEmailDialog(context),
        ),
        ListTile(
          leading: Icon(Icons.lock_outline, color: AppColors.textMuted),
          title: Text(
            tr('settings.changePassword'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const ChangePasswordScreen(),
            ),
          ),
        ),
        ListTile(
          leading: Icon(
            Icons.emoji_emotions_outlined,
            color: AppColors.textMuted,
          ),
          title: Text(
            tr('settings.defaultReaction'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          onTap: () => showDefaultReactionDialog(context),
        ),
        ListTile(
          leading: Icon(Icons.language, color: AppColors.textMuted),
          title: Text(
            tr('settings.language'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          onTap: () => showLanguageDialog(context),
        ),
        ListTile(
          leading: Icon(Icons.palette_outlined, color: AppColors.textMuted),
          title: Text(
            tr('settings.theme'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          onTap: () => showThemeDialog(context),
        ),
        ListTile(
          leading: Icon(Icons.text_fields, color: AppColors.textMuted),
          title: Text(
            tr('settings.fontSize'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          onTap: () => showFontSizeDialog(context),
        ),
        ListTile(
          leading: const Icon(Icons.logout, color: Colors.red),
          title: Text(
            tr('settings.logout'),
            style: const TextStyle(color: Colors.red),
          ),
          onTap: () => confirmLogout(context),
        ),
        ListTile(
          leading: const Icon(Icons.delete_forever, color: Colors.red),
          title: Text(
            tr('settings.deleteAccount'),
            style: const TextStyle(color: Colors.red),
          ),
          onTap: () => confirmDeleteAccount(context),
        ),
      ],
    );
  }
}
