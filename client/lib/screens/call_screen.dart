import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/call_service.dart';
import '../theme/app_theme.dart';

class CallScreen extends StatefulWidget {
  final String peerLogin;
  const CallScreen({super.key, required this.peerLogin});

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

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    if (mounted) setState(() => _renderersReady = true);

    _call.remoteStreamUpdates.listen((stream) {
      _lastRemoteStream = stream;
      _remoteRenderer.srcObject = _call.remoteVideoEnabled ? stream : null;
      if (mounted) setState(() {});
    });

    _call.remoteVideoStateUpdates.listen((_) {
      _remoteRenderer.srcObject = _call.remoteVideoEnabled ? _lastRemoteStream : null;
      if (mounted) setState(() {});
    });

    _call.stateStream.listen((state) {
      if (!mounted) return;
      setState(() {});
      if (state == CallState.idle) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });
  }

  void _syncLocalRenderer() {
    _localRenderer.srcObject = _call.videoEnabled ? _call.localStream : null;
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  String _statusText() {
    switch (_call.state) {
      case CallState.outgoingRinging:
        return 'Вызов...';
      case CallState.connected:
        return 'Соединено';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_renderersReady) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    final showRemoteVideo = _remoteRenderer.srcObject != null && _call.remoteVideoEnabled;
    final screenSize = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: showRemoteVideo
                  ? RTCVideoView(
                      _remoteRenderer,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    )
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircleAvatar(radius: 48, child: Icon(Icons.person, size: 48)),
                          const SizedBox(height: 16),
                          Text(widget.peerLogin, style: const TextStyle(color: Colors.white, fontSize: 22)),
                          const SizedBox(height: 8),
                          Text(_statusText(), style: const TextStyle(color: Colors.white70)),
                        ],
                      ),
                    ),
            ),
            if (_call.state == CallState.connected || _call.state == CallState.outgoingRinging)
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
                          : const Center(
                              child: Padding(
                                padding: EdgeInsets.all(8),
                                child: Text(
                                  'Ваша камера выключена',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.white70, fontSize: 11),
                                ),
                              ),
                            ),
                    ),
                  ),
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
                    icon: _call.videoEnabled ? Icons.videocam : Icons.videocam_off,
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
                    onTap: () async {
                      if (_call.state == CallState.outgoingRinging) {
                        await _call.cancelCall();
                      } else {
                        await _call.endCall();
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controlButton({required IconData icon, required VoidCallback onTap, Color? background}) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(color: background ?? AppColors.surface, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white),
      ),
    );
  }
}