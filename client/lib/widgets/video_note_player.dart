import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../l10n/app_strings.dart';
import '../services/debug_log.dart';
import '../services/media_playback_coordinator.dart';
import 'media_status_overlay.dart';

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
  final Future<File> Function({void Function(double percent)? onProgress})
  resolveFile;
  // Кадр-превью — ОТДЕЛЬНО от resolveFile: там байты, тут сам файл для
  // проигрывания. Раньше, пока не тапнули play, был просто чёрный квадрат
  // (ТЗ пользователя) — теперь виден реальный кадр, как у обычного видео
  // из галереи (см. ChatScreen._resolveVideoThumbnailBytes).
  final Future<Uint8List> Function({void Function(double percent)? onProgress})?
  resolveThumbnail;
  // Локальный файл кадра-превью — только у СВОИХ ещё не отправленных (или
  // уже отправленных, но не перезагруженных с нуля) сообщений, см.
  // ChatScreen._sendRecordedMessage/_writeLocalVideoThumbnail. Пока он есть,
  // resolveThumbnail вообще не вызывается — у своего сообщения mediaId
  // может ещё не существовать (см. тот же приём для обычного видео).
  final String? localPreviewPath;
  final int? durationMs;
  final double compactSize;
  final double expandedSize;
  // Фаза отправки ("Шифрование…", "В очереди…" и т.п.) — не null, пока
  // свой файл ещё не отправлен целиком, см. StoredMessage.processingStep.
  final String? processingStep;
  // Живой процент ИСХОДЯЩЕЙ загрузки на сервер — см.
  // ChatScreen._uploadProgress. null, если сейчас не идёт реальная
  // передача байт (другая фаза, например шифрование).
  final double? uploadPercent;
  final MediaPlaybackCoordinator? coordinator;
  final String? messageId;

  const VideoNotePlayer({
    super.key,
    required this.resolveFile,
    this.resolveThumbnail,
    this.localPreviewPath,
    required this.durationMs,
    this.compactSize = 200,
    required this.expandedSize,
    this.processingStep,
    this.uploadPercent,
    this.coordinator,
    this.messageId,
  });

  @override
  State<VideoNotePlayer> createState() => _VideoNotePlayerState();
}

class _VideoNotePlayerState extends State<VideoNotePlayer> {
  VideoPlayerController? _controller;
  bool _loading = false;
  double _downloadPercent = 0;
  bool _playing = false;

  Uint8List? _thumbnailBytes;
  bool _thumbnailLoading = false;
  double _thumbnailPercent = 0;

  // Защита от повторного входа в обработку "конец видео" (см. _onTick):
  // addListener у video_player может выстрелить несколько раз подряд, пока
  // позиция уже >= длительности, а предыдущий (асинхронный) вызов ещё не
  // успел домотать pause()+seekTo(0) — без гварда это могло запускать
  // НЕСКОЛЬКО параллельных перемоток в начало одного и того же контроллера.
  // Плюс диагностическое логирование (см. _toggle/_onTick ниже) — жалоба
  // тестировщика "повторно видео не воспроизводится без выхода из чата".
  bool _handlingEnd = false;

  @override
  void initState() {
    super.initState();
    DebugLog.log('VideoNote initState messageId=${widget.messageId}');
    // Свой кадр-превью грузить не нужно — у своих сообщений он либо уже
    // есть локально (localPreviewPath), либо появится после отправки
    // (тогда виджет пересоберётся с новым localPreviewPath). Чужие —
    // качаем кадр сразу, автоматически, тем же способом, что и обычное
    // видео из галереи (ТЗ пользователя: "когда пользователю присылают
    // видеосообщения... надо писать текстовый статус и сколько скачано").
    if (widget.localPreviewPath == null && widget.resolveThumbnail != null) {
      unawaited(_loadThumbnail());
    }
  }

  Future<void> _loadThumbnail() async {
    setState(() {
      _thumbnailLoading = true;
      _thumbnailPercent = 0;
    });
    try {
      final bytes = await widget.resolveThumbnail!(
        onProgress: (percent) {
          if (mounted) setState(() => _thumbnailPercent = percent);
        },
      );
      if (!mounted) return;
      setState(() {
        _thumbnailBytes = bytes;
        _thumbnailLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _thumbnailLoading = false);
    }
  }

  @override
  void didUpdateWidget(covariant VideoNotePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messageId != widget.messageId) {
      DebugLog.log(
        'VideoNote didUpdateWidget messageId changed '
        '${oldWidget.messageId} -> ${widget.messageId}',
      );
    }
    // Своё сообщение только что отправилось — localPreviewPath пропал
    // из null? нет, наоборот: он был null → появился (или наоборот, редкий
    // случай) не наш кейс. Актуальный переход — было "нет resolveThumbnail
    // ещё не пробовали" → mediaId уже есть. Проще всего: если кадра до сих
    // пор нет и теперь можно попробовать — пробуем.
    if (_thumbnailBytes == null &&
        !_thumbnailLoading &&
        widget.localPreviewPath == null &&
        widget.resolveThumbnail != null &&
        oldWidget.resolveThumbnail == null) {
      unawaited(_loadThumbnail());
    }
  }

