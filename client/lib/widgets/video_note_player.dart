import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../services/debug_log.dart';

/// Проигрыватель видео-сообщения — квадрат со скруглёнными углами (у нас
/// не кружок, как в Телеге, а именно квадрат). Тап запускает/ставит на
/// паузу; во время проигрывания разворачивается до expandedSize, на паузе
/// снова сжимается до compactSize — ровно то поведение, которое просили.
class VideoNotePlayer extends StatefulWidget {
  final Future<File> Function() resolveFile;
  final int? durationMs;
  final double compactSize;
  final double expandedSize;
  // См. VoiceMessagePlayer.processingStep — тот же смысл, для видео-кружка.
  final String? processingStep;

  const VideoNotePlayer({
    super.key,
    required this.resolveFile,
    required this.durationMs,
    this.compactSize = 200,
    required this.expandedSize,
    this.processingStep,
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

  // Временное диагностическое логирование (см. обсуждение с пользователем
  // — тестировщик прислал жалобу "второй тап не воспроизводит повторно",
  // а прошлая попытка чинить это вслепую не помогла). Снять, когда баг
  // будет реально понят и закрыт.
  Future<void> _toggle() async {
    final controller = _controller;
    DebugLog.log(
      'VideoNote _toggle() called hasController=${controller != null} '
      'playing=$_playing loading=$_loading '
      '${controller != null ? 'pos=${controller.value.position} dur=${controller.value.duration} isPlaying=${controller.value.isPlaying}' : ''}',
    );
    if (controller != null) {
      if (_playing) {
        await controller.pause();
        DebugLog.log('VideoNote _toggle() paused, setting playing=false');
        if (mounted) setState(() => _playing = false);
      } else {
        // На случай, если предыдущий _onTick ещё не успел довести до конца
        // свою перемотку в начало — досрочно дожидаемся её здесь тоже,
        // иначе play() может уйти на контроллер, который вот-вот сам
        // домотает до 0 и "перепрыгнет" только что начавшееся воспроизведение.
        if (controller.value.position > Duration.zero &&
            controller.value.position >= controller.value.duration) {
          DebugLog.log('VideoNote _toggle() re-seeking to 0 before replay');
          await controller.seekTo(Duration.zero);
        }
        await controller.play();
        DebugLog.log(
          'VideoNote _toggle() play() called, setting playing=true '
          'postPlay.isPlaying=${controller.value.isPlaying} postPlay.pos=${controller.value.position}',
        );
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
      DebugLog.log(
        'VideoNote _toggle() first play, dur=${newController.value.duration}',
      );
      if (mounted) setState(() => _playing = true);
    } catch (e) {
      DebugLog.log('VideoNote _toggle() first-play FAILED error=$e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _onTick() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.duration > Duration.zero &&
        c.value.position >= c.value.duration) {
      DebugLog.log(
        'VideoNote _onTick() end-of-video detected pos=${c.value.position} '
        'dur=${c.value.duration} currentlyPlayingFlag=$_playing',
      );
      await c.pause();
      // Дожидаемся реального завершения перемотки, прежде чем сообщать UI
      // "готово к повторному воспроизведению" — раньше seekTo не
      // ожидался, и повторный тап мог прийти на контроллер, ещё не
      // закончивший перематываться в начало (видимо застревал на
      // развороте контейнера без реального рестарта видео).
      await c.seekTo(Duration.zero);
      DebugLog.log(
        'VideoNote _onTick() seek-to-0 done, actualPos=${c.value.position}, setting playing=false',
      );
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
              if (widget.processingStep != null)
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            widget.processingStep!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
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
