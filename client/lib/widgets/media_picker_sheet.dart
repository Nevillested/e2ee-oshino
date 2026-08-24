import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';
import '../l10n/app_strings.dart';
import '../services/media_asset_cache.dart';
import '../theme/app_theme.dart';
import 'caption_input_bar.dart';
import 'vertical_dismiss_detector.dart';

class MediaPickerSheetResult {
  final List<AssetEntity> items;
  final String caption;
  // Спойлер — на весь текущий выбор разом (как в Телеге: пункт меню "Hide
  // with spoiler" применяется ко ВСЕЙ пачке, которую собираетесь отправить,
  // а не к отдельным фото по одному), см. ТЗ пользователя.
  final bool spoiler;
  MediaPickerSheetResult(this.items, this.caption, {this.spoiler = false});
}

/// Стандартная кривая появления модального bottom sheet в Flutter
/// (Easing.legacyDecelerate) вообще не даёт перелёта — просто плавно
/// замедляется к цели. Здесь — та же формула, что и у Curves.easeOutBack
/// (кубическая "пружинка" Robert Penner) — с коэффициентом 1.70158, это
/// как раз ЕЁ СОБСТВЕННОЕ стандартное значение (Robert Penner), дающее
/// перелёт примерно на 10%: при отдыхе на kAttachmentSheetRestFraction
/// = 0.5 экрана кривая сначала долетает примерно до 0.55 и только потом
/// оседает на 0.5. Раньше пробовали 8.5 (перелёт почти 100% — при высоте
/// панели около половины экрана это ПРЕВЫШАЛО полную высоту экрана,
/// Flutter обрезал реальный размер по границе, и получалось не "перелёт",
/// а "упёрлось в потолок и рухнуло обратно") и 3.4 (перелёт ~30%, до 0.65
/// — по ощущениям оказалось многовато).
class _BigOvershootCurve extends Curve {
  const _BigOvershootCurve(this.overshoot);
  final double overshoot;

  @override
  double transformInternal(double t) {
    final c1 = overshoot;
    final c3 = c1 + 1;
    final tm1 = t - 1;
    return 1 + c3 * tm1 * tm1 * tm1 + c1 * tm1 * tm1;
  }
}

const _kAttachmentSheetCurve = _BigOvershootCurve(1.70158);

/// Доля высоты экрана, на которой панель "отдыхает" после открытия — но
/// НЕ жёсткий пол: ниже этой точки панель по-прежнему тянется пальцем
/// напрямую (см. minChildSize: 0.0 в build()), просто при отпускании
/// пальца решение "закрыть/вернуть на место" принимается по факту того,
/// где панель оказалась в момент отпускания — см. _onSheetSizeChanged().
const double kAttachmentSheetRestFraction = 0.5;

/// Ниже этой доли экрана отпускание пальца ЗАКРЫВАЕТ шторку целиком;
/// выше — панель пружинисто возвращается на kAttachmentSheetRestFraction.
const double _kAttachmentSheetDismissThreshold = 0.4;

/// Сама открывающая анимация (рост+перелёт+усадка) больше не крутится тут,
/// в самом route — она играет ВНУТРИ _MediaPickerSheetBody, через
/// DraggableScrollableController.animateTo (см. _openSheet()): так высота
/// панели зависит от РЕАЛЬНОГО количества медиафайлов (сколько строк по 3
/// плитки в ряд получится) — а не от произвольной константы вроде
/// "половина экрана", и после открытия по этой же ленте можно тянуть
/// дальше, до самого верха, и она просто скроллится, без второго,
/// отдельного от анимации, скачка. Тут — только мягкое затемнение фона.
Future<dynamic> showMediaPickerSheet(BuildContext context) {
  return showGeneralDialog<dynamic>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'media-picker',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (context, anim1, anim2) => const _MediaPickerSheetBody(),
    transitionBuilder: (context, anim, secondaryAnim, child) {
      return FadeTransition(opacity: anim, child: child);
    },
  );
}

class _MediaPickerSheetBody extends StatefulWidget {
  const _MediaPickerSheetBody();

  @override
  State<_MediaPickerSheetBody> createState() => _MediaPickerSheetBodyState();
}

class _MediaPickerSheetBodyState extends State<_MediaPickerSheetBody> {
  static const int _pageSize = 200;

