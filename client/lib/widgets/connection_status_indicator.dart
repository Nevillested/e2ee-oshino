import 'dart:async';
import 'package:flutter/material.dart';
import '../services/websocket_service.dart';
import '../theme/app_theme.dart';

/// Текстовый статус подключения к серверу — в шапке списка чатов, чтобы
/// всегда было понятно, что сейчас происходит со связью, а не просто
/// "тихо не работает". Показывает только то, что реально умеет отличить
/// сам WebSocketService (см. ConnectionStatus) — без выдуманных фаз вроде
/// отдельного DNS-резолва, которые Dart не даёт поймать отдельно.
class ConnectionStatusIndicator extends StatefulWidget {
  const ConnectionStatusIndicator({super.key});

  @override
  State<ConnectionStatusIndicator> createState() => _ConnectionStatusIndicatorState();
}

class _ConnectionStatusIndicatorState extends State<ConnectionStatusIndicator> {
  StreamSubscription<ConnectionStatus>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = WebSocketService.instance.statusUpdates.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  String _text(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.waitingForNetwork:
        return 'Ожидание интернета…';
      case ConnectionStatus.connecting:
        return 'Подключение к серверу…';
      case ConnectionStatus.connected:
        return 'Подключено';
      case ConnectionStatus.reconnecting:
        return 'Переподключение…';
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = WebSocketService.instance.status;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        _text(status),
        style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
      ),
    );
  }
}
