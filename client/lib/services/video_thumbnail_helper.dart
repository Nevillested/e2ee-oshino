import 'dart:typed_data';
import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';

final _thumbnailer = FcNativeVideoThumbnail();

/// Кадр-превью для видео (и локально выбранного файла до отправки, и уже
/// скачанного/расшифрованного кэшированного файла после получения) — один
/// и тот же путь для обеих ситуаций, чтобы видео в чате вело себя как фото:
/// со своим превью в пузыре и с воспроизведением во встроенном
/// просмотрщике, а не как безликий файл (см. ТЗ пользователя).
///
/// Раньше здесь был пакет video_thumbnail — у него в Android-сборке
/// намертво прописан jcenter(), а этот репозиторий давно закрыт и не
/// резолвится современным Gradle (сборка падала с "Could not find method
/// jcenter()"). fc_native_video_thumbnail — актуальный пакет с рабочей
/// сборкой (mavenCentral, современный AGP).
Future<Uint8List?> generateVideoThumbnail(String videoPath) {
  return _thumbnailer.saveThumbnailToBytes(
    srcFile: videoPath,
    width: 400,
    height: 400,
    format: 'jpeg',
    quality: 75,
  );
}
