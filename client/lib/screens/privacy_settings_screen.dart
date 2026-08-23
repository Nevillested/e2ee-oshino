import 'dart:async';
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../l10n/app_strings.dart';
import '../services/my_profile_store.dart';
import '../services/retry_until_success.dart';
import '../session.dart';
import '../theme/app_theme.dart';
import '../widgets/frosted_dialog.dart';
import '../widgets/theme_reactive.dart';

/// Точка входа из настроек — окно поверх текущего экрана (см. ТЗ
/// пользователя), тот же полупрозрачный заблюренный стиль, что и у
/// остальных окон настроек (см. FrostedDialog).
Future<void> showPrivacySettingsWindow(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => FrostedDialog(
      title: Text(
        tr('privacy.title'),
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: const PrivacySettingsScreen(),
    ),
  );
}

/// "Приватность и безопасность" — 4 настройки видимости профиля.
/// 0=никто, 1=все, 2=только контакты (findByLogin — только 0/1, "только
/// контакты" не имеет смысла для самой возможности найтись по логину).
class PrivacySettingsScreen extends StatefulWidget {
  const PrivacySettingsScreen({super.key});

  @override
  State<PrivacySettingsScreen> createState() => _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends State<PrivacySettingsScreen> {
  late int _findByLogin;
  late int _avatar;
  late int _birthday;
  late int _status;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final profile = MyProfileStore.notifier.value;
    _findByLogin = profile?.findByLoginVisibility ?? 1;
    _avatar = profile?.avatarVisibility ?? 1;
    _birthday = profile?.birthdayVisibility ?? 1;
    _status = profile?.statusVisibility ?? 1;
  }

  Future<void> _pickValue({
    required String title,
    required int current,
    required bool allowContactsOnly,
    required ValueChanged<int> onPicked,
  }) async {
    final options = <(int, String)>[
      (1, tr('privacy.everyone')),
      if (allowContactsOnly) (2, tr('privacy.contactsOnly')),
      (0, tr('privacy.nobody')),
    ];
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                title,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final (value, label) in options)
              ListTile(
                title: Text(
                  label,
                  style: TextStyle(color: AppColors.textPrimary),
                ),
                trailing: value == current
                    ? Icon(Icons.check, color: AppColors.primary)
                    : null,
                onTap: () => Navigator.pop(context, value),
              ),
          ],
        ),
      ),
    );
    if (picked != null) onPicked(picked);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final token = await Session.getToken();
    if (token == null) return;
    final findByLogin = _findByLogin;
    final avatar = _avatar;
    final birthday = _birthday;
    final status = _status;
    await retryUntilSuccess(
      () => ApiClient().updatePrivacy(
        token,
        findByLogin: findByLogin,
        avatar: avatar,
        birthday: birthday,
        status: status,
      ),
    );
    MyProfileStore.setPrivacy(
      findByLogin: findByLogin,
      avatar: avatar,
      birthday: birthday,
      status: status,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr('privacy.saved'))));
    Navigator.pop(context);
  }

  String _labelFor(int value, bool allowContactsOnly) {
    if (value == 0) return tr('privacy.nobody');
    if (value == 2 && allowContactsOnly) return tr('privacy.contactsOnly');
    return tr('privacy.everyone');
  }

  @override
  Widget build(BuildContext context) {
    return ThemeReactive(builder: (context) => _build(context));
  }

  Widget _build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: Icon(Icons.search, color: AppColors.textMuted),
          title: Text(
            tr('privacy.findByLogin'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          subtitle: Text(
            _labelFor(_findByLogin, false),
            style: TextStyle(color: AppColors.textMuted),
          ),
          onTap: () => _pickValue(
            title: tr('privacy.findByLogin'),
            current: _findByLogin,
            allowContactsOnly: false,
            onPicked: (v) => setState(() => _findByLogin = v),
          ),
        ),
        ListTile(
          leading: Icon(Icons.photo_outlined, color: AppColors.textMuted),
          title: Text(
            tr('privacy.avatar'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          subtitle: Text(
            _labelFor(_avatar, true),
            style: TextStyle(color: AppColors.textMuted),
          ),
          onTap: () => _pickValue(
            title: tr('privacy.avatar'),
            current: _avatar,
            allowContactsOnly: true,
            onPicked: (v) => setState(() => _avatar = v),
          ),
        ),
        ListTile(
          leading: Icon(Icons.cake_outlined, color: AppColors.textMuted),
          title: Text(
            tr('privacy.birthday'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          subtitle: Text(
            _labelFor(_birthday, true),
            style: TextStyle(color: AppColors.textMuted),
          ),
          onTap: () => _pickValue(
            title: tr('privacy.birthday'),
            current: _birthday,
            allowContactsOnly: true,
            onPicked: (v) => setState(() => _birthday = v),
          ),
        ),
        ListTile(
          leading: Icon(Icons.chat_bubble_outline, color: AppColors.textMuted),
          title: Text(
            tr('privacy.status'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          subtitle: Text(
            _labelFor(_status, true),
            style: TextStyle(color: AppColors.textMuted),
          ),
          onTap: () => _pickValue(
            title: tr('privacy.status'),
            current: _status,
            allowContactsOnly: true,
            onPicked: (v) => setState(() => _status = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(tr('common.save')),
            ),
          ),
        ),
      ],
    );
  }
}
