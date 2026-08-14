import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../widgets/vertical_dismiss_detector.dart';

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
  final Future<Uint8List> Function(T item) resolveBytes;

  const MediaViewerScreen({
    super.key,
    required this.items,
    required this.initialIndex,
    required this.resolveBytes,
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

  @override
  void initState() {
    super.initState();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Listener(
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
            // Новая открытая страница всегда стартует неувеличенной — даже
            // если Flutter почему-то не пересоздал widget соседней страницы,
            // явно сбрасываем состояние при каждом перелистывании.
            onPageChanged: (_) => _handleZoomChanged(false),
            itemCount: widget.items.length,
            itemBuilder: (context, index) => _MediaViewerPage<T>(
              item: widget.items[index],
              resolveBytes: widget.resolveBytes,
              onZoomChanged: _handleZoomChanged,
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaViewerPage<T> extends StatefulWidget {
  final T item;
  final Future<Uint8List> Function(T item) resolveBytes;
  final ValueChanged<bool> onZoomChanged;

  const _MediaViewerPage({
    required this.item,
    required this.resolveBytes,
    required this.onZoomChanged,
  });

  @override
  State<_MediaViewerPage<T>> createState() => _MediaViewerPageState<T>();
}

class _MediaViewerPageState<T> extends State<_MediaViewerPage<T>>
    with SingleTickerProviderStateMixin {
  late final Future<Uint8List> _future;
  final _transformationController = TransformationController();
  late final AnimationController _zoomAnimController;
  Animation<Matrix4>? _zoomAnim;
  Offset? _lastDoubleTapPosition;

  static const double _doubleTapZoom = 2.75;

  @override
  void initState() {
    super.initState();
    _future = widget.resolveBytes(widget.item);
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
    _zoomAnim = Matrix4Tween(
      begin: _transformationController.value,
      end: target,
    ).animate(CurvedAnimation(parent: _zoomAnimController, curve: Curves.easeOut));
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

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
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
