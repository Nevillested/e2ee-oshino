import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

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
