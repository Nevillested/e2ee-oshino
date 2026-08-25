import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';
import '../l10n/app_strings.dart';
import '../widgets/app_loading_indicator.dart';
import '../widgets/vertical_dismiss_detector.dart';

/// Папка в галерее устройства, куда сохраняются медиа через "Сохранить в
/// галерею" (см. _MediaViewerScreenState._saveCurrentToGallery) — общая для
/// фото (Pictures/Oshinobu) и видео (Movies/Oshinobu), чтобы обе категории
/// были узнаваемо сгруппированы под одним и тем же именем приложения.
const _kSaveFolderName = 'Oshinobu';

/// Полноэкранный просмотрщик медиафайлов: горизонтальный свайп листает все
/// фото чата по порядку, вертикальный свайп (вверх или вниз) закрывает
/// просмотрщик — фото анимированно уходит в ту же сторону, куда его
/// смахнули. Системный жест "назад" закрывает просмотрщик как обычный
/// Navigator.pop, отдельно ничего обрабатывать не нужно.
///
/// Фото можно масштабировать щипком (InteractiveViewer) или двойным тапом —
/// пока оно увеличено, и горизонтальное перелистывание, и вертикальное
/// закрытие свайпом выключены (см. _blockSiblingGestures): иначе они
/// спорили бы за один и тот же палец с попыткой подвигать увеличенную
/// картинку.
class MediaViewerScreen<T> extends StatefulWidget {
  final List<T> items;
  final int initialIndex;
  // Для фото — сами байты (см. _MediaViewerPage.build). Для видео —
  // тоже используется, но только в _saveCurrentToGallery как фолбэк, если
  // resolveVideoFile не задан; основной путь воспроизведения видео —
  // resolveVideoFile ниже, который отдаёт реальный файл, а не кадр-превью.
  final Future<Uint8List> Function(
    T item, {
    void Function(double percent)? onProgress,
  })
  resolveBytes;
  final bool Function(T item)? isVideo;
  // Отдаёт СКАЧАННЫЙ/расшифрованный видеофайл целиком (не байты!) — нужен
  // отдельно от resolveBytes, потому что у видео-сообщений в чате byte-байты
  // (см. ChatScreen._resolvePhotoBytes) — это уже кадр-превью, а не сам
  // видеофайл (см. ТЗ пользователя: превью должно быть у видео тоже, но
  // воспроизводить в просмотрщике нужно настоящее видео).
  final Future<File> Function(
    T item, {
    void Function(double percent)? onProgress,
  })?
  resolveVideoFile;

  const MediaViewerScreen({
    super.key,
    required this.items,
    required this.initialIndex,
    required this.resolveBytes,
    this.isVideo,
    this.resolveVideoFile,
  });

  @override
  State<MediaViewerScreen<T>> createState() => _MediaViewerScreenState<T>();
}

class _MediaViewerScreenState<T> extends State<MediaViewerScreen<T>> {
  late final PageController _pageController;
  bool _zoomed = false;

  // Сколько пальцев сейчас реально касаются экрана — считаем через сырые
  // указатели (Listener), а не через жесты: жест ещё только-только начинает
  // разбираться, кто его "выиграл" (PageView, свайп-закрытие или щипок
  // внутри InteractiveViewer), и к этому моменту обычно уже поздно —
  // конкурирующий однопальцевый детектор вертикального свайпа успевает
  // застолбить арену раньше, чем InteractiveViewer поймёт, что пальцев два.
  // Из-за этого щипок нередко вообще не срабатывал. А вот Listener видит
  // КАЖДОЕ касание сразу, без ожидания жеста — реагируя на него, мы
  // выключаем соседние жесты (PageView/свайп-закрытие) ДО того, как арена
  // вообще успела решить, кому достанется первый палец.
  int _activePointers = 0;

  bool get _blockSiblingGestures => _zoomed || _activePointers >= 2;

  late int _currentIndex;
  bool _saving = false;

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

  void _handleZoomChanged(bool zoomed) {
    if (zoomed == _zoomed) return;
    setState(() => _zoomed = zoomed);
  }

  void _incrementPointers(PointerDownEvent _) {
    setState(() => _activePointers++);
  }

  void _decrementPointers(PointerEvent _) {
    if (_activePointers == 0) return;
    setState(() => _activePointers--);
  }

  void _onPageChanged(int index) {
    _currentIndex = index;
    _handleZoomChanged(false);
  }

