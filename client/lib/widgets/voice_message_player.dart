import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import '../services/media_playback_coordinator.dart';
import '../theme/app_theme.dart';

/// Плеер голосового сообщения — play/pause + полоска прогресса + время.
/// Файл расшифровывается лениво, только при первом нажатии play (см.
/// resolveFile — та же логика "скачать/расшифровать по требованию", что
/// уже используется для фото в чате).
///
/// coordinator/messageId — регистрация в верхней панели управления (см.
/// MediaPlaybackCoordinator и _buildMediaControlBar в chat_screen.dart) —
/// та же схема, что у VideoNotePlayer.
class VoiceMessagePlayer extends StatefulWidget {
  final bool isMine;
  final int? durationMs;
  // Текущий шаг отправки ("Шифрование…", "Загрузка на сервер…" и т.п.,
  // см. StoredMessage.processingStep) — не null, пока голосовое ещё
  // отправляется. Файл при этом уже лежит локально и в принципе
  // проигрывается (см. resolveFile), поэтому воспроизведение не блокируем
  // — просто заменяем строку с длительностью на текущий статус.
  final String? processingStep;
  final Future<File> Function() resolveFile;
  final MediaPlaybackCoordinator? coordinator;
  final String? messageId;

  const VoiceMessagePlayer({
    super.key,
    required this.isMine,
    required this.durationMs,
    this.processingStep,
    required this.resolveFile,
    this.coordinator,
    this.messageId,
  });

  @override
  State<VoiceMessagePlayer> createState() => _VoiceMessagePlayerState();
}

class _VoiceMessagePlayerState extends State<VoiceMessagePlayer> {
  final _player = AudioPlayer();
  StreamSubscription<void>? _completeSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  bool _loading = false;
  File? _file;

  @override
  void initState() {
    super.initState();
    _duration = widget.durationMs != null
        ? Duration(milliseconds: widget.durationMs!)
        : null;
    _posSub = _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _durSub = _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _position = Duration.zero;
        });
      }
      _reportPlayingState(false);
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _completeSub?.cancel();
    _player.dispose();
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
    await _player.pause();
    if (mounted) setState(() => _playing = false);
    _reportPlayingState(false);
  }

  Future<void> _doResume() async {
    if (_file == null) {
      setState(() => _loading = true);
      try {
        _file = await widget.resolveFile();
      } catch (_) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      if (!mounted) return;
      setState(() => _loading = false);
    }
    await _player.play(DeviceFileSource(_file!.path));
    if (mounted) setState(() => _playing = true);
    _registerWithCoordinator();
  }

  /// Явная остановка (крестик на верхней панели) — полная остановка (не
  /// просто пауза) + сброс позиции, плюс сообщаем панели, что сообщение
  /// больше не активно.
  Future<void> _doStop() async {
    await _player.stop();
    if (mounted) {
      setState(() {
        _playing = false;
        _position = Duration.zero;
      });
    }
    final id = widget.messageId;
    if (widget.coordinator != null && id != null) {
      widget.coordinator!.deactivate(id);
    }
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _doPause();
    } else {
      await _doResume();
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final isProcessing = widget.processingStep != null;
    final total = _duration ?? Duration.zero;
    final progress = total.inMilliseconds > 0
        ? (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final accent = widget.isMine ? Colors.white : AppColors.primary;
    final shownDuration = _playing || _position > Duration.zero
        ? _position
        : total;

    return SizedBox(
      width: 200,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            customBorder: const CircleBorder(),
            onTap: _loading ? null : _toggle,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withValues(alpha: 0.18),
              ),
              alignment: Alignment.center,
              child: _loading
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: accent,
                      ),
                    )
                  : Icon(
                      _playing ? Icons.pause : Icons.play_arrow,
                      color: accent,
                      size: 20,
                    ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: isProcessing ? null : progress,
                    minHeight: 3,
                    backgroundColor: accent.withValues(alpha: 0.2),
                    valueColor: AlwaysStoppedAnimation(accent),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isProcessing ? widget.processingStep! : _fmt(shownDuration),
                  style: TextStyle(
                    color: accent.withValues(alpha: 0.85),
                    fontSize: 11,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
