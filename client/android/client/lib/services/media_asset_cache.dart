import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodCall;
import 'package:photo_manager/photo_manager.dart';

/// Результат первой страницы галереи — то же самое, что раньше отдельно
/// собирал _MediaPickerSheetBodyState._load() прямо в момент открытия
/// шторки вложений.
class MediaAssetPage {
  final AssetPathEntity? path;
  final List<AssetEntity> assets;
  final bool isLimited;
  const MediaAssetPage({
    required this.path,
    required this.assets,
    required this.isLimited,
  });
}

/// Кэширует запрос прав + первую страницу галереи, чтобы шторка вложений
/// открывалась без короткого спиннера-заглушки: сам запрос (права на
/// медиатеку + PhotoManager.getAssetPathList/getAssetListPaged) занимает
/// заметное время, и раньше выполнялся ЗАНОВО каждый раз ровно в момент
/// тапа по скрепке. prefetch() запускает его заранее (см. вызов в
/// ChatScreen.initState).
///
/// ТЗ пользователя: новые фото/видео должны появляться в плитке СРАЗУ.
/// Для этого:
///  - startWatching() подписывается на системные уведомления об изменении
///    медиатеки (PhotoManager.addChangeCallback) — снял фото в другом
///    приложении / в нашей камере → кэш инвалидируется, [revision] тикает,
///    открытая шторка перечитывает список;
///  - refresh() принудительно перечитывает первую страницу (stale-while-
///    revalidate: шторка сперва рисует старый кэш мгновенно, потом
///    подменяет свежим).
class MediaAssetCache {
  static const _pageSize = 200;

  static Future<MediaAssetPage>? _future;

  /// Тикает на каждое изменение медиатеки / принудительный refresh —
  /// открытая шторка вложений слушает это и перечитывает список.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static bool _watching = false;
  static Timer? _changeDebounce;

  static Future<MediaAssetPage> _load() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.hasAccess) {
      return const MediaAssetPage(path: null, assets: [], isLimited: false);
    }
    final isLimited = permission == PermissionState.limited;

    final filterOption = FilterOptionGroup(
      videoOption: const FilterOption(
        durationConstraint: DurationConstraint(allowNullable: true),
      ),
    );
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
      filterOption: filterOption,
    );
    if (paths.isEmpty) {
      return MediaAssetPage(path: null, assets: const [], isLimited: isLimited);
    }

    final allPath = paths.first;
    final assets = await allPath.getAssetListPaged(page: 0, size: _pageSize);
    return MediaAssetPage(path: allPath, assets: assets, isLimited: isLimited);
  }

  /// Запускает загрузку заранее, если она ещё не запущена — вызывать
  /// заблаговременно (см. ChatScreen.initState), результат ждать не нужно.
  /// Заодно поднимает слежение за медиатекой.
  static void prefetch() {
    _future ??= _load();
    startWatching();
  }

  /// Отдаёт уже готовый (или ещё идущий) результат.
  static Future<MediaAssetPage> get() => _future ??= _load();

  /// Принудительно перечитать первую страницу галереи. Возвращает свежий
  /// результат и обновляет кэш; [revision] тикает, чтобы открытая шторка
  /// подхватила изменение.
  static Future<MediaAssetPage> refresh() {
    final fresh = _load();
    _future = fresh;
    fresh.whenComplete(() => revision.value++);
    return fresh;
  }

  /// Сбрасывает кэш — нужно, когда пользователь только что расширил доступ
  /// к галерее (PhotoManager.presentLimited) и список нужно перечитать.
  static void invalidate() {
    _future = null;
    revision.value++;
  }

  /// Подписка на системные уведомления об изменении медиатеки. Идемпотентно.
  static void startWatching() {
    if (_watching) return;
    _watching = true;
    PhotoManager.addChangeCallback(_onLibraryChanged);
    // startChangeNotify сам по себе может бросить, если прав ещё нет —
    // не критично, подписка включится при следующем вызове.
    PhotoManager.startChangeNotify().catchError((_) => false);
  }

  static void _onLibraryChanged(MethodCall _) {
    // Изменения галереи прилетают пачками (серийная съёмка, запись видео) —
    // дебаунсим, чтобы не гонять getAssetPathList на каждый кадр. Не знаем
    // точно, ЧТО поменялось — просто перечитываем первую страницу.
    _changeDebounce?.cancel();
    _changeDebounce = Timer(const Duration(milliseconds: 400), refresh);
  }
}