  /// Сохраняет байты ТЕКУЩЕЙ открытой страницы в системную галерею, в папку
  /// [_kSaveFolderName] — через PhotoManager (уже используется в проекте для
  /// чтения галереи, см. MediaAssetCache), просто в режиме записи. На
  /// Android relativePath работает только с версии 10 (API 29) и выше —
  /// ниже PhotoManager сам сохраняет файл без вложенной папки, и это
  /// приемлемый деградейшн, а не ошибка.
  Future<void> _saveCurrentToGallery() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final item = widget.items[_currentIndex];
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.hasAccess) {
        if (!mounted) return;
        _showSnackBar(
          tr('mediaViewer.savePermissionDenied'),
          action: SnackBarAction(
            label: tr('mediaViewer.openSettings'),
            onPressed: PhotoManager.openSetting,
          ),
        );
        return;
      }

      final isVideoItem = widget.isVideo?.call(item) ?? false;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      if (isVideoItem && widget.resolveVideoFile != null) {
        // Настоящий видеофайл (не кадр-превью из resolveBytes) — уже лежит
        // расшифрованным в MediaCache к этому моменту, saveVideo сам его
        // просто копирует, оригинал не трогает.
        final file = await widget.resolveVideoFile!(item);
        await PhotoManager.editor.saveVideo(
          file,
          title: 'oshinobu_$stamp.mp4',
          relativePath: 'Movies/$_kSaveFolderName',
        );
      } else {
        final bytes = await widget.resolveBytes(item);
        await PhotoManager.editor.saveImage(
          bytes,
          filename: 'oshinobu_$stamp.jpg',
          relativePath: 'Pictures/$_kSaveFolderName',
        );
      }

      if (!mounted) return;
      _showSnackBar(tr('mediaViewer.saved'));
    } catch (_) {
      if (!mounted) return;
      _showSnackBar(tr('mediaViewer.saveFailed'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showSnackBar(String message, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: action,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _buildOverflowMenu() {
    return SafeArea(
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.only(top: 4, right: 4),
          child: Material(
            color: Colors.transparent,
            child: PopupMenuButton<String>(
              tooltip: '',
              color: const Color(0xFF1C1C1E),
              icon: _saving
                  ? const AppLoadingIndicator(size: 20, color: Colors.white)
                  : const Icon(Icons.more_vert, color: Colors.white),
              onSelected: (_) => _saveCurrentToGallery(),
              itemBuilder: (context) => [
                PopupMenuItem<String>(
                  value: 'save',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.download_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        tr('mediaViewer.saveToGallery'),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Listener(
            onPointerDown: _incrementPointers,
            onPointerUp: _decrementPointers,
            onPointerCancel: _decrementPointers,
            child: VerticalDismissDetector(
              enabled: !_blockSiblingGestures,
              child: PageView.builder(
                controller: _pageController,
                physics: _blockSiblingGestures
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                // Новая открытая страница всегда стартует неувеличенной —
                // даже если Flutter почему-то не пересоздал widget соседней
                // страницы, явно сбрасываем состояние при каждом
                // перелистывании.
                onPageChanged: _onPageChanged,
                itemCount: widget.items.length,
                itemBuilder: (context, index) {
                  final item = widget.items[index];
                  return _MediaViewerPage<T>(
                    item: item,
                    resolveBytes: widget.resolveBytes,
                    isVideo: widget.isVideo?.call(item) ?? false,
                    resolveVideoFile: widget.resolveVideoFile,
                    onZoomChanged: _handleZoomChanged,
                  );
                },
              ),
            ),
          ),
          _buildOverflowMenu(),
        ],
      ),
    );
  }
}

class _MediaViewerPage<T> extends StatefulWidget {
  final T item;
  final Future<Uint8List> Function(
    T item, {
    void Function(double percent)? onProgress,
  })
  resolveBytes;
  final bool isVideo;
  final Future<File> Function(
    T item, {
    void Function(double percent)? onProgress,
  })?
  resolveVideoFile;
  final ValueChanged<bool> onZoomChanged;

  const _MediaViewerPage({
    required this.item,
    required this.resolveBytes,
    required this.isVideo,
    required this.resolveVideoFile,
    required this.onZoomChanged,
  });

  @override
  State<_MediaViewerPage<T>> createState() => _MediaViewerPageState<T>();
}

class _MediaViewerPageState<T> extends State<_MediaViewerPage<T>>
    with SingleTickerProviderStateMixin {
  // Ровно один из двух реально используется — какой именно, решает
  // widget.isVideo (см. initState): для видео нужен настоящий файл (чтобы
  // проиграть его), для фото — байты кадра (Image.memory).
  Future<Uint8List>? _bytesFuture;
  Future<File>? _videoFuture;
  final _transformationController = TransformationController();
  late final AnimationController _zoomAnimController;
  Animation<Matrix4>? _zoomAnim;
  Offset? _lastDoubleTapPosition;
  // Живой процент скачивания — те же байты, что и в чате (см.
  // ChatScreen._resolvePhotoBytes), поэтому и индикация та же: число
  // в %, а не декоративный спиннер (ТЗ пользователя).
  double _downloadPercent = 0;

  static const double _doubleTapZoom = 2.75;

  @override
  void initState() {
    super.initState();
    void onProgress(double percent) {
      if (mounted) setState(() => _downloadPercent = percent);
    }

    if (widget.isVideo && widget.resolveVideoFile != null) {
      _videoFuture = widget.resolveVideoFile!(
        widget.item,
        onProgress: onProgress,
      );
    } else {
      _bytesFuture = widget.resolveBytes(widget.item, onProgress: onProgress);
    }
    _transformationController.addListener(_onTransformChanged);
    _zoomAnimController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 220),
        )..addListener(() {
          if (_zoomAnim != null) {
            _transformationController.value = _zoomAnim!.value;
          }
        });
  }

  @override
  void dispose() {
    _transformationController.removeListener(_onTransformChanged);
    _transformationController.dispose();
    _zoomAnimController.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final scale = _transformationController.value.getMaxScaleOnAxis();
    // Небольшой запас (не ровно 1.0) — иначе микроскопические погрешности
    // округления после отпускания жеста иногда оставляли бы _zoomed=true
    // даже когда фото визуально уже вернулось к исходному размеру.
    widget.onZoomChanged(scale > 1.01);
  }

  void _animateTo(Matrix4 target) {
    _zoomAnim =
        Matrix4Tween(
          begin: _transformationController.value,
          end: target,
        ).animate(
          CurvedAnimation(parent: _zoomAnimController, curve: Curves.easeOut),
        );
    _zoomAnimController.forward(from: 0);
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    _lastDoubleTapPosition = details.localPosition;
  }

  /// Двойной тап — как в Телеге: увеличивает вокруг точки тапа, если сейчас
  /// не увеличено, иначе просто возвращает к исходному размеру.
  void _handleDoubleTap() {
    final currentScale = _transformationController.value.getMaxScaleOnAxis();
    if (currentScale > 1.01) {
      _animateTo(Matrix4.identity());
      return;
    }
    final pos = _lastDoubleTapPosition ?? Offset.zero;
    final target = Matrix4.identity()
      ..translateByDouble(pos.dx, pos.dy, 0, 1)
      ..scaleByDouble(_doubleTapZoom, _doubleTapZoom, _doubleTapZoom, 1)
      ..translateByDouble(-pos.dx, -pos.dy, 0, 1);
    _animateTo(target);
  }

  Widget _percentIndicator() {
    return Center(
      child: Text(
        '${_downloadPercent.round()}%',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_videoFuture != null) {
      return FutureBuilder<File>(
        future: _videoFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _percentIndicator();
          }
          if (snapshot.hasError || snapshot.data == null) {
            return const Center(
              child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
            );
          }
          return _FullScreenVideo(file: snapshot.data!);
        },
      );
    }
    return FutureBuilder<Uint8List>(
      future: _bytesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _percentIndicator();
        }
        if (snapshot.hasError || snapshot.data == null) {
          return const Center(
            child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
          );
        }
        return GestureDetector(
          onDoubleTapDown: _handleDoubleTapDown,
          onDoubleTap: _handleDoubleTap,
          child: InteractiveViewer(
            transformationController: _transformationController,
            minScale: 1.0,
            maxScale: 5.0,
            child: Center(
              child: Image.memory(snapshot.data!, fit: BoxFit.contain),
            ),
          ),
        );
      },
    );
  }
}

