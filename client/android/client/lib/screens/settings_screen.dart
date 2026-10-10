import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import '../services/debug_log.dart';
import '../storage/media_cache.dart';
import '../theme/app_theme.dart';
import '../utils/file_size_format.dart';
import '../widgets/account_actions.dart';
import '../widgets/bottom_action_bar.dart';
import '../widgets/default_reaction_dialog.dart';
import '../widgets/email_dialog.dart';
import '../widgets/font_size_dialog.dart';
import '../widgets/language_dialog.dart';
import '../widgets/theme_dialog.dart';
import 'about_screen.dart';
import 'app_lock_settings_screen.dart';
import 'change_password_screen.dart';
import 'privacy_settings_screen.dart';

/// "Очистить кэш медиа" (ТЗ пользователя — раньше жила в "О приложении",
/// но это функция ОБЩИХ настроек, а не про само приложение). Сначала
/// считаем реальный размер, чтобы показать его в подтверждении ("сколько
/// места освободится") — если кэш и так пуст, спрашивать нечего.
Future<void> _confirmAndClearMediaCache(BuildContext context) async {
  final size = await MediaCache.totalSize();
  if (!context.mounted) return;
  if (size == 0) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr('settings.cacheEmpty'))));
    return;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Text(
        tr('settings.clearCacheTitle'),
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: Text(
        tr(
          'settings.clearCacheBody',
        ).replaceFirst('{size}', formatFileSize(size)),
        style: TextStyle(color: AppColors.textMuted),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(
            tr('common.cancel'),
            style: TextStyle(color: AppColors.primary),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(
            tr('settings.clearCache'),
            style: TextStyle(color: AppColors.primary),
          ),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  final count = await MediaCache.clearAll();
  DebugLog.log(
    'SettingsScreen media cache cleared count=$count freedBytes=$size',
  );
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(tr('settings.cacheCleared'))));
}

// Каждый пункт меню — окно ПОВЕРХ текущего экрана (см. ТЗ пользователя),
// а не отдельный экран через Navigator.push: единообразно для всех
// пунктов, включая те, что раньше были полноэкранными (Privacy and
// security/App lock/About the app/Change password — см. showXWindow в
// соответствующих файлах).

/// Цветная скруглённая плашка под иконкой пункта настроек — как в Telegram
/// (у каждого пункта свой фирменный цвет, а не одинаковый приглушённый
/// серый для всех). Белая иконка поверх сплошного цвета читается в обеих
/// темах одинаково, без завязки на AppColors.
class _SettingsIcon extends StatelessWidget {
  final IconData icon;
  final Color color;

  const _SettingsIcon({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: Colors.white, size: 18),
    );
  }
}

/// Содержимое "обратной стороны" HomePlaceholderScreen (см.
/// _buildFlippableBody там) — сам список пунктов настроек, без Scaffold и
/// AppBar: они у HomePlaceholderScreen общие с чатами, меняется только
/// заголовок/содержимое.
class SettingsContent extends StatelessWidget {
  const SettingsContent({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.only(bottom: bottomActionBarReservedHeight(context)),
      children: [
        ListTile(
          leading: const _SettingsIcon(
            icon: Icons.email_outlined,
            color: Color(0xFF2AABEE),
          ),
          title: Text(
            tr('settings.email'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          onTap: () => showEmailDialog(context),
        ),
        ListTile(
          leading: const _SettingsIcon(
            icon: Icons.lock_outline,
            color: Color(0xFFFF9F0A),
          ),
          title: Text(
            tr('settings.changePassword'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          onTap: () => showChangePasswordWindow(context),
        ),
        ListTile(
          leading: const _SettingsIcon(
            icon: Icons.emoji_emotions_outlined,
            color: Color(0xFFFF6482),
          ),
          title: Text(
            tr('settings.defaultReaction'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          onTap: () => showDefaultReactionDialog(context),
        ),
        ListTile(
          leading: const _SettingsIcon(
            icon: Icons.language,
            color: Color(0xFF32C769),
          ),
          title: Text(
            tr('settings.language'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          onTap: () => showLanguageDialog(context),
        ),
        ListTile(
          leading: const _SettingsIcon(
            icon: Icons.palette_outlined,
            color: Color(0xFFAF52DE),
          ),
          title: Text(
            tr('settings.theme'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          onTap: () => showThemeDialog(context),
        ),
        ListTile(
          leading: const _SettingsIcon(
            icon: Icons.text_fields,
            color: Color(0xFF5AC8FA),
          ),
          title: Text(
            tr('settings.fontSize'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          onTap: () => showFontSizeDialog(context),
        ),
        ListTile(
          leading: const _SettingsIcon(
            icon: Icons.privacy_tip_outlined,
            color: Color(0xFF34C759),
          ),
          title: Text(
            tr('settings.privacy'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          onTap: () => showPrivacySettingsWindow(context),
        ),
        ListTile(
          leading: const _SettingsIcon(
            icon: Icons.phonelink_lock_outlined,
            color: Color(0xFF5E5CE6),
          ),
          title: Text(
            tr('settings.appLock'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          onTap: () => showAppLockSettingsWindow(context),
        ),
        ListTile(
          leading: const _SettingsIcon(
            icon: Icons.cleaning_services_outlined,
            color: Color(0xFF00C7BE),
          ),
          title: Text(
            tr('settings.clearCache'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          onTap: () => _confirmAndClearMediaCache(context),
        ),
        ListTile(
          leading: const _SettingsIcon(
            icon: Icons.info_outline,
            color: Color(0xFF8E8E93),
          ),
          title: Text(
            tr('settings.about'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          onTap: () => showAboutWindow(context),
        ),
        ListTile(
          leading: const _SettingsIcon(
            icon: Icons.logout,
            color: Color(0xFFFF3B30),
          ),
          title: Text(
            tr('settings.logout'),
            style: const TextStyle(color: Colors.red),
          ),
          onTap: () => confirmLogout(context),
        ),
        ListTile(
          leading: const _SettingsIcon(
            icon: Icons.delete_forever,
            color: Color(0xFFB00020),
          ),
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
