import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/call_service.dart';

/// То, что реально видит система (и весь остальной телефон вокруг —
/// домашний экран, другие приложения) внутри плавающего окошка настоящего
/// Android Picture-in-Picture. Android просто масштабирует и обрезает под
/// нужное соотношение сторон ТЕКУЩЕЕ содержимое Activity в момент входа в
/// PiP — поэтому, пока идёт PiP, этот виджет рисуется на весь экран
/// (Positioned.fill) поверх всего остального интерфейса приложения: как
/// раз то немногое, что Android и покажет в маленьком окошке.
///
/// Рендерер держим "разогретым" и синхронизированным с потоком собеседника
/// ПОСТОЯННО, а не только пока PiP реально активен — иначе в момент входа
/// в PiP был бы короткий чёрный кадр, пока рендерер только начинает
/// получать кадры.
class SystemPipVideoView extends StatefulWidget {
  const SystemPipVideoView({super.key});

  @override
  State<SystemPipVideoView> createState() => _SystemPipVideoViewState();
}

class _SystemPipVideoViewState extends State<SystemPipVideoView> {
  final _call = CallService.instance;
  final _renderer = RTCVideoRenderer();

  bool _rendererReady = false;
  MediaStream? _lastRemoteStream;

  StreamSubscription<bool>? _pipSub;
  StreamSubscription<MediaStream?>? _streamSub;
  StreamSubscription<bool>? _videoStateSub;

  @override
  void initState() {
    super.initState();
    _renderer.initialize().then((_) {
      if (!mounted) return;
      setState(() => _rendererReady = true);
      _syncRendererSource();
    });

    _pipSub = _call.systemPipUpdates.listen((_) {
      if (mounted) setState(() {});
    });
    _streamSub = _call.remoteStreamUpdates.listen((stream) {
      _lastRemoteStream = stream;
      _syncRendererSource();
    });
    _videoStateSub = _call.remoteVideoStateUpdates.listen((_) {
      _syncRendererSource();
    });
  }

  void _syncRendererSource() {
    if (!_rendererReady) return;
    _renderer.srcObject = _call.remoteVideoEnabled ? _lastRemoteStream : null;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _pipSub?.cancel();
    _streamSub?.cancel();
    _videoStateSub?.cancel();
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_call.isInSystemPip || !_rendererReady) return const SizedBox.shrink();

    final showVideo = _call.remoteVideoEnabled && _renderer.srcObject != null;

    return Positioned.fill(
      // Этот виджет сидит СНАРУЖИ Navigator/Scaffold (в одном Stack прямо в
      // builder у MaterialApp, см. main.dart) — без своего Material текст
      // ниже рисовался бы без DefaultTextStyle из Material-темы, и Flutter
      // в debug-сборке подчёркивал бы его двойной жёлто-чёрной линией
      // именно как индикатор "нет Material-предка". type: transparency —
      // просто даёт стилевой контекст, не рисуя лишний фон поверх Container.
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          color: Colors.black,
          child: showVideo
              ? RTCVideoView(
                  _renderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircleAvatar(
                        radius: 28,
                        child: Icon(Icons.person, size: 28),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _call.currentPeerLogin ?? '',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
