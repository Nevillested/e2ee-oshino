import 'dart:async';
import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import '../screens/call_screen.dart';
import '../services/call_service.dart';

/// Светло-салатовая панель "Вернуться к экрану звонка" — свисает сверху
/// чата, ПОКА идёт разговор именно с этим собеседником (см. CallScreen,
/// который можно свернуть/уйти с него в другой чат, не завершая звонок).
/// Показывает живой таймер длительности и разворачивает CallScreen обратно
/// по нажатию.
class OngoingCallBanner extends StatefulWidget {
  final String peerLogin;
  const OngoingCallBanner({super.key, required this.peerLogin});

  @override
  State<OngoingCallBanner> createState() => _OngoingCallBannerState();
}

class _OngoingCallBannerState extends State<OngoingCallBanner> {
  final _call = CallService.instance;
  StreamSubscription<CallState>? _stateSub;
  Timer? _ticker;

  bool get _isRelevant =>
      _call.state == CallState.connected &&
      _call.currentPeerLogin == widget.peerLogin;

  @override
  void initState() {
    super.initState();
    _stateSub = _call.stateStream.listen((_) {
      if (mounted) setState(_syncTicker);
    });
    _syncTicker();
  }

  void _syncTicker() {
    if (_isRelevant && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!_isRelevant && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
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

  @override
  void dispose() {
    _stateSub?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isRelevant) return const SizedBox.shrink();

    return Material(
      color: const Color(0xFFCCFF90),
      child: InkWell(
        onTap: () {
          if (_call.isCallScreenVisible) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => CallScreen(peerLogin: widget.peerLogin),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.call, color: Colors.black87, size: 18),
              const SizedBox(width: 8),
              Text(
                tr('call.returnToScreen'),
                style: const TextStyle(
                  color: Colors.black87,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _durationText(),
                style: const TextStyle(
                  color: Colors.black87,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
