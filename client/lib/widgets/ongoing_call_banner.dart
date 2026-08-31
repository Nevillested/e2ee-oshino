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
///
/// peerLogin == null — режим "любой активный звонок" (см. ТЗ пользователя:
/// та же полоска в шапке общего списка чатов, а не внутри конкретного
/// чата) — тогда собеседник неважен, актуальность определяется только
/// самим фактом идущего разговора, а не тем, с кем именно он идёт.
class OngoingCallBanner extends StatefulWidget {
  final String? peerLogin;
  const OngoingCallBanner({super.key, this.peerLogin});

  @override
  State<OngoingCallBanner> createState() => _OngoingCallBannerState();
}

class _OngoingCallBannerState extends State<OngoingCallBanner> {
  final _call = CallService.instance;
  StreamSubscription<CallState>? _stateSub;
  StreamSubscription<String>? _statusSub;
  Timer? _ticker;

  // Раньше проверялось только CallState.connected — банер не появлялся,
  // пока идут гудки (собеседник ещё не ответил), и вернуться к экрану
  // звонка из чата было никак. Теперь актуален весь "живой" диапазон
  // состояний звонка с этим собеседником, не только уже соединённый.
  bool get _isRelevant =>
      (_call.state == CallState.outgoingRinging ||
          _call.state == CallState.incomingRinging ||
          _call.state == CallState.connected) &&
      (widget.peerLogin == null || _call.currentPeerLogin == widget.peerLogin);

  @override
  void initState() {
    super.initState();
    _stateSub = _call.stateStream.listen((_) {
      if (mounted) setState(_syncTicker);
    });
    _statusSub = _call.statusUpdates.listen((_) {
      if (mounted) setState(() {});
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

  // Пока звонок ещё не соединился — таймера длительности честно ещё нет,
  // вместо него та же строка статуса, что показывает сам CallScreen
  // (call.dialing/call.ringing/… — единая точка истины в CallService).
  String _durationOrStatusText() {
    final connectedAt = _call.connectedAt;
    if (connectedAt == null) return _call.status;
    final seconds = DateTime.now().difference(connectedAt).inSeconds;
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _statusSub?.cancel();
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
              builder: (_) => CallScreen(
                peerLogin: widget.peerLogin ?? _call.currentPeerLogin ?? '',
                peerAccountId: _call.currentPeerAccountId ?? '',
              ),
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
                _durationOrStatusText(),
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
