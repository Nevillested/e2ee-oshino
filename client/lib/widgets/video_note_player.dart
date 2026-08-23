import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../services/debug_log.dart';
import '../services/media_playback_coordinator.dart';

/// Проигрыватель видео-сообщения — квадрат со скруглёнными углами (у нас
/// не кружок, как в Телеге, а именно квадрат). Тап запускает/ставит на
/// паузу; во время проигрывания разворачивается до expandedSize, на паузе
/// снова сжимается до compactSize — ровно то поведение, которое просили.
///
/// coordinator/messageId — регистрация в верхней панели управления (см.
/// MediaPlaybackCoordinator и _buildMediaControlBar в chat_screen.dart):
/// оба опциональны, чтобы не ломать использование плеера где-то ещё без
/// панели, но ChatScreen их всегда передаёт.
class VideoNotePlayer extends StatefulWidget {
  final Future<File> Function() resolveFile;
  final int? durationMs;
  final double compactSize;
  final double expandedSize;
  // См. VoiceMessagePlayer.processingStep — тот же смысл, для видео-кружка.
  final String? processingStep;
  final MediaPlaybackCoordinator? coordinator;
  final String? messageId;

  const VideoNotePlayer({
    super.key,
    required this.resolveFile,
    required this.durationMs,
    this.compactSize = 200,
    required this.expandedSize,
    this.processingStep,
    this.coordinator,
    this.messageId,
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
    // Если это сообщение было "активным" в верхней панели, а сам виджет
    // уходит из дерева (проскроллили, ушли из чата) — панель не должна
    // остаться висеть, указывая на уже уничтоженный контроллер.
    final id = widget.messageId;
    if (widget.coordinator != null &&
        id != null &&
        widget.coordinator!.activeMessageId == id) {
      widget.coordinator!.deactivate(id);
    }
    super.dispose();
  }

  void _registerWithCoordinator() {
    final id = widget.messageId;
    if (widget.coordinator == null || id == null) return;
    widget.coordinator!.activate(
      id,
      pause: () => unawaited(_doPause()),
      resume: () => unawaited(_doResume()),
      stop: () => unawaited(_doStop()),
    );
  }

  void _reportPlayingState(bool playing) {
    final id = widget.messageId;
    if (widget.coordinator == null || id == null) return;
    widget.coordinator!.reportPlaying(id, playing);
  }

  Future<void> _doPause() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.pause();
    if (mounted) setState(() => _playing = false);
    _reportPlayingState(false);
  }

  Future<void> _doResume() async {
    final controller = _controller;
    if (controller == null) return;
    // На случай, если предыдущий _onTick ещё не успел довести до конца
    // свою перемотку в начало — досрочно дожидаемся её здесь тоже, иначе
    // play() может уйти на контроллер, который вот-вот сам домотает до 0 и
    // "перепрыгнет" только что начавшееся воспроизведение.
    if (controller.value.position > Duration.zero &&
        controller.value.position >= controller.value.duration) {
      await controller.seekTo(Duration.zero);
    }
    await controller.play();
    if (mounted) setState(() => _playing = true);
    _registerWithCoordinator();
  }

  /// Явная остановка (крестик на верхней панели) — пауза + перемотка в
  /// начало + схлопывание обратно до compactSize (см. build(): size
  /// зависит от _playing), плюс сообщаем панели, что сообщение больше не
  /// активно, чтобы она сама анимированно скрылась.
  Future<void> _doStop() async {
    final controller = _controller;
    if (controller != null) {
      await controller.pause();
      await controller.seekTo(Duration.zero);
    }
    if (mounted) setState(() => _playing = false);
    final id = widget.messageId;
    if (widget.coordinator != null && id != null) {
      widget.coordinator!.deactivate(id);
    }
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
        await _doPause();
        DebugLog.log('VideoNote _toggle() paused, setting playing=false');
      } else {
        await _doResume();
        DebugLog.log(
          'VideoNote _toggle() play() called, setting playing=true '
          'postPlay.isPlaying=${controller.value.isPlaying} postPlay.pos=${controller.value.position}',
        );
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
      _registerWithCoordinator();
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
      _reportPlayingState(false);
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
