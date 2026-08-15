import 'dart:io';

class PickedMedia {
  final File file;
  final bool isVideo;
  // Произвольный файл (PDF и т.п.), выбранный через системный
  // file_picker — в отличие от isVideo, не имеет собственного превью и
  // подписывается как "Файл", а не "Видео" (см. chat_screen.dart).
  final bool isFile;
  PickedMedia({required this.file, this.isVideo = false, this.isFile = false});
}
