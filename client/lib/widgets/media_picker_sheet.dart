import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';
import '../theme/app_theme.dart';
import 'caption_input_bar.dart';
import 'vertical_dismiss_detector.dart';

class MediaPickerSheetResult {
  final List<AssetEntity> items;
  final String caption;
  MediaPickerSheetResult(this.items, this.caption);
}

Future<dynamic> showMediaPickerSheet(BuildContext context) {
  return showModalBottomSheet<dynamic>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => const _MediaPickerSheetBody(),
  );
}

class _MediaPickerSheetBody extends StatefulWidget {
  const _MediaPickerSheetBody();

  @override
  State<_MediaPickerSheetBody> createState() => _MediaPickerSheetBodyState();
}

class _MediaPickerSheetBodyState extends State<_MediaPickerSheetBody> {
  static const int _pageSize = 200;

  bool _dragStartedAtTop = false;
  final ScrollController _gridScrollController = ScrollController();
  List<AssetEntity> _assets = [];
  final Map<String, int> _selectedOrder = {};
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

  @override
  void initState() {
    super.initState();
    _load();
    _initLiveCamera();
    _gridScrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore) return;
    if (!_gridScrollController.hasClients) return;
    final position = _gridScrollController.position;
    if (position.pixels >= position.maxScrollExtent - 600) {
      _loadMore();
    }
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
      _assets = [..._assets, ...more]..sort((a, b) => _sortKey(b).compareTo(_sortKey(a)));
      _hasMore = more.length == _pageSize;
      _loadingMore = false;
    });
  }

  Future<void> _requestFullAccess() async {
    await PhotoManager.presentLimited(type: RequestType.common);
    setState(() {
      _loading = true;
      _page = 0;
      _hasMore = true;
    });
    await _load();
  }

  /// MediaStore не всегда успевает проиндексировать файл, снятый секунду
  /// назад, к моменту открытия шторки — ручное обновление без закрытия и
  /// повторного открытия листа.
  Future<void> _refreshAssets() async {
    setState(() {
      _loading = true;
      _page = 0;
      _hasMore = true;
      _thumbnailFutures.clear();
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
      final controller = CameraController(back, ResolutionPreset.low, enableAudio: false);
      await controller.initialize();
      if (mounted) setState(() => _liveCamera = controller);
    } catch (_) {
      // Нет доступа к камере — плитка останется кликабельной, просто без превью.
    }
  }

  Future<void> _load() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.hasAccess) {
      setState(() => _loading = false);
      return;
    }
    final isLimited = permission == PermissionState.limited;

    // onlyAll: true — просим именно единый объединённый альбом "Все", а не
    // первый попавшийся из списка папок (WhatsApp Images, Camera и т.п.);
    // firstWhere-с-фолбэком раньше при отсутствии isAll-альбома мог молча
    // подставить произвольную папку, где новых файлов просто нет.
    //
    // durationConstraint(allowNullable: true) — по умолчанию plugin
    // ИСКЛЮЧАЕТ видео с ещё не вычисленной длительностью (duration == null).
    // Свежезаписанный крупный (4K/десятки МБ) файл MediaStore может не
    // успеть проиндексировать полностью за секунды — именно поэтому фото из
    // той же папки видны сразу, а такое видео пропадает, пока сама ОС не
    // доиндексирует его в фоне.
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
      setState(() {
        _loading = false;
        _isLimitedAccess = isLimited;
      });
      return;
    }

    final allPath = paths.first;
    final assets = await allPath.getAssetListPaged(page: 0, size: _pageSize);
    assets.sort((a, b) => _sortKey(b).compareTo(_sortKey(a)));

    if (mounted) {
      setState(() {
        _allPath = allPath;
        _assets = assets;
        _hasMore = assets.length == _pageSize;
        _isLimitedAccess = isLimited;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _gridScrollController.removeListener(_onScroll);
    _gridScrollController.dispose();
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
    });
  }

  void _openCameraTile() {
    _liveCamera?.dispose();
    Navigator.pop(context, 'open_camera');
  }

  void _sendSelected(String caption) {
    final ordered = _assets.where((a) => _selectedOrder.containsKey(a.id)).toList()
      ..sort((a, b) => _selectedOrder[a.id]!.compareTo(_selectedOrder[b.id]!));
    Navigator.pop(context, MediaPickerSheetResult(ordered, caption));
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final hasSelection = _selectedOrder.isNotEmpty;

    return Material(
      color: AppColors.background,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 36,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.textMuted,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Positioned(
                    right: 4,
                    top: 0,
                    bottom: 0,
                    child: IconButton(
                      icon: const Icon(Icons.refresh, size: 20, color: AppColors.textMuted),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Обновить список файлов',
                      onPressed: _loading ? null : _refreshAssets,
                    ),
                  ),
                ],
              ),
            ),
            if (_isLimitedAccess)
              InkWell(
                onTap: _requestFullAccess,
                child: Container(
                  width: double.infinity,
                  color: AppColors.primary.withValues(alpha: 0.15),
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, size: 16, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Доступны не все файлы — нажмите, чтобы разрешить полный доступ',
                          style: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            SizedBox(
              height: screenHeight * 0.5,
              // Stack вместо прежнего "сетка + панель друг под другом в
              // Column" — панель описания теперь ЛЕЖИТ ПОВЕРХ сетки, не
              // сдвигая её вверх при появлении. Сетка остаётся на месте
              // целиком, просто частично перекрывается снизу.
              child: Stack(
                children: [
Positioned.fill(
  child: _loading
      ? const Center(child: CircularProgressIndicator())
      : NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            // Запоминаем, была ли позиция УЖЕ на самом верху в момент
            // НАЧАЛА этого конкретного жеста — иначе долгий свайп,
            // который просто докручивает список до верха и продолжается
            // дальше в рамках одного и того же движения пальца, тоже
            // закрывал бы шторку, что неверно.
            if (notification is ScrollStartNotification) {
              _dragStartedAtTop = notification.metrics.pixels <= 0;
            } else if (notification is OverscrollNotification) {
              if (_dragStartedAtTop && notification.overscroll < 0) {
                Navigator.pop(context);
              }
            }
            return false;
          },
          child: GridView.builder(
            controller: _gridScrollController,
            padding: EdgeInsets.zero,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 1,
            ),
            itemCount: _assets.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) return _buildCameraTile();
              return _buildMediaTile(_assets[index - 1]);
            },
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
      ),
    );
  }

  Widget _buildCameraTile() {
    return InkWell(
      onTap: _openCameraTile,
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: Colors.black26, width: 0.5)),
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
        decoration: BoxDecoration(border: Border.all(color: Colors.black26, width: 0.5)),
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
                    () => asset.thumbnailDataWithSize(const ThumbnailSize(200, 200)),
                  ),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done || snapshot.data == null) {
                      return Container(color: AppColors.surface);
                    }
                    return Image.memory(snapshot.data!, fit: BoxFit.cover);
                  },
                ),
                if (asset.type == AssetType.video)
                  const Positioned(
                    bottom: 4,
                    left: 4,
                    child: Icon(Icons.play_circle_fill, color: Colors.white, size: 20),
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
                            color: order != null ? AppColors.primary : Colors.black45,
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          alignment: Alignment.center,
                          child: order != null
                              ? Text(
                                  '$order',
                                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
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
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
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
          itemBuilder: (context, index) => _AssetPreviewPage(asset: widget.assets[index]),
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
      return const Center(child: CircularProgressIndicator(color: Colors.white));
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
    return const Center(child: Icon(Icons.broken_image, color: Colors.white54, size: 64));
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
          onTap: () => controller.value.isPlaying ? controller.pause() : controller.play(),
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
                    return const Icon(Icons.play_arrow, color: Colors.white70, size: 64);
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

        final positionMs = value.position.inMilliseconds.clamp(0, value.duration.inMilliseconds).toDouble();
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
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
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
                      widget.controller.seekTo(Duration(milliseconds: v.round()));
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