import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

enum AttachmentPickType { gallery, camera, file }

/// Панель выбора вложения — три квадратные ячейки, ширина = высота =
/// (ширина экрана / 3), закрывается свайпом сверху вниз.
Future<AttachmentPickType?> showAttachmentSheet(BuildContext context) {
  return showModalBottomSheet<AttachmentPickType>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (context) {
      return GestureDetector(
        onVerticalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) > 200) {
            Navigator.pop(context);
          }
        },
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: SafeArea(
            top: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final tileSize = constraints.maxWidth / 3;
                return SizedBox(
                  height: tileSize,
                  child: Row(
                    children: [
                      _tile(
                        context,
                        tileSize,
                        Icons.photo_library,
                        'Галерея',
                        AttachmentPickType.gallery,
                      ),
                      _tile(
                        context,
                        tileSize,
                        Icons.camera_alt,
                        'Камера',
                        AttachmentPickType.camera,
                      ),
                      _tile(
                        context,
                        tileSize,
                        Icons.insert_drive_file,
                        'Файл',
                        AttachmentPickType.file,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
    },
  );
}

Widget _tile(
  BuildContext context,
  double size,
  IconData icon,
  String label,
  AttachmentPickType type,
) {
  return InkWell(
    onTap: () => Navigator.pop(context, type),
    child: SizedBox(
      width: size,
      height: size,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: AppColors.primary, size: 32),
          const SizedBox(height: 8),
          Text(label, style: TextStyle(color: AppColors.textPrimary)),
        ],
      ),
    ),
  );
}
