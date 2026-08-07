import 'package:flutter/material.dart';
import '../crypto/key_store.dart';
import '../services/message_router.dart';
import '../services/websocket_service.dart';
import '../session.dart';
import '../storage/chat_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_drawer.dart';
import 'chat_screen.dart';
import 'new_chat_screen.dart';
import '../api/api_client.dart';

class HomePlaceholderScreen extends StatefulWidget {
  const HomePlaceholderScreen({super.key});

  @override
  State<HomePlaceholderScreen> createState() => _HomePlaceholderScreenState();
}

class _HomePlaceholderScreenState extends State<HomePlaceholderScreen> {
  final _webSocketService = WebSocketService.instance;
  List<ChatSummary> _chats = [];

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    final token = await Session.getToken();
    final deviceId = await KeyStore.getStoredDeviceId();
    if (token == null || deviceId == null) return;

    _webSocketService.connect(token, deviceId);
    MessageRouter.start();
    MessageRouter.updates.listen((_) => _refreshChats());
    await _refreshChats();
  }

  Future<void> _refreshChats() async {
    final chats = await ChatStore.getKnownPeers();
    if (!mounted) return;
    setState(() => _chats = chats);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: const Text('Чаты'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const NewChatScreen()),
              );
              _refreshChats();
            },
          ),
        ],
      ),
      body: _chats.isEmpty
          ? const Center(
              child: Text('Нет чатов', style: TextStyle(color: AppColors.textMuted)),
            )
          : ListView.builder(
              itemCount: _chats.length,
              itemBuilder: (context, index) {
                final chat = _chats[index];
                return ListTile(
                  title: Text(
                    chat.peerLogin ?? 'Устройство ${chat.peerAccountId.substring(0, 8)}',
                    style: const TextStyle(color: AppColors.textPrimary),
                  ),
                  subtitle: Text(
                    chat.lastMessage,
                    style: const TextStyle(color: AppColors.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
onTap: () async {
  final login = chat.peerLogin;
  if (login == null) return;

  final token = await Session.getToken();
  final result = await ApiClient().getDevicesByLogin(token!, login);
  if (result.devices.isEmpty) return;
  final freshDeviceId = result.devices.first['device_id'] as String;

  await Navigator.push(
    // ignore: use_build_context_synchronously
    context,
    MaterialPageRoute(
      builder: (context) => ChatScreen(
        peerDeviceId: freshDeviceId,
        peerAccountId: chat.peerAccountId,
        peerLogin: login,
      ),
    ),
  );
  _refreshChats();
},
                );
              },
            ),
    );
  }
}