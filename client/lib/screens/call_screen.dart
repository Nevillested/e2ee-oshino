import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../l10n/app_strings.dart';
import '../services/avatar_cache.dart';
import '../services/call_service.dart';
import '../services/pip_service.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_settings_tile.dart';
import '../widgets/theme_reactive.dart';

class CallScreen extends StatefulWidget {
  final String peerLogin;
  final String peerAccountId;
  const CallScreen({
    super.key,
    required this.peerLogin,
    required this.peerAccountId,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  final _call = CallService.instance;

  bool _renderersReady = false;
  MediaStream? _lastRemoteStream;

  Offset _selfViewOffset = const Offset(16, 60);
  Future<Uint8List?>? _peerAvatarFuture;

  Timer? _durationTicker;
  StreamSubscription<String>? _statusSub;
  StreamSubscription<MediaStream?>? _remoteStreamSub;
  StreamSubscription<bool>? _remoteVideoStateSub;
  StreamSubscription<CallState>? _stateSub;

  @override
  void initState() {
    super.initState();
    debugPrint(
      'CallScreen: initState (peerLogin=${widget.peerLogin}, state=${_call.state})',
    );
    // Логин собеседника и "экран разговора сейчас виден" нужны отдельно от
    // самого CallState — уведомление и системный PiP ориентируются именно
    // на них, чтобы показать/спрятать себя при уходе на другой экран
    // приложения, пока звонок продолжается в фоне.
    _call.currentPeerLogin = widget.peerLogin;
    _call.currentPeerAccountId = widget.peerAccountId;
    _peerAvatarFuture = widget.peerAccountId.isEmpty
        ? null
        : AvatarCache.get(widget.peerAccountId);
    _call.setCallScreenVisible(true);
    _init();
    _statusSub = _call.statusUpdates.listen((_) {
      if (mounted) setState(() {});
    });
  }

  void _syncDurationTicker() {
    final shouldTick = _call.state == CallState.connected;
    if (shouldTick && _durationTicker == null) {
      _durationTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!shouldTick && _durationTicker != null) {
      _durationTicker?.cancel();
      _durationTicker = null;
    }
  }

  String _durationText() {
    final connectedAt = _call.connectedAt;
    if (connectedAt == null) return '';
    final seconds = DateTime.now().difference(connectedAt).inSeconds;
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }

  Future<void> _init() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    if (mounted) setState(() => _renderersReady = true);

    // Поток собеседника мог прийти ЗАДОЛГО до того, как именно этот
    // экземпляр CallScreen появился (например: экран уже сворачивали в PiP
    // и разворачивают заново) — remoteStreamUpdates подписчикам "задним
    // числом" ничего не пришлёт, поэтому сначала подхватываем уже
    // ТЕКУЩЕЕ значение напрямую, а стримом ниже реагируем только на
    // дальнейшие изменения.
    _lastRemoteStream = _call.remoteStream;
    _remoteRenderer.srcObject = _call.remoteVideoEnabled
        ? _lastRemoteStream
        : null;
    debugPrint(
      'CallScreen: _init: подхватил текущий remoteStream=${_call.remoteStream}, '
      'remoteVideoEnabled=${_call.remoteVideoEnabled}',
    );

    _remoteStreamSub = _call.remoteStreamUpdates.listen((stream) {
      _lastRemoteStream = stream;
      _remoteRenderer.srcObject = _call.remoteVideoEnabled ? stream : null;
      if (mounted) setState(() {});
    });

    _remoteVideoStateSub = _call.remoteVideoStateUpdates.listen((_) {
      _remoteRenderer.srcObject = _call.remoteVideoEnabled
          ? _lastRemoteStream
          : null;
      if (mounted) setState(() {});
    });

    _stateSub = _call.stateStream.listen((state) {
      debugPrint('CallScreen: stateStream -> $state (mounted=$mounted)');
      if (!mounted) return;
      _syncDurationTicker();
      setState(() {});
      if (state == CallState.idle) {
        // Уведомление гасит сам CallService (_setState) — оно должно
        // исчезнуть, даже если этот экран уже не смонтирован (пользователь
        // ушёл в другой чат, пока звонок продолжался). Здесь остаётся
        // только закрыть сам экран, если он всё ещё на виду.
        debugPrint('CallScreen: state=idle -> popUntil(isFirst)');
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });
    _syncDurationTicker();
  }

  void _syncLocalRenderer() {
    _localRenderer.srcObject = _call.videoEnabled ? _call.localStream : null;
  }

  /// Общая логика завершения звонка — используется красной кнопкой.
  /// Системный back-жест больше НЕ вешает трубку (см. build()): уходя с
  /// этого экрана, пользователь просто возвращается туда, где был, а
  /// звонок продолжается в фоне (CallService не привязан к жизни этого
  /// экрана) — ровно то же самое поведение, что и при сворачивании всего
  /// приложения.
  Future<void> _hangUp() async {
    debugPrint('CallScreen: красная кнопка нажата, state=${_call.state}');
    if (_call.state == CallState.outgoingRinging) {
      await _call.cancelCall();
    } else {
      await _call.endCall();
    }
  }

  @override
  void dispose() {
    debugPrint('CallScreen: dispose');
    // Уведомление НЕ трогаем здесь — оно привязано к самому звонку
    // (CallService), а не к тому, смотрит ли пользователь именно на этот
    // экран прямо сейчас: звонок может продолжаться и после ухода отсюда
    // (в т.ч. в системном PiP).
    _call.setCallScreenVisible(false);
    _durationTicker?.cancel();
    _statusSub?.cancel();
    _remoteStreamSub?.cancel();
    _remoteVideoStateSub?.cancel();
    _stateSub?.cancel();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  String _statusText() {
    if (_call.state == CallState.connected) return _durationText();
    // Пока соединение ещё не установлено (дозвон, автопринятие звонка из
    // уведомления, обмен SDP/ICE-кандидатами WebRTC) — живой статус из
    // CallService, чтобы не выглядело, будто приложение просто зависло.
    return _call.status.isNotEmpty ? _call.status : tr('call.dialing');
  }

  @override
  Widget build(BuildContext context) {
    return ThemeReactive(builder: (context) => _build(context));
  }

  Widget _build(BuildContext context) {
    if (!_renderersReady) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.textPrimary),
        ),
      );
    }