  // Контроллер, который DraggableScrollableSheet сам передаёт в builder —
  // именно ЕГО, а не отдельный свой, нужно слушать для пагинации: панель
  // теперь одна общая лента (шапка + сетка), а не сетка внутри отдельного
  // фиксированного окошка со своим скроллом.
  ScrollController? _attachedScrollController;
  final _sheetController = DraggableScrollableController();
  // Защита от повторного/зависшего закрытия — см. _closeSheet().
  bool _closing = false;
  // Для оценки скорости прокрутки списка "на глаз" по паре соседних
  // ScrollUpdateNotification — см. _handleListScrollNotification.
  DateTime? _lastScrollNotifTime;
  double? _lastScrollNotifPixels;
  List<AssetEntity> _assets = [];
  final Map<String, int> _selectedOrder = {};
  // См. MediaPickerSheetResult.spoiler — на весь выбор разом, сбрасывается,
  // как только выбор становится пустым (нечему больше применяться).
  bool _spoilerEnabled = false;
  CameraController? _liveCamera;
  bool _loading = true;
  final Map<String, Future<Uint8List?>> _thumbnailFutures = {};

  AssetPathEntity? _allPath;
  int _page = 0;
  bool _hasMore = true;
  bool _loadingMore = false;
  bool _isLimitedAccess = false;

  /// createDateTime у видео иногда отстаёт от реального момента съёмки
  /// (метаданные "снято" не всегда надёжны) — берём более позднюю из двух
  /// дат, чтобы только что снятое видео не проваливалось вниз списка.
  static DateTime _sortKey(AssetEntity a) {
    final created = a.createDateTime;
    final modified = a.modifiedDateTime;
    return created.isAfter(modified) ? created : modified;
  }

