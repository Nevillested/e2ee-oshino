import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../api/api_client.dart';
import '../l10n/app_strings.dart';
import '../services/my_avatar_store.dart';
import '../session.dart';
import '../theme/app_theme.dart';

/// Пункт настроек "Фото профиля" — превью текущего фото (или заглушка,
/// см. AvatarPlaceholder) слева, тап открывает галерею и сразу же
/// загружает выбранное фото на сервер. Без отдельного окна
/// подтверждения — сама загрузка достаточно быстрое, безобидное действие
/// (можно тут же поменять ещё раз), в отличие от языка/темы это не
/// настройка "туда-обратно", а разовое действие.
///
/// Превью читается из MyAvatarStore (единый источник истины для СВОЕГО
/// фото, см. этот класс и "Заметки" в home_placeholder_screen.dart) —
/// никакого собственного запроса/кэша на этом экране больше нет: и при
/// первом открытии, и после загрузки нового фото это ровно те же байты,
/// что видят "Заметки" в списке чатов.
class AvatarSettingsTile extends StatefulWidget {
  const AvatarSettingsTile({super.key});

  @override
  State<AvatarSettingsTile> createState() => _AvatarSettingsTileState();
}

class _AvatarSettingsTileState extends State<AvatarSettingsTile> {
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

  /// Уже есть фото — тап открывает выбор действия (сменить/удалить),
  /// вместо того чтобы сразу лезть в галерею как при первой загрузке —
  /// иначе удалить фото было бы просто нечем, кроме как перезаписать
  /// новым.
  Future<void> _onTap() async {
    if (MyAvatarStore.notifier.value == null) {
      await _pickAndUpload();
      return;
    }
    final action = await showModalBottomSheet<_AvatarAction>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => const _AvatarActionSheet(),
    );
    if (action == _AvatarAction.change) {
      await _pickAndUpload();
    } else if (action == _AvatarAction.remove) {
      await _removeAvatar();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: SizedBox(
        width: 40,
        height: 40,
        child: _uploading
            ? const CircularProgressIndicator(strokeWidth: 2)
            : ValueListenableBuilder(
                valueListenable: MyAvatarStore.notifier,
                builder: (context, bytes, _) =>
                    AvatarThumbnail(bytes: bytes, radius: 20),
              ),
      ),
      title: Text(
        tr('settings.avatar'),
        style: TextStyle(color: AppColors.textPrimary),
      ),
      onTap: _uploading ? null : _onTap,
    );
  }
}

enum _AvatarAction { change, remove }

class _AvatarActionSheet extends StatelessWidget {
  const _AvatarActionSheet();

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

/// Общая заглушка/аватарка — используется и здесь, и в списке чатов
/// (см. home_placeholder_screen.dart). bytes == null — заглушка: обычный
/// круг с иконкой человека поверх акцентного цвета, ничего вычурного.
///
/// placeholderColor/placeholderBackground — по умолчанию акцентный цвет
/// поверх его же полупрозрачной версии (годится для обычного, нейтрального
/// фона экрана). На фоне, который САМ уже залит примерно тем же акцентным
/// цветом (например, градиентная плашка в new_chat_screen.dart), эта же
/// комбинация становится почти невидимой — там вызывающая сторона передаёт
/// свою пару цветов (обычно светлую) явно.
class AvatarThumbnail extends StatelessWidget {
  final Uint8List? bytes;
  final double radius;
  final Color? placeholderColor;
  final Color? placeholderBackground;

  const AvatarThumbnail({
    super.key,
    required this.bytes,
    this.radius = 22,
    this.placeholderColor,
    this.placeholderBackground,
  });

  @override
  Widget build(BuildContext context) {
    if (bytes != null) {
      return CircleAvatar(radius: radius, backgroundImage: MemoryImage(bytes!));
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor:
          placeholderBackground ?? AppColors.primary.withValues(alpha: 0.25),
      child: Icon(
        Icons.person,
        color: placeholderColor ?? AppColors.primary,
        size: radius,
      ),
    );
  }
}
