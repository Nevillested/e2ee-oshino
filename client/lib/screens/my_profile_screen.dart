import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../api/api_client.dart';
import '../l10n/app_strings.dart';
import '../services/my_avatar_store.dart';
import '../services/my_profile_store.dart';
import '../services/retry_until_success.dart';
import '../session.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_settings_tile.dart';
import '../widgets/photo_viewer_screen.dart';
import '../widgets/theme_reactive.dart';

/// Содержимое таба "Профиль" — своё фото/логин/статус/дата рождения.
/// Как и SettingsContent, рендерится БЕЗ своего Scaffold/AppBar — те
/// общие с остальными табами, см. HomePlaceholderScreen (для этого таба
/// AppBar вообще не показывается, надпись "Профиль" была бессмысленным
/// дублированием таба снизу).
class MyProfileContent extends StatefulWidget {
  const MyProfileContent({super.key});

  @override
  State<MyProfileContent> createState() => _MyProfileContentState();
}

enum _AvatarAction { view, change, remove }

class _MyProfileContentState extends State<MyProfileContent> {
  bool _uploading = false;

  Future<void> _pickAndUpload() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
    );
    if (picked == null) return;

    final bytes = await picked.readAsBytes();
    final token = await Session.getToken();
    if (token == null) return;

    setState(() => _uploading = true);
    try {
      await ApiClient().uploadAvatar(token, bytes);
      MyAvatarStore.setUploaded(bytes);
      if (!mounted) return;
      setState(() => _uploading = false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _uploading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('settings.avatarUploadFailed'))),
      );
    }
  }

  Future<void> _removeAvatar() async {
    final token = await Session.getToken();
    if (token == null) return;

    setState(() => _uploading = true);
    try {
      await ApiClient().deleteAvatar(token);
      MyAvatarStore.setRemoved();
      if (!mounted) return;
      setState(() => _uploading = false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _uploading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('settings.avatarUploadFailed'))),
      );
    }
  }

  Future<void> _onAvatarTap() async {
    final currentBytes = MyAvatarStore.notifier.value;
    if (currentBytes == null) {
      // Фото ещё нет — тут показывать нечего и удалять нечего, сразу в
      // галерею, как и раньше вело себя AvatarSettingsTile.
      await _pickAndUpload();
      return;
    }
    final action = await showModalBottomSheet<_AvatarAction>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => const _ProfileAvatarActionSheet(),
    );
    if (!mounted) return;
    switch (action) {
      case _AvatarAction.view:
        showPhotoViewer(context, currentBytes);
      case _AvatarAction.change:
        await _pickAndUpload();
      case _AvatarAction.remove:
        await _removeAvatar();
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 40% ширины экрана — ровно так, как попросили, плюс небольшой отступ
    // сверху, чтобы кружок не упирался в статус-бар/чёлку.
    final avatarDiameter = MediaQuery.of(context).size.width * 0.4;
    return ThemeReactive(
      builder: (context) => ValueListenableBuilder<MyProfile?>(
        valueListenable: MyProfileStore.notifier,
        builder: (context, profile, _) {
          if (profile == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 24,
            ),
            children: [
              Center(
                child: GestureDetector(
                  onTap: _uploading ? null : _onAvatarTap,
                  child: SizedBox(
                    width: avatarDiameter,
                    height: avatarDiameter,
                    child: _uploading
                        ? const Center(child: CircularProgressIndicator())
                        : ValueListenableBuilder<Uint8List?>(
                            valueListenable: MyAvatarStore.notifier,
                            builder: (context, bytes, _) => AvatarThumbnail(
                              bytes: bytes,
                              radius: avatarDiameter / 2,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
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

/// Просмотр / Изменить / Удалить — именно в этом порядке (см. ТЗ
/// пользователя). Показывается, только если фото уже есть (см.
/// _onAvatarTap выше — без фото сразу открывается галерея).
class _ProfileAvatarActionSheet extends StatelessWidget {
  const _ProfileAvatarActionSheet();

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
                leading: Icon(Icons.visibility_outlined, color: AppColors.primary),
                title: Text(
                  tr('settings.avatarView'),
                  style: TextStyle(color: AppColors.textPrimary),
                ),
                onTap: () => Navigator.pop(context, _AvatarAction.view),
              ),
              ListTile(
                leading: Icon(Icons.photo_camera_outlined, color: AppColors.primary),
                title: Text(
                  tr('settings.avatarChange'),
                  style: TextStyle(color: AppColors.textPrimary),
                ),
                onTap: () => Navigator.pop(context, _AvatarAction.change),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: Text(
                  tr('settings.avatarRemove'),
                  style: const TextStyle(color: Colors.redAccent),
                ),
                onTap: () => Navigator.pop(context, _AvatarAction.remove),
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}
