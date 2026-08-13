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
/// тапа по скрепке — то есть ровно тогда, когда уже идёт открывающая
/// анимация шторки. prefetch() запускает его заранее (см. вызов в
/// ChatScreen.initState), а showMediaPickerSheet просто переиспользует уже
/// готовый (или ещё идущий, но уже стартовавший заранее) Future.
class MediaAssetCache {
  static const _pageSize = 200;

  static Future<MediaAssetPage>? _future;

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
  static void prefetch() {
    _future ??= _load();
  }

  /// Отдаёт уже готовый (или ещё идущий) результат — если prefetch() успел
  /// отработать заранее, awaiting практически мгновенный.
  static Future<MediaAssetPage> get() => _future ??= _load();

  /// Сбрасывает кэш — нужно, когда пользователь только что расширил доступ
  /// к галерее (PhotoManager.presentLimited) и список нужно перечитать.
  static void invalidate() {
    _future = null;
  }
}
