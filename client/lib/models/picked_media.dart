import 'dart:io';

class PickedMedia {
  final File file;
  final bool isVideo;
  // Произвольный файл (PDF и т.п.), выбранный через системный
  // file_picker — в отличие от isVideo, не имеет собственного превью и
  // подписывается как "Файл", а не "Видео" (см. chat_screen.dart).
  final bool isFile;
  // Фото/видео со спойлером (см. media_picker_sheet.dart, ТЗ пользователя
  // — "Hide with spoiler" из меню выбора) — получатель (и сам отправитель
  // в своей истории) видит его заблюренным до тапа, см. _photoPreview.
  final bool isSpoiler;
  PickedMedia({
    required this.file,
    this.isVideo = false,
    this.isFile = false,
    this.isSpoiler = false,
  });
}
