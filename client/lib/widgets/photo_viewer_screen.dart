import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Полноэкранный просмотр фото профиля (своего — из его модалки
/// "Просмотр"/"Изменить"/"Удалить", см. my_profile_screen.dart; чужого —
/// по тапу на аватар в peer_profile_screen.dart). Закрыть — свайп вверх,
/// свайп вниз или системный свайп-назад (последний работает сам по себе,
/// это обычный Navigator.pop).
class PhotoViewerScreen extends StatelessWidget {
  final Uint8List bytes;

  const PhotoViewerScreen({super.key, required this.bytes});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragEnd: (details) {
        // Порог по скорости, а не по пройденному расстоянию — свайп вверх
        // ИЛИ вниз, направление не важно, важен сам факт вертикального
        // свайпа (см. ТЗ пользователя).
        if ((details.primaryVelocity ?? 0).abs() > 200) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              Center(child: Image.memory(bytes, fit: BoxFit.contain)),
              Positioned(
                top: 4,
                left: 4,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Открывает PhotoViewerScreen плавным fade-переходом (не слайд сбоку —
/// это не "новый экран навигации", а просто увеличенный просмотр того
/// же фото).
void showPhotoViewer(BuildContext context, Uint8List bytes) {
  Navigator.push(
    context,
    PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 200),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (context, animation, secondaryAnimation) =>
          FadeTransition(opacity: animation, child: PhotoViewerScreen(bytes: bytes)),
    ),
  );
}
