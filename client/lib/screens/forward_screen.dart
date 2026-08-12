import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../session.dart';
import '../storage/chat_store.dart';
import '../theme/app_theme.dart';
import '../widgets/swipe_back_page_route.dart';
import 'chat_screen.dart';

/// Список чатов пользователя для пересылки — выбор одного открывает этот
/// чат с уже прикреплённой панелькой "Количество пересылаемых сообщений".
/// Пересылаются ТОЛЬКО тексты сообщений (см. ChatScreen._sendForwarded) —
/// без ссылки на исходного отправителя и без вложений, это сознательное
/// упрощение по сравнению с Telegram: полноценная пересылка упёрлась бы в
/// то, что исходное сообщение зашифровано ключом, доступным только
/// исходной паре собеседников.
class ForwardScreen extends StatefulWidget {
  final List<String> messageTexts;
  const ForwardScreen({super.key, required this.messageTexts});

  @override
  State<ForwardScreen> createState() => _ForwardScreenState();
}

class _ForwardScreenState extends State<ForwardScreen> {
  List<ChatSummary> _peers = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final peers = await ChatStore.getKnownPeers();
    if (!mounted) return;
    setState(() {
      _peers = peers;
      _loading = false;
    });
  }

  Future<void> _openChat(ChatSummary entry) async {
    final login = entry.peerLogin;
    final deviceIdToUse = entry.lastKnownDeviceId ?? '';

    () async {
      try {
        final token = await Session.getToken();
        final result = await ApiClient().getDevicesByLogin(token!, login);
        if (result.devices.isNotEmpty) {
          await ChatStore.setLastKnownDeviceId(
            login,
            result.devices.first['device_id'] as String,
          );
        }
      } catch (_) {}
    }();

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      SwipeBackPageRoute(
        builder: (context) => ChatScreen(
          peerDeviceId: deviceIdToUse,
          peerAccountId: entry.lastKnownAccountId ?? '',
          peerLogin: login,
          forwardedTexts: widget.messageTexts,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Переслать')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _peers.length,
              itemBuilder: (context, index) {
                final entry = _peers[index];
                return ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person)),
                  title: Text(
                    entry.isDeleted ? 'Удалённый аккаунт' : entry.peerLogin,
                    style: const TextStyle(color: AppColors.textPrimary),
                  ),
                  subtitle: Text(
                    entry.lastMessage,
                    style: const TextStyle(color: AppColors.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => _openChat(entry),
                );
              },
            ),
    );
  }
}
