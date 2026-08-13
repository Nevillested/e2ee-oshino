import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Проигрыватель видео-сообщения — квадрат со скруглёнными углами (у нас
/// не кружок, как в Телеге, а именно квадрат). Тап запускает/ставит на
/// паузу; во время проигрывания разворачивается до expandedSize, на паузе
/// снова сжимается до compactSize — ровно то поведение, которое просили.
class VideoNotePlayer extends StatefulWidget {
  final Future<File> Function() resolveFile;
  final int? durationMs;
  final double compactSize;
  final double expandedSize;

  const VideoNotePlayer({
    super.key,
    required this.resolveFile,
    required this.durationMs,
    this.compactSize = 200,
    required this.expandedSize,
  });

  @override
  State<VideoNotePlayer> createState() => _VideoNotePlayerState();
}

class _VideoNotePlayerState extends State<VideoNotePlayer> {
  VideoPlayerController? _controller;
  bool _loading = false;
  bool _playing = false;

  @override
  void dispose() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final controller = _controller;
    if (controller != null) {
      if (_playing) {
        await controller.pause();
        if (mounted) setState(() => _playing = false);
      } else {
        await controller.play();
        if (mounted) setState(() => _playing = true);
      }
      return;
    }

    setState(() => _loading = true);
    try {
      final file = await widget.resolveFile();
      final newController = VideoPlayerController.file(file);
      await newController.initialize();
      await newController.setLooping(false);
      newController.addListener(_onTick);
      if (!mounted) {
        newController.dispose();
        return;
      }
      setState(() {
        _controller = newController;
        _loading = false;
      });
      await newController.play();
      if (mounted) setState(() => _playing = true);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onTick() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.duration > Duration.zero &&
        c.value.position >= c.value.duration) {
      c.pause();
      c.seekTo(Duration.zero);
      if (mounted) setState(() => _playing = false);
    }
  }

  String _fmt(int? ms) {
    if (ms == null) return '';
    final d = Duration(milliseconds: ms);
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final size = _playing ? widget.expandedSize : widget.compactSize;
    final controller = _controller;
    return GestureDetector(
      onTap: _loading ? null : _toggle,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        width: size,
        height: size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(color: Colors.black),
              if (controller != null && controller.value.isInitialized)
                FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: controller.value.size.width,
                    height: controller.value.size.height,
                    child: VideoPlayer(controller),
                  ),
                ),
              if (!_playing)
                Center(
                  child: _loading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : Container(
                          width: 46,
                          height: 46,
                          decoration: const BoxDecoration(
                            color: Colors.black45,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.play_arrow,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                ),
              if (widget.durationMs != null)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _fmt(widget.durationMs),
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