  // Таймер "устаканилось" — см. _onSheetSizeChanged: пересоздаётся на
  // каждое изменение size, и решение "закрыть/вернуть/оставить" выносится
  // только когда по нему прошло достаточно тишины, то есть панель РЕАЛЬНО
  // перестала двигаться (а не просто в моменте отпустили палец — см.
  // объяснение там же, почему именно так).
  Timer? _sheetSettleTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _initLiveCamera();
    // Параллельно с загрузкой файлов (заполнением плиток) — сама открывающая
    // анимация: растёт из нижнего края, перелетает выше цели и оседает на
    // kAttachmentSheetRestFraction. addPostFrameCallback — DraggableScrollableController
    // должен быть уже ПРИКРЕПЛЁН к построенному DraggableScrollableSheet.
    WidgetsBinding.instance.addPostFrameCallback((_) => _openSheet());
    _sheetController.addListener(_onSheetSizeChanged);
  }

  Future<void> _openSheet() async {
    // В полтора раза быстрее предыдущего показа (было 1400мс).
    await _sheetController.animateTo(
      kAttachmentSheetRestFraction,
      duration: const Duration(milliseconds: 933),
      curve: _kAttachmentSheetCurve,
    );
  }

  /// Реагирует на ЛЮБОЕ изменение размера панели — и от прямого перетягивания
  /// пальцем, и от баллистического доката ПОСЛЕ отпускания (флик). Раньше
  /// решение "закрыть/вернуть на место" принималось только в момент
  /// onPointerUp по текущему на тот момент размеру — а при флике в момент
  /// отпускания пальца размер ещё мог быть большим (например, около 1.0),
  /// а реальное итоговое положение становилось известно только СПУСТЯ
  /// какое-то время, пока доигрывала инерция самого DraggableScrollableSheet.
  /// Если та инерция утаскивала панель в 0, наш Navigator.pop() просто
  /// никогда не вызывался — маршрут не закрывался, а вместе с ним не
  /// пропадало и затемнение фона. Теперь решение принимается по ФАКТИЧЕСКИ
  /// устоявшемуся размеру, независимо от того, чем он был вызван.
  void _onSheetSizeChanged() {
    if (_closing || !_sheetController.isAttached) return;
    final size = _sheetController.size;
    if (size <= 0.001) {
      _sheetSettleTimer?.cancel();
      _closeSheet();
      return;
    }
    _sheetSettleTimer?.cancel();
    _sheetSettleTimer = Timer(const Duration(milliseconds: 120), () {
      if (_closing || !_sheetController.isAttached) return;
      final settled = _sheetController.size;
      if (settled >= kAttachmentSheetRestFraction) return;
      if (settled < _kAttachmentSheetDismissThreshold) {
        _closeSheet();
      } else {
        _sheetController.animateTo(
          kAttachmentSheetRestFraction,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// DraggableScrollableSheet, когда список НЕ у самого начала, сначала
  /// докручивает список к его собственному верху (position 0), и только
  /// потом начинает сжимать саму панель — это устройство самого виджета.
  /// Проблема в том, что когда это докручивание списка происходит не
  /// пальцем, а баллистически (флик), и список долетает до нуля СО
  /// СКОРОСТЬЮ — встроенный виджет в ЭТОМ направлении (список → сжатие
  /// панели) остаток инерции никуда не передаёт: список просто упирается в
  /// свою границу и останавливается, а панель как стояла на потолке, так и
  /// стоит, хотя палец явно "бросал" её вниз. Здесь оцениваем скорость по
  /// последним двум ScrollUpdateNotification и, если список долетел до
  /// верха БАЛЛИСТИЧЕСКИ (dragDetails == null, то есть не рукой) и с
  /// заметной скоростью — а не просто тихо доскроллил и остановился сам,
  /// как при обычном неспешном просмотре, — докатываем панель сами.
  static const double _kListFlingContinuationVelocity = 800;

  bool _handleListScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      _lastScrollNotifTime = null;
      _lastScrollNotifPixels = null;
      return false;
    }
    if (notification is! ScrollUpdateNotification) return false;

    final now = DateTime.now();
    final pixels = notification.metrics.pixels;
    final prevTime = _lastScrollNotifTime;
    final prevPixels = _lastScrollNotifPixels;
    _lastScrollNotifTime = now;
    _lastScrollNotifPixels = pixels;

    if (notification.dragDetails != null) return false; // ведёт палец, не флик
    if (pixels > 0) return false; // ещё не докатились до верха списка
    if (prevTime == null || prevPixels == null) return false;

    final dtSeconds = now.difference(prevTime).inMicroseconds / 1e6;
    if (dtSeconds <= 0) return false;
    final velocity = (pixels - prevPixels) / dtSeconds; // <0 — летит к верху

    if (velocity < -_kListFlingContinuationVelocity &&
        _sheetController.isAttached &&
        _sheetController.size > kAttachmentSheetRestFraction) {
      _sheetController.animateTo(
        kAttachmentSheetRestFraction,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    }
    return false;
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore) return;
    final controller = _attachedScrollController;
    if (controller == null || !controller.hasClients) return;
    final position = controller.position;
    if (position.pixels >= position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  /// DraggableScrollableSheet передаёт СВОЙ ScrollController через builder —
  /// его и нужно слушать для пагинации (см. _onScroll), а не заводить
  /// отдельный. Он может смениться при пересборке — переслушиваем только
  /// при реальной смене объекта.
  void _attachScrollController(ScrollController controller) {
    if (identical(controller, _attachedScrollController)) return;
    _attachedScrollController?.removeListener(_onScroll);
    _attachedScrollController = controller;
    controller.addListener(_onScroll);
  }

  Future<void> _loadMore() async {
    final path = _allPath;
    if (path == null || !_hasMore || _loadingMore) return;
    _loadingMore = true;

    final nextPage = _page + 1;
    final more = await path.getAssetListPaged(page: nextPage, size: _pageSize);

    if (!mounted) return;
    setState(() {
      _page = nextPage;
      _assets = [..._assets, ...more]
        ..sort((a, b) => _sortKey(b).compareTo(_sortKey(a)));
      _hasMore = more.length == _pageSize;
      _loadingMore = false;
    });
  }

  Future<void> _requestFullAccess() async {
    await PhotoManager.presentLimited(type: RequestType.common);
    MediaAssetCache.invalidate();
    setState(() {
      _loading = true;
      _page = 0;
      _hasMore = true;
    });
    await _load();
  }

  Future<void> _initLiveCamera() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.low,
        enableAudio: false,
      );
      await controller.initialize();
      if (mounted) setState(() => _liveCamera = controller);
    } catch (_) {
      // Нет доступа к камере — плитка останется кликабельной, просто без превью.
    }
  }

  /// Сама загрузка (запрос прав + первая страница галереи, см.
  /// MediaAssetCache) теперь запускается ЗАРАНЕЕ — см. ChatScreen.initState
  /// — а не в момент открытия шторки: это самое время (заметный запрос к
  /// PhotoManager) раньше выполнялось ровно тогда же, когда играет
  /// открывающая анимация, отсюда и промелькивающий спиннер. Здесь просто
  /// забираем уже готовый (или почти готовый) результат.
  Future<void> _load() async {
    final page = await MediaAssetCache.get();
    if (page.path == null && page.assets.isEmpty && !page.isLimited) {
      // path == null без ограниченного доступа — либо нет прав вообще,
      // либо в галерее пусто; в обоих случаях просто показываем пустую
      // сетку без плиток фото (плитка камеры при этом всё равно есть).
      if (mounted) setState(() => _loading = false);
      return;
    }

    final assets = [...page.assets]
      ..sort((a, b) => _sortKey(b).compareTo(_sortKey(a)));

    if (mounted) {
      setState(() {
        _allPath = page.path;
        _assets = assets;
        _hasMore = assets.length == _pageSize;
        _isLimitedAccess = page.isLimited;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _attachedScrollController?.removeListener(_onScroll);
    _sheetController.removeListener(_onSheetSizeChanged);
    _sheetSettleTimer?.cancel();
    _sheetController.dispose();
    _liveCamera?.dispose();
    super.dispose();
  }

  void _toggleSelect(AssetEntity asset) {
    setState(() {
      if (_selectedOrder.containsKey(asset.id)) {
        final removedOrder = _selectedOrder.remove(asset.id)!;
        for (final key in _selectedOrder.keys.toList()) {
          if (_selectedOrder[key]! > removedOrder) {
            _selectedOrder[key] = _selectedOrder[key]! - 1;
          }
        }
      } else {
        _selectedOrder[asset.id] = _selectedOrder.length + 1;
      }
      if (_selectedOrder.isEmpty) _spoilerEnabled = false;
    });
  }

  void _openCameraTile() {
    _liveCamera?.dispose();
    _closeSheet('open_camera');
  }

  void _sendSelected(String caption) {
    final ordered =
        _assets.where((a) => _selectedOrder.containsKey(a.id)).toList()..sort(
          (a, b) => _selectedOrder[a.id]!.compareTo(_selectedOrder[b.id]!),
        );
    _closeSheet(
      MediaPickerSheetResult(ordered, caption, spoiler: _spoilerEnabled),
    );
  }

  /// Единая точка закрытия шторки — вместо мгновенного Navigator.pop (тогда
  /// панель просто пропадала на месте, а не "уходила" вниз под нижний край
  /// экрана) сперва СЖИМАЕМ её обратно в 0 через тот же
  /// DraggableScrollableController, что и открытие, и только потом реально
  /// снимаем route.
  ///
  /// _closing — защита от повторного вызова (например, drag-release ещё раз
  /// решит "закрыть", пока предыдущее закрытие уже идёт). Future.any с
  /// таймаутом — защита от того, что сама animateTo() может НЕ доиграть до
  /// конца: если сразу после отпускания пальца сработает СОБСТВЕННАЯ
  /// баллистическая прокрутка DraggableScrollableSheet (обычная реакция на
  /// fling), она может перехватить/оборвать нашу анимацию, и её Future
  /// тогда просто никогда не резолвится — а раз Navigator.pop() ждёт именно
  /// его, шторка визуально пропадает (или зависает), а затемнение фона,
  /// которое снимается только вместе с реальным pop()'ом, остаётся навсегда.
  Future<void> _closeSheet([Object? result]) async {
    if (_closing) return;
    _closing = true;
    if (_sheetController.isAttached) {
      try {
        await Future.any([
          _sheetController.animateTo(
            0.0,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeIn,
          ),
          Future.delayed(const Duration(milliseconds: 400)),
        ]);
      } catch (_) {}
    }
    if (mounted) Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final hasSelection = _selectedOrder.isNotEmpty;

    // DraggableScrollableSheet сам считает полную высоту ленты по
    // itemCount сетки (строки × размер плитки) — без ручной арифметики
    // "сколько там рядов" и без эйгерной постройки всех плиток разом:
    // SliverGrid внутри CustomScrollView строит (и меряет экстент) лениво,
    // как обычный GridView.builder.
    //
    // minChildSize/initialChildSize ВСЕГДА 0.0 — специально НЕ фиксируем
    // пол на kAttachmentSheetRestFraction: ниже него панель должна тянуться
    // пальцем напрямую (см. _onSheetSizeChanged), а не клэмпаться. Решение
    // "закрыть/вернуть на 0.5" принимается уже по факту отпускания пальца.
    return DraggableScrollableSheet(
      controller: _sheetController,
      initialChildSize: 0.0,
      minChildSize: 0.0,
      maxChildSize: 1.0,
      expand: false,
      // Закрытие обрабатываем сами (см. _onSheetSizeChanged) — этот флаг
      // про совсем другой, автоматический механизм, которым мы не
      // пользуемся.
      shouldCloseOnMinExtent: false,
      builder: (context, scrollController) {
        _attachScrollController(scrollController);
        return Material(
          color: AppColors.background,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          // Без SafeArea(bottom) — панель должна начинаться от САМОГО низа
          // экрана и перекрывать собой зазор в 5px под полем ввода в чате
          // позади неё, а не останавливаться, не доходя до края, оставляя
          // этот зазор (и жестовую зону ОС) видимой щелью снизу.
          child: Column(
            children: [
              SizedBox(
                height: 36,
                child: Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.textMuted,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              if (_isLimitedAccess)
                InkWell(
                  onTap: _requestFullAccess,
                  child: Container(
                    width: double.infinity,
                    color: AppColors.primary.withValues(alpha: 0.15),
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 14,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 16,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tr('media.limitedAccess'),
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              // Панель "N фото выбрано" + меню из трёх точек (см. ТЗ
              // пользователя, по образцу Телеги) — только пока что-то
              // выбрано, симметрично панели описания снизу.
              if (hasSelection)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 4, 4),
                  child: Row(
                    children: [
                      Text(
                        '${tr('media.selectedCount')}: ${_selectedOrder.length}',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      PopupMenuButton<void>(
                        icon: Icon(Icons.more_vert, color: AppColors.textPrimary),
                        color: AppColors.surface,
                        itemBuilder: (context) => [
                          PopupMenuItem<void>(
                            onTap: () =>
                                setState(() => _spoilerEnabled = !_spoilerEnabled),
                            child: Row(
                              children: [
                                Icon(
                                  _spoilerEnabled
                                      ? Icons.check_box
                                      : Icons.check_box_outline_blank,
                                  size: 20,
                                  color: AppColors.textPrimary,
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  tr('media.hideWithSpoiler'),
                                  style: TextStyle(color: AppColors.textPrimary),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              Expanded(
                // Stack вместо прежнего "сетка + панель друг под другом в
                // Column" — панель описания теперь ЛЕЖИТ ПОВЕРХ сетки, не
                // сдвигая её вверх при появлении. Сетка остаётся на месте
                // целиком, просто частично перекрывается снизу.
                child: Stack(
                  children: [
                    Positioned.fill(
                      // ВАЖНО: CustomScrollView со scrollController от
                      // DraggableScrollableSheet строится ВСЕГДА, даже пока
                      // _loading — если подменять его на время загрузки
                      // спиннером (как было раньше), scrollController ни к
                      // чему не подключён, DraggableScrollableController
                      // остаётся неприкреплённым к позиции скролла, и
                      // _openSheet()'s animateTo() падает молча (экран
                      // просто темнеет и ничего не открывается — не строка
                      // ошибки, а именно тишина). Спиннер теперь просто
                      // одна из sliver'ов внутри той же самой ленты.
                      //
                      // Закрытие по утягиванию вниз теперь не через overscroll
                      // (см. _onSheetSizeChanged выше) — минимума у
                      // панели больше нет, драг вниз двигает саму панель
                      // напрямую. NotificationListener — отдельная задача,
                      // см. _handleListScrollNotification: докатывает панель,
                      // если флик списка вверх упёрся в его собственный
                      // потолок ещё со скоростью.
                      child: NotificationListener<ScrollNotification>(
                        onNotification: _handleListScrollNotification,
                        child: CustomScrollView(
                          controller: scrollController,
                          slivers: [
                            if (_loading)
                              const SliverFillRemaining(
                                hasScrollBody: false,
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            else
                              SliverGrid(
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 3,
                                      childAspectRatio: 1,
                                    ),
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) => index == 0
                                      ? _buildCameraTile()
                                      : _buildMediaTile(_assets[index - 1]),
                                  childCount: _assets.length + 1,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (hasSelection)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: CaptionInputBar(onSend: _sendSelected),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCameraTile() {
    return InkWell(
      onTap: _openCameraTile,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.black26, width: 0.5),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_liveCamera != null && _liveCamera!.value.isInitialized)
              ClipRect(child: CameraPreview(_liveCamera!))
            else
              Container(color: AppColors.surface),
            const Positioned(
              top: 6,
              right: 6,
              child: Icon(Icons.camera_alt, color: Colors.white, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openAssetPreview(AssetEntity asset) async {
    final index = _assets.indexOf(asset);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _AssetPreviewScreen(
          assets: _assets,
          initialIndex: index < 0 ? 0 : index,
          selectedOrder: _selectedOrder,
          onToggleSelect: _toggleSelect,
        ),
      ),
    );
  }

  Widget _buildMediaTile(AssetEntity asset) {
    final order = _selectedOrder[asset.id];
    return GestureDetector(
      onTap: () => _openAssetPreview(asset),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.black26, width: 0.5),
        ),
        // LayoutBuilder даёт РЕАЛЬНЫЙ конечный размер плитки — нужен, чтобы
        // явно задать Positioned ширину/высоту тап-зоны выбора. Без этого
        // (только top+right без left/bottom) Stack отдаёт FractionallySizedBox
        // неограниченные constraints, и 50% от бесконечности ломает layout
        // ("Cannot hit test a render box with no size").
        child: LayoutBuilder(
          builder: (context, constraints) {
            final quadrantWidth = constraints.maxWidth / 2;
            final quadrantHeight = constraints.maxHeight / 2;
            return Stack(
              fit: StackFit.expand,
              children: [
                FutureBuilder<Uint8List?>(
                  future: _thumbnailFutures.putIfAbsent(
                    asset.id,
                    () => asset.thumbnailDataWithSize(
                      const ThumbnailSize(200, 200),
                    ),
                  ),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done ||
                        snapshot.data == null) {
                      return Container(color: AppColors.surface);
                    }
                    return Image.memory(snapshot.data!, fit: BoxFit.cover);
                  },
                ),
                if (asset.type == AssetType.video)
                  const Positioned(
                    bottom: 4,
                    left: 4,
                    child: Icon(
                      Icons.play_circle_fill,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                // Тап-зона выбора занимает всю верхнюю правую четверть плитки
                // (не только маленький кружок) — легче попасть пальцем. Тап по
                // остальным трём четвертям уходит на GestureDetector плитки
                // целиком и открывает предпросмотр.
                Positioned(
                  top: 0,
                  right: 0,
                  width: quadrantWidth,
                  height: quadrantHeight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _toggleSelect(asset),
                    child: Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: order != null
                                ? AppColors.primary
                                : Colors.black45,
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          alignment: Alignment.center,
                          child: order != null
                              ? Text(
                                  '$order',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Компактный полноэкранный предпросмотр выбираемых файлов — открывается
/// тапом по плитке (кроме кружка выбора), листается влево-вправо по всем
/// файлам сетки как единый просмотрщик. Для видео проигрывает файл, для
/// фото просто показывает его целиком. Кружок в верхнем правом углу
/// позволяет выбрать/снять выбор ТЕКУЩЕЙ (открытой сейчас) страницы прямо
/// отсюда, не возвращаясь к сетке. Свайп вверх/вниз или системный "назад"
/// закрывает предпросмотр.
class _AssetPreviewScreen extends StatefulWidget {
  final List<AssetEntity> assets;
  final int initialIndex;
  final Map<String, int> selectedOrder;
  final void Function(AssetEntity asset) onToggleSelect;

  const _AssetPreviewScreen({
    required this.assets,
    required this.initialIndex,
    required this.selectedOrder,
    required this.onToggleSelect,
  });

  @override
  State<_AssetPreviewScreen> createState() => _AssetPreviewScreenState();
}

class _AssetPreviewScreenState extends State<_AssetPreviewScreen> {
  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _handleToggleSelect() {
    widget.onToggleSelect(widget.assets[_currentIndex]);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.selectedOrder[widget.assets[_currentIndex].id];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Center(
              child: GestureDetector(
                onTap: _handleToggleSelect,
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: order != null ? AppColors.primary : Colors.black45,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  alignment: Alignment.center,
                  child: order != null
                      ? Text(
                          '$order',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: VerticalDismissDetector(
        child: PageView.builder(
          controller: _pageController,
          itemCount: widget.assets.length,
          onPageChanged: (index) => setState(() => _currentIndex = index),
          itemBuilder: (context, index) =>
              _AssetPreviewPage(asset: widget.assets[index]),
        ),
      ),
    );
  }
}

class _AssetPreviewPage extends StatefulWidget {
  final AssetEntity asset;
  const _AssetPreviewPage({required this.asset});

  @override
  State<_AssetPreviewPage> createState() => _AssetPreviewPageState();
}

class _AssetPreviewPageState extends State<_AssetPreviewPage> {
  VideoPlayerController? _videoController;
  Future<void>? _videoInit;
  File? _imageFile;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final file = await widget.asset.file;
    if (!mounted) return;
    if (file == null) {
      setState(() => _loading = false);
      return;
    }

    if (widget.asset.type == AssetType.video) {
      final controller = VideoPlayerController.file(file);
      _videoController = controller;
      _videoInit = controller.initialize().then((_) {
        if (mounted) controller.play();
      });
    } else {
      _imageFile = file;
    }
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    if (_videoController != null) {
      // Таймлайн вынесен ОТДЕЛЬНО от _VideoPreview и прижат к нижнему краю
      // всей страницы (а не только видео), чтобы тянуться на полную ширину
      // экрана даже для вертикальных видео, которые уже сами по себе
      // занимают меньше ширины (AspectRatio центрирует видео по центру).
      return Stack(
        alignment: Alignment.center,
        children: [
          _VideoPreview(controller: _videoController!, initFuture: _videoInit!),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: _VideoSeekBar(controller: _videoController!),
            ),
          ),
        ],
      );
    }
    if (_imageFile != null) {
      return Center(child: Image.file(_imageFile!, fit: BoxFit.contain));
    }
    return const Center(
      child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
    );
  }
}

class _VideoPreview extends StatelessWidget {
  final VideoPlayerController controller;
  final Future<void> initFuture;
  const _VideoPreview({required this.controller, required this.initFuture});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: initFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const CircularProgressIndicator(color: Colors.white);
        }
        return GestureDetector(
          onTap: () => controller.value.isPlaying
              ? controller.pause()
              : controller.play(),
          child: AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: Stack(
              alignment: Alignment.center,
              children: [
                VideoPlayer(controller),
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: controller,
                  builder: (context, value, _) {
                    if (value.isPlaying) return const SizedBox.shrink();
                    return const Icon(
                      Icons.play_arrow,
                      color: Colors.white70,
                      size: 64,
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _VideoSeekBar extends StatefulWidget {
  final VideoPlayerController controller;
  const _VideoSeekBar({required this.controller});

  @override
  State<_VideoSeekBar> createState() => _VideoSeekBarState();
}

class _VideoSeekBarState extends State<_VideoSeekBar> {
  // Пока палец держит ползунок, отображаем позицию из жеста, а не из
  // контроллера — иначе набегающие обновления позиции во время
  // проигрывания дёргали бы ползунок обратно под пальцем.
  double? _dragValueMs;

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final durationMs = value.duration.inMilliseconds.toDouble();
        if (durationMs <= 0) return const SizedBox.shrink();

        final positionMs = value.position.inMilliseconds
            .clamp(0, value.duration.inMilliseconds)
            .toDouble();
        final sliderMs = (_dragValueMs ?? positionMs).clamp(0.0, durationMs);

        return Container(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Colors.black54],
            ),
          ),
          child: Row(
            children: [
              Text(
                _formatDuration(Duration(milliseconds: sliderMs.round())),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                  ),
                  child: Slider(
                    value: sliderMs,
                    min: 0,
                    max: durationMs,
                    activeColor: AppColors.primary,
                    inactiveColor: Colors.white24,
                    onChangeStart: (v) => setState(() => _dragValueMs = v),
                    onChanged: (v) => setState(() => _dragValueMs = v),
                    onChangeEnd: (v) {
                      widget.controller.seekTo(
                        Duration(milliseconds: v.round()),
                      );
                      setState(() => _dragValueMs = null);
                    },
                  ),
                ),
              ),
              Text(
                _formatDuration(value.duration),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }
}
