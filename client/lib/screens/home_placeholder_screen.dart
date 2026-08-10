import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../crypto/key_store.dart';
import '../services/call_service.dart';
import '../services/message_router.dart';
import '../services/websocket_service.dart';
import '../session.dart';
import '../storage/chat_store.dart';
import '../storage/notes_store.dart';
import '../theme/app_theme.dart';
import '../utils/time_format.dart';
import '../widgets/bottom_action_bar.dart';
import 'chat_screen.dart';
import 'incoming_call_screen.dart';
import 'new_chat_screen.dart';
import 'notes_screen.dart';
import 'welcome_screen.dart';

const _notesMarker = '__notes__';

class _NoGlowScrollBehavior extends ScrollBehavior {
  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) {
    return child;
  }
}

class HomePlaceholderScreen extends StatefulWidget {
  const HomePlaceholderScreen({super.key});

  @override
  State<HomePlaceholderScreen> createState() => _HomePlaceholderScreenState();
}

class _HomePlaceholderScreenState extends State<HomePlaceholderScreen> {
  final _webSocketService = WebSocketService.instance;
  List<ChatSummary> _entries = [];

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
    ChatStore.changes.listen((_) => _refreshChats());
    NotesStore.changes.listen((_) => _refreshChats());

    CallService.instance.startListening();
    CallService.instance.incomingCalls.listen((info) async {
      final currentToken = await Session.getToken();
      String peerLogin = 'Неизвестный';
      if (currentToken != null) {
        final owner = await ApiClient().getDeviceOwnerInfo(currentToken, info.peerDeviceId);
        if (owner != null) peerLogin = owner.login;
      }
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => IncomingCallScreen(peerLogin: peerLogin)),
        );
      }
    });

    _webSocketService.sessionInvalidated.listen((_) async {
      await Session.clearToken();
      await KeyStore.clearAll();
      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (context) => const WelcomeScreen()),
          (route) => false,
        );
      }
    });

    await _refreshChats();
  }

  Future<void> _refreshChats() async {
    final chats = await ChatStore.getKnownPeers();
    final notesSummary = await NotesStore.getSummary();

    final combined = <ChatSummary>[
      ChatSummary(_notesMarker, notesSummary.lastMessage, notesSummary.lastTimestamp),
      ...chats,
    ]..sort((a, b) => b.lastTimestamp.compareTo(a.lastTimestamp));

    if (!mounted) return;
    setState(() => _entries = combined);
  }

  @override
  Widget build(BuildContext context) {
    final barHeight = MediaQuery.of(context).size.height / 15;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Чаты'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const NewChatScreen()),
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: ScrollConfiguration(
              behavior: _NoGlowScrollBehavior(),
              child: ListView.builder(
                padding: EdgeInsets.only(bottom: barHeight),
                itemCount: _entries.length,
                itemBuilder: (context, index) {
                  final entry = _entries[index];
                  final isNotes = entry.peerLogin == _notesMarker;

                  return Container(
                    color: entry.unreadCount > 0
                        ? AppColors.primary.withValues(alpha: 0.12)
                        : Colors.transparent,
                    child: ListTile(
                      title: Text(
                        isNotes ? 'Заметки' : (entry.isDeleted ? 'Удалённый аккаунт' : entry.peerLogin),
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: entry.unreadCount > 0 ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      subtitle: Text(
                        entry.lastMessage,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontWeight: entry.unreadCount > 0 ? FontWeight.w600 : FontWeight.normal,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
trailing: Row(
  mainAxisAlignment: MainAxisAlignment.center,
  crossAxisAlignment: CrossAxisAlignment.center,
  mainAxisSize: MainAxisSize.min,
  children: [
    if (entry.unreadCount > 0)
      Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          entry.unreadCount > 9 ? '9+' : '${entry.unreadCount}',
          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
        ),
      ),
    if (entry.lastTimestamp > 0)
      Text(
        formatChatTime(entry.lastTimestamp),
        style: TextStyle(
          color: entry.unreadCount > 0 ? AppColors.primary : AppColors.textMuted,
          fontSize: 12,
          fontWeight: entry.unreadCount > 0 ? FontWeight.bold : FontWeight.normal,
        ),
      ),
  ],
),
                      onTap: () async {
                        if (isNotes) {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(builder: (context) => const NotesScreen()),
                          );
                          return;
                        }

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
                              await ChatStore.setPeerDeletedStatus(login, false);
                            }
                          } on ApiException {
                            await ChatStore.setPeerDeletedStatus(login, true);
                          } catch (_) {}
                        }();

                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ChatScreen(
                              peerDeviceId: deviceIdToUse,
                              peerAccountId: entry.lastKnownAccountId ?? '',
                              peerLogin: login,
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: const BottomActionBar(),
          ),
        ],
      ),
    );
  }
}