import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../widgets/vertical_dismiss_detector.dart';

/// Полноэкранный просмотрщик медиафайлов: горизонтальный свайп листает все
/// фото чата по порядку, вертикальный свайп (вверх или вниз) закрывает
/// просмотрщик — фото анимированно уходит в ту же сторону, куда его
/// смахнули. Системный жест "назад" закрывает просмотрщик как обычный
/// Navigator.pop, отдельно ничего обрабатывать не нужно.
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: VerticalDismissDetector(
        child: PageView.builder(
          controller: _pageController,
          itemCount: widget.items.length,
          itemBuilder: (context, index) => _MediaViewerPage<T>(
            item: widget.items[index],
            resolveBytes: widget.resolveBytes,
          ),
        ),
      ),
    );
  }
}

class _MediaViewerPage<T> extends StatefulWidget {
  final T item;
  final Future<Uint8List> Function(T item) resolveBytes;

  const _MediaViewerPage({required this.item, required this.resolveBytes});

  @override
  State<_MediaViewerPage<T>> createState() => _MediaViewerPageState<T>();
}

class _MediaViewerPageState<T> extends State<_MediaViewerPage<T>> {
  late final Future<Uint8List> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.resolveBytes(widget.item);
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
        return Center(child: Image.memory(snapshot.data!, fit: BoxFit.contain));
      },
    );
  }
}
