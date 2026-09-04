import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../l10n/app_strings.dart';
import '../services/debug_log.dart';
import '../services/media_playback_coordinator.dart';
import 'media_status_overlay.dart';
import 'safe_memory_image.dart';

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
  // Дешёвая проверка "файл уже в MediaCache" — вызывается ПЕРЕД
  // resolveFile, чтобы решить, показывать ли оверлей "Downloading" вообще.
  // Без неё повторное воспроизведение уже скачанного видео (см.
  // _startFresh) на долю секунды всегда мигало "Downloading 0%", хотя
  // resolveFile реально ничего не качал — просто отдавал файл из кеша, но
  // _loading уже успевал стать true до того, как это выяснялось (жалоба
  // с устройства). null — считаем, что дешёвой проверки нет, ведём себя
  // как раньше.
  final Future<bool> Function()? isCached;
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
    this.isCached,
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

  // См. _watchForStall — реальный кейс с устройства (OnePlus 13, debug_log
  // пользователя): play() успешно возвращается и на миг даже репортит
  // isPlaying=true, но видео физически не декодируется — позиция навсегда
  // застревает на 0:00. Раньше это только логировалось ("+400ms check
  // moved=false") и молча оставалось висеть — для пользователя выглядело
  // как "видео не воспроизводится вообще". _stallRetryUsed ограничивает
  // автоматическое восстановление ОДНИМ пересозданием контроллера за один
  // пользовательский заход (сбрасывается в _toggle() только когда
  // пользователь САМ заново запускает воспроизведение с нуля, не при
  // внутреннем авто-ретрае — иначе бесконечно зависший декодер зациклил бы
  // пересоздание сам с собой).
  bool _stallRetryUsed = false;
  bool _stallError = false;

  // Периодический снимок состояния КАЖДЫЕ несколько секунд, ПОКА идёт
  // воспроизведение — в отличие от _watchForStall (одна разовая проверка
  // только в момент play()), это ловит зависание/зелёный экран/ошибку,
  // возникшие СРЕДИ уже идущего воспроизведения, а не только на старте.
  // Само по себе ничего не чинит (нет ретрая) — только пишет в лог, чтобы
  // при повторной жалобе было видно, где именно позиция перестала
  // двигаться или когда controller.value.hasError стал true.
  Timer? _diagTicker;
  Duration? _lastDiagPosition;

  void _startDiagTicker(VideoPlayerController controller) {
    _diagTicker?.cancel();
    _lastDiagPosition = controller.value.position;
    _diagTicker = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted || _controller != controller) {
        _diagTicker?.cancel();
        return;
      }
      final pos = controller.value.position;
      final stuck = pos == _lastDiagPosition;
      // Пишем только когда позиция реально перестала двигаться посреди
      // воспроизведения (или появилась ошибка) — штатное проигрывание не шумит.
      if (stuck || controller.value.hasError) {
        DebugLog.log(
          'VideoNote diag-tick messageId=${widget.messageId} stuck=$stuck '
          'isBuffering=${controller.value.isBuffering} '
          '${_stateSnapshot(controller)}',
        );
      }
      _lastDiagPosition = pos;
    });
  }

  void _stopDiagTicker() {
    _diagTicker?.cancel();
    _diagTicker = null;
  }

  @override
  void initState() {
    super.initState();
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
    _stopDiagTicker();
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
        unawaited(_doPause());
      },
      resume: () {
        unawaited(_doResume());
      },
      stop: () {
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
    _stopDiagTicker();
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
    await controller.play();
    if (mounted) setState(() => _playing = true);
    _registerWithCoordinator();
    _watchForStall(controller);
    _startDiagTicker(controller);
  }

  /// Само play() иногда завершается, даже если декодер реально не
  /// возобновил выдачу кадров (частая проблема video_player/ExoPlayer на
  /// Android после seekTo в конец/начало, а по debug_log с OnePlus 13 —
  /// иногда и на самом первом холодном старте) — isPlaying=true сразу после
  /// play() это не доказывает. Проверяем позицию ещё раз спустя паузу: если
  /// она не сдвинулась вообще — воспроизведение не идёт, несмотря на
  /// успешный play(). Раньше это только логировалось и оставалось молча
  /// висеть (жалоба с реального устройства: "видеосообщение не
  /// воспроизводится") — теперь при обнаружении пробуем восстановиться
  /// автоматически (см. _stallRetryUsed), а если и повторная попытка не
  /// помогла — показываем настоящую ошибку вместо тишины.
  void _watchForStall(VideoPlayerController controller) {
    final posAtPlay = controller.value.position;
    unawaited(
      Future.delayed(const Duration(milliseconds: 400), () async {
        if (!mounted || _controller != controller) return;
        final moved = controller.value.position != posAtPlay;
        if (moved) return;
        DebugLog.log(
          'VideoNote stall-check: playback did not advance ${_stateSnapshot(controller)}',
        );
        _stopDiagTicker();
        controller.removeListener(_onTick);
        try {
          await controller.pause();
        } catch (_) {}
        try {
          await controller.dispose();
        } catch (_) {}
        if (!mounted) return;
        if (_stallRetryUsed) {
          DebugLog.log('VideoNote stall-check: retry already used, giving up');
          setState(() {
            _controller = null;
            _playing = false;
            _stallError = true;
          });
          final id = widget.messageId;
          if (widget.coordinator != null && id != null) {
            widget.coordinator!.deactivate(id);
          }
          return;
        }
        _stallRetryUsed = true;
        DebugLog.log('VideoNote stall-check: auto-retrying via cold restart');
        setState(() => _controller = null);
        await _startFresh();
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
    _stopDiagTicker();
    if (controller != null) {
      controller.removeListener(_onTick);
      await controller.pause();
    }
    // _playing=false СРАЗУ (а не одновременно с dispose(), как было раньше)
    // — запускает анимацию сжатия (AnimatedContainer в build()) поверх ещё
    // живого, просто остановленного кадра видео, вместо того чтобы кадр
    // резко подменялся статичным превью В ТОТ ЖЕ момент, что и начало
    // сжатия. Раньше оба действия шли в одном setState — из-за этого по
    // естественному окончанию (см. _onTick — там та же проблема технически
    // есть, но незаметна: последний кадр и так уже почти статичен) сжатие
    // выглядело нормально, а по явному крестику подмена середины
    // проигрывания на превью прямо в момент старта анимации читалась как
    // "анимации нет вообще" (жалоба пользователя). Панель сверху (см.
    // MediaPlaybackCoordinator/_buildMediaControlBar) сворачивается
    // ПАРАЛЛЕЛЬНО той же анимацией — deactivate() сразу следом, а не после
    // задержки ниже.
    if (mounted) setState(() => _playing = false);
    final id = widget.messageId;
    if (widget.coordinator != null && id != null) {
      widget.coordinator!.deactivate(id);
    }
    if (controller != null) {
      // Даём анимации сжатия реально доиграть, прежде чем убрать кадр и
      // подменить его превью — та же длительность, что у AnimatedContainer.
      await Future.delayed(const Duration(milliseconds: 220));
      await controller.dispose();
    }
    if (mounted) setState(() => _controller = null);
  }

  // Временное диагностическое логирование (см. обсуждение с пользователем
  // — тестировщик прислал жалобу "второй тап не воспроизводит повторно",
  // разобрано по присланному debug_log: play() после seekTo(0) на конце
  // видео стабильно репортит isPlaying=true, но позиция навсегда
  // застревает на 0 — известная особенность video_player/ExoPlayer на
  // Android. Оставляем логи как есть — полезны и для будущей диагностики).
  Future<void> _toggle() async {
    final controller = _controller;
    if (controller != null) {
      if (_playing) {
        await _doPause();
      } else {
        await _doResume();
      }
      return;
    }

    // Пользователь сам запускает воспроизведение с нуля (не наш внутренний
    // авто-ретрай — см. _watchForStall) — снимаем и лимит попыток, и
    // предыдущую ошибку, раз это уже новый заход.
    _stallRetryUsed = false;
    if (_stallError) setState(() => _stallError = false);
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
    // Дешёвая предварительная проверка кеша (см. widget.isCached) — если
    // файл уже скачан, resolveFile ниже вернёт его мгновенно, без
    // реальной сетевой загрузки, и оверлей "Downloading" показывать не
    // нужно вообще: раньше _loading становился true безусловно, и на
    // повторном воспроизведении уже скачанного видео на экране каждый раз
    // мелькало "Downloading 0%" (жалоба с устройства).
    final alreadyCached = await widget.isCached?.call() ?? false;
    if (!alreadyCached) {
      setState(() {
        _loading = true;
        _downloadPercent = 0;
      });
    }
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
      if (mounted) setState(() => _playing = true);
      _registerWithCoordinator();
      _watchForStall(newController);
      _startDiagTicker(newController);
    } catch (e) {
      DebugLog.error('VideoNote _startFresh() FAILED error=$e');
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
        // подряд, пока позиция ещё не сброшена предыдущим вызовом — гвард
        // от параллельных pause()+dispose по одному platform-каналу.
        return;
      }
      _handlingEnd = true;
      _stopDiagTicker();
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
      return SafeMemoryImage(
        bytes: _thumbnailBytes!,
        fit: BoxFit.cover,
        brokenBuilder: (context) => Container(color: Colors.black),
      );
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
    // См. _watchForStall — декодер молча застрял (isPlaying=true, позиция
    // навсегда на 0:00), автовосстановление тоже не помогло. Реальный
    // случай с устройства раньше молча висел без единого сигнала
    // пользователю — теперь честно показываем, что не получилось, а не
    // просто статичный кадр-превью без объяснений.
    final stallErrorOverlay =
        sendingOverlay == null &&
            receivingOverlay == null &&
            playTapOverlay == null &&
            _stallError
        ? MediaStatusOverlay(
            statusText: tr('media.playbackFailed'),
            percent: null,
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
                  playTapOverlay == null &&
                  stallErrorOverlay == null)
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
              if (stallErrorOverlay != null) stallErrorOverlay,
            ],
          ),
        ),
      ),
    );
  }
}
