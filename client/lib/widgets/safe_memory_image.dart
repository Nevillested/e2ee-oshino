import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../services/image_normalize.dart';
import 'app_loading_indicator.dart';

/// Image.memory с автоматическим фолбэком на нормализацию (см.
/// services/image_normalize.dart) — реальный кейс с устройства: JPEG с
/// Pixel 7 Pro (Ultra HDR) стабильно не декодируется нативным Android-
/// декодером конкретно на эмуляторе ("Failed to create image decoder...
/// unimplemented"), хотя байты полностью валидны (обычный чистый
/// Dart-декодер их читает без единой ошибки). При сбое нативного
/// декодирования один раз пересохраняем изображение без "лишних"
/// сегментов (MPF/огромный XMP) через чистый Dart-путь и показываем уже
/// его — вместо того чтобы просто сдаться и показать сломанную иконку.
class SafeMemoryImage extends StatefulWidget {
  final Uint8List bytes;
  final BoxFit fit;
  final int? cacheWidth;
  final Widget Function(BuildContext context)? brokenBuilder;

  const SafeMemoryImage({
    super.key,
    required this.bytes,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.brokenBuilder,
  });

  @override
  State<SafeMemoryImage> createState() => _SafeMemoryImageState();
}

enum _NormalizeState { idle, running, done, failed }

class _SafeMemoryImageState extends State<SafeMemoryImage> {
  Uint8List? _normalized;
  _NormalizeState _state = _NormalizeState.idle;

  Future<void> _tryNormalize() async {
    if (_state != _NormalizeState.idle) return;
    _state = _NormalizeState.running;
    final result = await normalizeJpegBytes(widget.bytes);
    if (!mounted) return;
    setState(() {
      _normalized = result;
      _state = result != null ? _NormalizeState.done : _NormalizeState.failed;
    });
  }

  Widget _broken(BuildContext context) {
    return widget.brokenBuilder?.call(context) ??
        const Center(child: Icon(Icons.broken_image, color: Colors.red));
  }

  @override
  void didUpdateWidget(covariant SafeMemoryImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) {
      _normalized = null;
      _state = _NormalizeState.idle;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_normalized != null) {
      return Image.memory(
        _normalized!,
        fit: widget.fit,
        cacheWidth: widget.cacheWidth,
        errorBuilder: (context, error, stackTrace) => _broken(context),
      );
    }
    return Image.memory(
      widget.bytes,
      fit: widget.fit,
      cacheWidth: widget.cacheWidth,
      errorBuilder: (context, error, stackTrace) {
        if (_state == _NormalizeState.failed) return _broken(context);
        // errorBuilder обязан вернуть виджет синхронно — сам запуск
        // асинхронной нормализации откладываем на кадр позже, чтобы не
        // дёргать setState прямо из чужого builder'а.
        if (_state == _NormalizeState.idle) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _tryNormalize();
          });
        }
        return const Center(child: AppLoadingIndicator(size: 22));
      },
    );
  }
}