/// Проигрыватель видео на всю страницу просмотрщика — тап ставит на
/// паузу/возобновляет, поверх паузы виден полупрозрачный треугольник play
/// (тот же язык, что и у VideoNotePlayer в чате). Без щипка-зума и
/// двойного тапа — в отличие от фото, они тут конфликтовали бы с обычным
/// прогрессом воспроизведения и не являются ожидаемым поведением для видео.
class _FullScreenVideo extends StatefulWidget {
  final File file;
  const _FullScreenVideo({required this.file});

  @override
  State<_FullScreenVideo> createState() => _FullScreenVideoState();
}

class _FullScreenVideoState extends State<_FullScreenVideo> {
  late final VideoPlayerController _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(widget.file)
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() => _ready = true);
        _controller.play();
      });
    _controller.addListener(_onTick);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTick);
    _controller.dispose();
    super.dispose();
  }

  void _onTick() {
    // Только чтобы иконка play/pause отражала реальное состояние — тик
    // видеопозиции сам по себе не важен, отдельный прогресс-бар не нужен
    // (это просмотрщик, а не плеер с таймлайном).
    if (mounted) setState(() {});
  }

  void _toggle() {
    if (_controller.value.isPlaying) {
      _controller.pause();
    } else {
      _controller.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Center(child: AppLoadingIndicator(color: Colors.white));
    }
    return GestureDetector(
      onTap: _toggle,
      child: Center(
        child: AspectRatio(
          aspectRatio: _controller.value.aspectRatio,
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPlayer(_controller),
              if (!_controller.value.isPlaying)
                Container(
                  decoration: const BoxDecoration(
                    color: Colors.black38,
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(16),
                  child: const Icon(
                    Icons.play_arrow,
                    color: Colors.white,
                    size: 48,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