  @override
  void dispose() {
    DebugLog.log(
      'VideoNote dispose messageId=${widget.messageId} '
      'hadController=${_controller != null} playing=$_playing',
    );
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
      pause: () {
        DebugLog.log('VideoNote coordinator->pause messageId=$id');
        unawaited(_doPause());
      },
      resume: () {
        DebugLog.log('VideoNote coordinator->resume messageId=$id');
        unawaited(_doResume());
      },
      stop: () {
        DebugLog.log('VideoNote coordinator->stop messageId=$id');
        unawaited(_doStop());
      },
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
    if (controller == null) {
      // Контроллера уже нет — см. _onTick/_doStop: после конца видео или
      // явной остановки мы теперь ПЕРЕСОЗДАЁМ контроллер с нуля вместо
      // того, чтобы доигрывать старый (см. комментарий там, причина —
      // подтверждённый по логам баг video_player на Android). Верхняя
      // панель управления может прислать resume уже после этого — ведём
      // себя как обычный холодный старт.
      await _startFresh();
      return;
    }
    DebugLog.log('VideoNote _doResume() start ${_stateSnapshot(controller)}');
    await controller.play();
    DebugLog.log(
      'VideoNote _doResume() play() returned ${_stateSnapshot(controller)}',
    );
    if (mounted) setState(() => _playing = true);
    _registerWithCoordinator();
    // Само play() иногда завершается, даже если декодер реально не
    // возобновил выдачу кадров (частая проблема video_player на Android
    // после seekTo в конец/начало) — is Playing=true сразу после play() это
    // не докажет. Проверяем позицию ещё раз спустя паузу: если она не
    // сдвинулась вообще — воспроизведение не идёт, несмотря на успешный
    // play().
    final posAtPlay = controller.value.position;
    unawaited(
      Future.delayed(const Duration(milliseconds: 400), () {
        if (!mounted || _controller != controller) return;
        final moved = controller.value.position != posAtPlay;
        DebugLog.log(
          'VideoNote _doResume() +400ms check moved=$moved '
          '${_stateSnapshot(controller)}',
        );
      }),
    );
  }

  String _stateSnapshot(VideoPlayerController controller) {
    final v = controller.value;
    return 'pos=${v.position} dur=${v.duration} isPlaying=${v.isPlaying} '
        'isInitialized=${v.isInitialized} hasError=${v.hasError} '
        'errorDescription=${v.errorDescription}';
  }

