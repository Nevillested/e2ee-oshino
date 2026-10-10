import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../services/debug_log.dart';
import '../theme/app_theme.dart';

/// Общая заглушка/аватарка — используется и здесь, и в списке чатов
/// (см. home_placeholder_screen.dart). bytes == null — заглушка: обычный
/// круг с иконкой человека поверх акцентного цвета, ничего вычурного.
///
/// placeholderColor/placeholderBackground — по умолчанию акцентный цвет
/// поверх его же полупрозрачной версии (годится для обычного, нейтрального
/// фона экрана). На фоне, который САМ уже залит примерно тем же акцентным
/// цветом, эта же комбинация становится почти невидимой — там вызывающая
/// сторона передаёт свою пару цветов (обычно светлую) явно.
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

  Widget _placeholder() {
    return Container(
      width: radius * 2,
      height: radius * 2,
      color: placeholderBackground ?? AppColors.primary.withValues(alpha: 0.25),
      alignment: Alignment.center,
      child: Icon(
        Icons.person,
        color: placeholderColor ?? AppColors.primary,
        size: radius,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (bytes == null) return ClipOval(child: _placeholder());
    // Image.memory (в отличие от CircleAvatar.backgroundImage/MemoryImage,
    // который errorBuilder не поддерживает вообще) — без него повреждённый
    // или не до конца записанный файл диск-кэша (см. AvatarCache._writeToDisk
    // — запись могла прерваться, если приложение убьют посреди нее) молча
    // декодировался бы в пустой кружок БЕЗ иконки "нет фото" — реальная
    // жалоба пользователя: "иногда при перезапуске приложения пропадают
    // фото собеседников... вместо них тупо заполнено каким-то цветом".
    return ClipOval(
      child: Image.memory(
        bytes!,
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          // См. жалобу "иногда при перезапуске приложения пропадают фото
          // собеседников... вместо них тупо заполнено каким-то цветом" —
          // если это повторится, тут будет видно, что байты БЫЛИ (иначе
          // мы не попали бы в эту ветку вообще), но именно декодирование
          // упало, и с какой именно ошибкой.
          DebugLog.log(
            'AvatarThumbnail: decode FAILED, ${bytes!.length} байт, error=$error',
          );
          return _placeholder();
        },
      ),
    );
  }
}
