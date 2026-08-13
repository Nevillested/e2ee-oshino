import 'dart:async';
import 'package:call_ring_plugin/call_ring_plugin.dart';
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../crypto/key_store.dart';
import '../l10n/app_strings.dart';
import '../services/call_service.dart';
import '../services/message_router.dart';
import '../services/pip_service.dart';
import '../services/push_service.dart';
import '../services/websocket_service.dart';
import '../session.dart';
import '../storage/chat_store.dart';
import '../theme/app_theme.dart';
import '../utils/time_format.dart';
import '../widgets/bottom_action_bar.dart';
import '../widgets/connection_status_indicator.dart';
import '../widgets/swipe_back_page_route.dart';
import '../widgets/theme_reactive.dart';
import 'chat_screen.dart';
import 'incoming_call_screen.dart';
import 'new_chat_screen.dart';
import 'settings_screen.dart';
import 'welcome_screen.dart';

class _NoGlowScrollBehavior extends ScrollBehavior {
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
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

  // Настройки показываются не отдельным route, а "обратной стороной" этого
  // же экрана — панель снизу всегда одна и та же (см. build), меняется
  // только иконка на ней и то, что видно при развороте карточки (см.
  // _buildFlippableBody).
  bool _showSettings = false;

  void _toggleSettings() => setState(() => _showSettings = !_showSettings);

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
    PushService.init();

    CallService.instance.startListening();

    // Приложение могло быть запущено именно кнопкой "Ответить" из
    // уведомления о звонке (см. CallRingService) — тогда ближайший (или
    // уже идущий) входящий звонок нужно принять автоматически.
    if (await PipService.consumeAutoAccept()) {
      CallService.instance.requestAutoAcceptNextCall();
    }

    // Звонок могли отклонить кнопкой в уведомлении, ПОКА приложение было
    // полностью закрыто — тогда его некому было сразу записать в историю
    // чата (см. PendingMissedCallStore.kt). Досписываем при первом же
    // запуске.
    unawaited(_writePendingMissedCallIfAny(token));