  /// Явная остановка (крестик на верхней панели) — схлопывание обратно до
  /// compactSize (см. build(): size зависит от _playing), плюс сообщаем
  /// панели, что сообщение больше не активно, чтобы она сама анимированно
  /// скрылась. Контроллер не просто ставим на паузу+перематываем в начало,
  /// а полностью уничтожаем (см. _onTick — та же причина: video_player на
  /// Android не всегда возобновляет декодирование после seekTo(0), надёжно
  /// работает только пересоздание с нуля при следующем плее).
  Future<void> _doStop() async {
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_onTick);
      await controller.pause();
      await controller.dispose();
    }
    if (mounted) {
      setState(() {
        _controller = null;
        _playing = false;
      });
    }
    final id = widget.messageId;
    if (widget.coordinator != null && id != null) {
      widget.coordinator!.deactivate(id);
    }
  }

  // Временное диагностическое логирование (см. обсуждение с пользователем
  // — тестировщик прислал жалобу "второй тап не воспроизводит повторно",
  // разобрано по присланному debug_log: play() после seekTo(0) на конце
  // видео стабильно репортит isPlaying=true, но позиция навсегда
  // застревает на 0 — известная особенность video_player/ExoPlayer на
  // Android. Оставляем логи как есть — полезны и для будущей диагностики).
  Future<void> _toggle() async {
    final controller = _controller;
    DebugLog.log(
      'VideoNote _toggle() called messageId=${widget.messageId} '
      'hasController=${controller != null} playing=$_playing loading=$_loading '
      '${controller != null ? _stateSnapshot(controller) : ''}',
    );
    if (controller != null) {
      if (_playing) {
        await _doPause();
        DebugLog.log(
          'VideoNote _toggle() paused, setting playing=false '
          '${_stateSnapshot(controller)}',
        );
      } else {
        await _doResume();
        DebugLog.log(
          'VideoNote _toggle() resume flow done, setting playing=true '
          '${_stateSnapshot(controller)}',
        );
      }
      return;
    }

    await _startFresh();
  }

  /// "Холодный старт" — создаёт контроллер с нуля, инициализирует и сразу
  /// проигрывает. Единственный путь, который в присланном debug_log
  /// отработал НАДЁЖНО каждый раз (в отличие от play() на уже
  /// существующем, однажды доигранном до конца контроллере — см. _onTick/
  /// _doStop, которые поэтому теперь полностью уничтожают контроллер
  /// вместо paused-в-начале). Вызывается и из _toggle() (первый тап), и из
  /// _doResume() (повторный тап/панель управления — после того, как
  /// предыдущий контроллер уже уничтожен).
  Future<void> _startFresh() async {
    setState(() {
      _loading = true;
      _downloadPercent = 0;
    });
    try {
      final file = await widget.resolveFile(
        onProgress: (percent) {
          if (mounted) setState(() => _downloadPercent = percent);
        },
      );
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
        'VideoNote _startFresh() play ${_stateSnapshot(newController)}',
      );
      if (mounted) setState(() => _playing = true);
      _registerWithCoordinator();
    } catch (e) {
      DebugLog.log('VideoNote _startFresh() FAILED error=$e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _onTick() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.duration > Duration.zero &&
        c.value.position >= c.value.duration) {
      if (_handlingEnd) {
        // addListener у video_player может выстрелить несколько раз
        // подряд, пока позиция ещё не сброшена предыдущим вызовом — без
        // этого гварда сюда могли одновременно попасть несколько
        // параллельных pause()+seekTo(0), гоняющихся друг за другом по
        // одному и тому же platform-каналу. Логируем сам факт — если это
        // реально происходит часто, вот прямое тому доказательство.
        DebugLog.log(
          'VideoNote _onTick() end-of-video re-entrant call SKIPPED '
          'pos=${c.value.position} dur=${c.value.duration}',
        );
        return;
      }
      _handlingEnd = true;
      DebugLog.log(
        'VideoNote _onTick() end-of-video detected ${_stateSnapshot(c)} '
        'currentlyPlayingFlag=$_playing',
      );
      try {
        // Раньше тут были pause()+seekTo(0), доигрывая старый контроллер —
        // по debug_log это ЕДИНСТВЕННОЕ место, откуда начинается стабильно
        // воспроизводящийся баг: play() после такого seekTo репортит
        // isPlaying=true, но позиция навсегда застревает на 0 (проверено
        // +400ms замером в _doResume — moved=false на каждой последующей
        // попытке). Вместо доигровки — полностью уничтожаем контроллер;
        // следующий тап пойдёт через холодный старт (_startFresh),
        // единственный путь, что в логе работал каждый раз без сбоев.
        c.removeListener(_onTick);
        await c.pause();
        await c.dispose();
        DebugLog.log('VideoNote _onTick() disposed controller after end');
        if (mounted) {
          setState(() {
            _controller = null;
            _playing = false;
          });
        }
        // Естественное завершение — в отличие от обычной паузы, верхняя
        // панель управления должна исчезнуть целиком, а не просто
        // переключить иконку на play (ТЗ пользователя).
        final id = widget.messageId;
        if (widget.coordinator != null && id != null) {
          widget.coordinator!.deactivate(id);
        }
      } finally {
        _handlingEnd = false;
      }
    }
  }

  String _fmt(int? ms) {
    if (ms == null) return '';
    final d = Duration(milliseconds: ms);
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _buildThumbnail() {
    if (widget.localPreviewPath != null) {
      return Image.file(File(widget.localPreviewPath!), fit: BoxFit.cover);
    }
    if (_thumbnailBytes != null) {
      return Image.memory(_thumbnailBytes!, fit: BoxFit.cover);
    }
    return Container(color: Colors.black);
  }

  @override
  Widget build(BuildContext context) {
    final size = _playing ? widget.expandedSize : widget.compactSize;
    final controller = _controller;
    // Ровно один из трёх — своя отправка, чужое скачивание кадра, либо
    // догрузка самого файла по тапу play (см. ТЗ пользователя: везде на
    // миниатюре нужен текстовый статус и, если сейчас реальная передача
    // байт — процент).
    final sendingOverlay = widget.processingStep != null
        ? MediaStatusOverlay(
            statusText: widget.processingStep!,
            percent: widget.uploadPercent,
            size: size,
            borderRadius: BorderRadius.circular(18),
          )
        : null;
    final receivingOverlay = sendingOverlay == null && _thumbnailLoading
        ? MediaStatusOverlay(
            statusText: tr('media.downloading'),
            percent: _thumbnailPercent,
            size: size,
            borderRadius: BorderRadius.circular(18),
          )
        : null;
    final playTapOverlay =
        sendingOverlay == null && receivingOverlay == null && _loading
        ? MediaStatusOverlay(
            statusText: tr('media.downloading'),
            percent: _downloadPercent,
            size: size,
            borderRadius: BorderRadius.circular(18),
          )
        : null;

    return GestureDetector(
      onTap: (_loading || sendingOverlay != null) ? null : _toggle,
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
              _buildThumbnail(),
              if (controller != null && controller.value.isInitialized)
                FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: controller.value.size.width,
                    height: controller.value.size.height,
                    child: VideoPlayer(controller),
                  ),
                ),
              if (!_playing &&
                  sendingOverlay == null &&
                  receivingOverlay == null &&
                  playTapOverlay == null)
                Center(
                  child: Container(
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
              if (sendingOverlay != null) sendingOverlay,
              if (receivingOverlay != null) receivingOverlay,
              if (playTapOverlay != null) playTapOverlay,
            ],
          ),
        ),
      ),
    );
  }
}