    final showRemoteVideo =
        _remoteRenderer.srcObject != null && _call.remoteVideoEnabled;
    final screenSize = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: showRemoteVideo
                  ? RTCVideoView(
                      _remoteRenderer,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    )
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FutureBuilder<Uint8List?>(
                            future: _peerAvatarFuture,
                            builder: (context, snapshot) => AvatarThumbnail(
                              bytes: snapshot.data,
                              radius: 48,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            widget.peerLogin,
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 22,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _statusText(),
                            style: TextStyle(color: AppColors.textMuted),
                          ),
                        ],
                      ),
                    ),
            ),
            // Когда собеседник с видео закрывает собой весь экран, имя и
            // длительность (а во время дозвона иначе их вообще негде было
            // бы увидеть) выводим отдельной плашкой сверху.
            if (showRemoteVideo)
              Positioned(
                top: 12,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.peerLogin,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                        if (_statusText().isNotEmpty)
                          Text(
                            _statusText(),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_call.state == CallState.connected ||
                _call.state == CallState.outgoingRinging)
              Positioned(
                left: _selfViewOffset.dx.clamp(0, screenSize.width - 100),
                top: _selfViewOffset.dy.clamp(0, screenSize.height - 140),
                child: GestureDetector(
                  onPanUpdate: (details) {
                    setState(() {
                      _selfViewOffset += details.delta;
                    });
                  },
                  child: Container(
                    width: 100,
                    height: 140,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: _call.videoEnabled
                          ? RTCVideoView(_localRenderer, mirror: true)
                          : Center(
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(
                                  tr('call.cameraOff'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            // Ручной вход в настоящий системный PiP — как у Telegram: две
            // стрелки, направленные друг на друга. Сам переход на предыдущий
            // экран (и последующее возвращение сюда при разворачивании PiP)
            // делает CallService, реагируя на колбэк с нативной стороны, а
            // не эта кнопка напрямую — см. CallService._handlePipModeChange.
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: Icon(Icons.close_fullscreen, color: AppColors.textPrimary),
                iconSize: 20,
                onPressed: () => PipService.enterPipNow(),
              ),
            ),
            Positioned(
              bottom: 32,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _controlButton(
                    icon: _call.micEnabled ? Icons.mic : Icons.mic_off,
                    onTap: () async {
                      await _call.toggleMic();
                      if (mounted) setState(() {});
                    },
                  ),
                  _controlButton(
                    icon: _call.videoEnabled
                        ? Icons.videocam
                        : Icons.videocam_off,
                    onTap: () async {
                      await _call.toggleVideo();
                      _syncLocalRenderer();
                      if (mounted) setState(() {});
                    },
                  ),
                  _controlButton(
                    icon: _call.speakerOn ? Icons.volume_up : Icons.hearing,
                    onTap: () async {
                      await _call.toggleSpeaker();
                      if (mounted) setState(() {});
                    },
                  ),
                  _controlButton(
                    icon: Icons.call_end,
                    background: Colors.red,
                    onTap: _hangUp,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controlButton({
    required IconData icon,
    required VoidCallback onTap,
    Color? background,
  }) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: background ?? AppColors.surface,
          shape: BoxShape.circle,
        ),
        // На красной кнопке (завершить звонок) фон всегда фиксированный —
        // белая иконка корректна в обеих темах. На остальных фон теперь
        // AppColors.surface (белый в светлой теме) — там нужен цвет текста
        // самой темы, иначе снова белым по белому.
        child: Icon(icon, color: background != null ? Colors.white : AppColors.textPrimary),
      ),
    );
  }
}
