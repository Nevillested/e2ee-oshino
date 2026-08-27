import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Фолбэк для JPEG, которые нативный декодер Android не может открыть —
/// реальный кейс с устройства: фото с Pixel 7 Pro (Ultra HDR — обычный
/// baseline JPEG + встроенный gain-map через MPF-маркер и огромный XMP-блок)
/// стабильно ловит "Failed to create image decoder... unimplemented" именно
/// на эмуляторе (см. разбор с пользователем — файл прошёл проверку через
/// PIL/чистый JPEG-декодер без единой ошибки, значит дело не в порче байт).
/// `package:image` — чистый Dart-декодер, платформенный ImageDecoder вообще
/// не трогает: раз он смог прочитать те же байты, значит основное
/// (базовое) изображение внутри полностью валидно, просто лишние
/// сегменты (MPF/огромный XMP) сбивают нативный путь. Пересохраняем БЕЗ
/// них — результат гарантированно декодируется каким угодно декодером.
///
/// compute() — decode+encode многомегапиксельного фото ощутимо (секунды)
/// нагружает CPU, гонять это на UI-изоляте нельзя.
///
/// Кэш по identityHashCode байт (не по содержимому — сравнивать
/// многомегабайтные массивы ради кэша дороже, чем сам смысл кэша) — тот же
/// экземпляр Uint8List в чате переиспользуется из _resolvedMedia на каждой
/// перерисовке пузыря; без кэша виджет, пересоздаваемый ListView'ом при
/// скролле, гонял бы повторную нормализацию (секунды CPU) на каждый заход.
final Map<int, Future<Uint8List?>> _normalizeCache = {};

Future<Uint8List?> normalizeJpegBytes(Uint8List bytes) {
  return _normalizeCache.putIfAbsent(
    identityHashCode(bytes),
    () => compute(_normalizeJpegBytesIsolate, bytes),
  );
}

Uint8List? _normalizeJpegBytesIsolate(Uint8List bytes) {
  try {
    final decoded = img.decodeJpg(bytes);
    if (decoded == null) return null;
    // decodeJpg сам по себе поворот по EXIF-тегу НЕ применяет — только
    // декодирует сырые пиксели и оставляет ориентацию отдельным
    // метаданным (см. package:image — bakeOrientation() существует
    // отдельной, явно вызываемой функцией именно поэтому). Без этого шага
    // портретные фото после пересохранения оказались бы физически
    // повёрнуты набок: metadata-поворот, на который рассчитывал оригинал,
    // теряется/не гарантирован в пересобранном файле, а исходные пиксели
    // так и остаются "лежащими".
    final baked = img.bakeOrientation(decoded);
    return Uint8List.fromList(img.encodeJpg(baked, quality: 92));
  } catch (_) {
    return null;
  }
}
