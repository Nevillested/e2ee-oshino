import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../api/api_client.dart';
import '../l10n/app_strings.dart';
import '../services/avatar_cache.dart';
import '../session.dart';
import '../theme/app_theme.dart';

/// Пункт настроек "Фото профиля" — превью текущего фото (или заглушка,
/// см. AvatarPlaceholder) слева, тап открывает галерею и сразу же
/// загружает выбранное фото на сервер. Без отдельного окна
/// подтверждения — сама загрузка достаточно быстрое, безобидное действие
/// (можно тут же поменять ещё раз), в отличие от языка/темы это не
/// настройка "туда-обратно", а разовое действие.
class AvatarSettingsTile extends StatefulWidget {
  const AvatarSettingsTile({super.key});

  @override
  State<AvatarSettingsTile> createState() => _AvatarSettingsTileState();
}

class _AvatarSettingsTileState extends State<AvatarSettingsTile> {
  String? _accountId;
  Uint8List? _avatarBytes;
  bool _loading = true;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final accountId = await Session.getAccountId();
    if (accountId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final bytes = await AvatarCache.get(accountId);
    if (!mounted) return;
    setState(() {
      _accountId = accountId;
      _avatarBytes = bytes;
      _loading = false;
    });
  }

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
      if (_accountId != null) AvatarCache.invalidate(_accountId!);
      if (!mounted) return;
      setState(() {
        _avatarBytes = bytes;
        _uploading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _uploading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('settings.avatarUploadFailed'))),
      );
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
            : (_loading
                  ? const SizedBox.shrink()
                  : AvatarThumbnail(bytes: _avatarBytes, radius: 20)),
      ),
      title: Text(
        tr('settings.avatar'),
        style: TextStyle(color: AppColors.textPrimary),
      ),
      onTap: _uploading ? null : _pickAndUpload,
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