    // Автопринятые звонки (кнопка "Ответить" в push-уведомлении) CallService
    // открывает сам, напрямую через глобальный rootNavigatorKey — этот
    // листенер эмитится только для звонков, требующих ручного выбора
    // "принять/отклонить".
    CallService.instance.incomingCalls.listen((info) async {
      final currentToken = await Session.getToken();
      String peerLogin = tr('common.unknown');
      if (currentToken != null) {
        final owner = await ApiClient().getDeviceOwnerInfo(
          currentToken,
          info.peerDeviceId,
        );
        if (owner != null) peerLogin = owner.login;
      }
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => IncomingCallScreen(peerLogin: peerLogin),
        ),
      );
    });

    _webSocketService.sessionInvalidated.listen((_) async {
      await Session.clearToken();
      await KeyStore.clearAll();
      await CallRingPlugin.clearCredentials();
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

  /// См. комментарий у вызова выше — дописывает в историю чата звонок,
  /// который отклонили кнопкой в уведомлении при полностью закрытом
  /// приложении. ChatStore.changes уже слушается в _connect() выше, так
  /// что список чатов обновится сам.
  Future<void> _writePendingMissedCallIfAny(String token) async {
    final pending = await CallRingPlugin.consumePendingMissedCall();
    if (pending == null) return;
    try {
      final owner = await ApiClient().getDeviceOwnerInfo(
        token,
        pending.callerDeviceId,
      );
      if (owner == null) return;
      await ChatStore.addCallLog(
        owner.login,
        direction: 'incoming',
        outcome: 'missed',
        timestamp: pending.timestamp,
        accountId: owner.accountId,
      );
    } catch (_) {
      // Не получилось дописать сейчас — не критично, это всего одна запись
      // в локальной истории, которую мы иначе потеряли бы безвозвратно.
    }
  }

  Future<void> _refreshChats() async {
    final chats = await ChatStore.getKnownPeers();
    // "Заметки" — обычная запись в ChatStore под фиксированным peerLogin
    // (см. notesPeerLogin); пока в неё ни разу не писали, такой записи там
    // ещё нет — подставляем пустую заглушку, чтобы пункт всё равно был
    // виден и открывался (иначе новый пользователь не найдёт его вообще).
    final hasNotes = chats.any((c) => c.peerLogin == notesPeerLogin);
    final combined = <ChatSummary>[
      if (!hasNotes) ChatSummary(notesPeerLogin, '', 0),
      ...chats,
    ]..sort((a, b) => b.lastTimestamp.compareTo(a.lastTimestamp));

    if (!mounted) return;
    setState(() => _entries = combined);
  }

  @override
  Widget build(BuildContext context) {
    return ThemeReactive(builder: (context) => _build(context));
  }

  Widget _build(BuildContext context) {
    final barHeight = MediaQuery.of(context).size.height / 15;

    return PopScope(
      // На "обратной стороне" (настройки) системный back должен сначала
      // развернуть карточку обратно к чатам, а не сразу закрывать
      // приложение — это то же самое действие, что и тап по иконке на
      // нижней панели.
      canPop: !_showSettings,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _toggleSettings();
      },
      child: Scaffold(
        appBar: _showSettings
            ? AppBar(title: Text(tr('settings.title')))
            : AppBar(
                title: const ConnectionStatusIndicator(),
                centerTitle: false,
                actions: [
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const NewChatScreen(),
                        ),
                      );
                    },
                  ),
                ],
              ),
        body: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.only(bottom: barHeight),
                child: _buildFlippableBody(),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: BottomActionBar(
                // Иконка на панели — это иконка ДРУГОЙ, ещё не открытой
                // стороны: находясь в чатах, показываем шестерёнку
                // (открыть настройки), находясь в настройках — иконку
                // чатов (вернуться).
                icon: _showSettings
                    ? Icons.chat_bubble_outline
                    : Icons.settings,
                onTap: _toggleSettings,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// "Fade through color" — заказанная замена прежнему 3D-перевороту:
  /// вместо вращения по Y старое содержимое гаснет ЗА сплошным цветом
  /// (тем же, что и фон экрана — не белым, как в оригинальном примере: тот
  /// был написан под always-light UI, у нас же есть тёмная тема, и белая
  /// вспышка в ней выглядела бы чужеродно), а новое проступает поверх него.
  /// AnimatedSwitcher вызывает transitionBuilder ОТДЕЛЬНО для уходящего и
  /// приходящего виджета (в отличие от PageRouteBuilder в присланном
  /// примере, где "child" — только новая страница, а старая остаётся под
  /// ней сама по себе) — здесь один и тот же приём просто применён к
  /// обеим сторонам разом: у каждой свой цветовой слой гаснет/проступает
  /// синхронно с её же содержимым.
  Widget _buildFlippableBody() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      transitionBuilder: (child, animation) {
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOut);
        return Stack(
          children: [
            FadeTransition(
              opacity: Tween<double>(begin: 1, end: 0).animate(curved),
              child: Container(color: AppColors.background),
            ),
            FadeTransition(
              opacity: Tween<double>(begin: 0, end: 1).animate(curved),
              child: child,
            ),
          ],
        );
      },
      child: KeyedSubtree(
        key: ValueKey(_showSettings),
        child: _showSettings ? const SettingsContent() : _buildChatList(),
      ),
    );
  }

  Widget _buildChatList() {
    return ScrollConfiguration(
      behavior: _NoGlowScrollBehavior(),
      child: ListView.builder(
        itemCount: _entries.length,
        itemBuilder: (context, index) {
          final entry = _entries[index];
          final isNotes = entry.peerLogin == notesPeerLogin;

          return Container(
                    color: entry.unreadCount > 0
                        ? AppColors.primary.withValues(alpha: 0.12)
                        : Colors.transparent,
                    child: ListTile(
                      title: Text(
                        isNotes
                            ? tr('home.notes')
                            : (entry.isDeleted
                                  ? tr('home.deletedAccount')
                                  : entry.peerLogin),
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: entry.unreadCount > 0
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                      subtitle: Text(
                        entry.lastMessage,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontWeight: entry.unreadCount > 0
                              ? FontWeight.w600
                              : FontWeight.normal,
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
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.primary,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                entry.unreadCount > 9
                                    ? '9+'
                                    : '${entry.unreadCount}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          if (entry.lastTimestamp > 0)
                            Text(
                              formatChatTime(entry.lastTimestamp),
                              style: TextStyle(
                                color: entry.unreadCount > 0
                                    ? AppColors.primary
                                    : AppColors.textMuted,
                                fontSize: 12,
                                fontWeight: entry.unreadCount > 0
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                        ],
                      ),
                      onTap: () async {
                        if (isNotes) {
                          final myAccountId =
                              await Session.getAccountId() ?? '';
                          if (!context.mounted) return;
                          await Navigator.push(
                            context,
                            SwipeBackPageRoute(
                              builder: (context) => ChatScreen(
                                peerDeviceId: '',
                                peerAccountId: myAccountId,
                                peerLogin: notesPeerLogin,
                              ),
                            ),
                          );
                          return;
                        }

                        final login = entry.peerLogin;
                        final deviceIdToUse = entry.lastKnownDeviceId ?? '';

                        () async {
                          try {
                            final token = await Session.getToken();
                            final result = await ApiClient().getDevicesByLogin(
                              token!,
                              login,
                            );
                            if (result.devices.isNotEmpty) {
                              await ChatStore.setLastKnownDeviceId(
                                login,
                                result.devices.first['device_id'] as String,
                              );
                              await ChatStore.setPeerDeletedStatus(
                                login,
                                false,
                              );
                            }
                          } on ApiException {
                            await ChatStore.setPeerDeletedStatus(login, true);
                          } catch (_) {}
                        }();

                        await Navigator.push(
                          context,
                          SwipeBackPageRoute(
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
    );
  }
}
