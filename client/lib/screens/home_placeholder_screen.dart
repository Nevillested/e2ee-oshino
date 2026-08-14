import 'dart:async';
import 'dart:typed_data';
import 'package:call_ring_plugin/call_ring_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import '../api/api_client.dart';
import '../crypto/key_store.dart';
import '../crypto/message_envelope.dart';
import '../l10n/app_strings.dart';
import '../services/avatar_cache.dart';
import '../services/call_service.dart';
import '../services/control_message_sender.dart';
import '../services/message_router.dart';
import '../services/pip_service.dart';
import '../services/push_service.dart';
import '../services/websocket_service.dart';
import '../session.dart';
import '../storage/chat_store.dart';
import '../theme/app_theme.dart';
import '../utils/time_format.dart';
import '../widgets/avatar_settings_tile.dart';
import '../widgets/bottom_action_bar.dart';
import '../widgets/chat_list_context_menu.dart';
import '../widgets/connection_status_indicator.dart';
import '../widgets/delete_message_dialog.dart';
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
    unawaited(_syncMutedChats(token));
    unawaited(_syncBlockedContacts(token));

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

  /// Сверяет локальный флаг мьюта каждого чата с сервером — на нём это
  /// единственный источник истины для push-подавления, а локальная копия
  /// нужна лишь для мгновенного отображения иконки/подписи в списке и меню
  /// (см. ChatStore.syncMutedFromServer).
  Future<void> _syncMutedChats(String token) async {
    try {
      final mutedAccountIds = await ApiClient().getMutedChats(token);
      await ChatStore.syncMutedFromServer(mutedAccountIds.toSet());
    } catch (_) {
      // Не удалось — не критично, локальное состояние (если уже было
      // сохранено раньше) остаётся как есть, следующее подключение попробует
      // снова.
    }
  }

  /// Тот же принцип, что и _syncMutedChats — сервер является единственным
  /// источником истины (блокировка реально применяется ИМ, см. проверку в
  /// websocket.go), локальная копия нужна только для мгновенного
  /// отображения заглушки-композера/пункта меню (см. ChatStore.
  /// syncBlockedFromServer).
  Future<void> _syncBlockedContacts(String token) async {
    try {
      final blocked = await ApiClient().getBlockedContacts(token);
      await ChatStore.syncBlockedFromServer(
        blocked.blockedByMe.toSet(),
        blocked.blockingMe.toSet(),
      );
    } catch (_) {
      // Не удалось — не критично, локальное состояние (если уже было
      // сохранено раньше) остаётся как есть, следующее подключение попробует
      // снова.
    }
  }

  Future<void> _openChatMenu(ChatSummary entry, Offset position) async {
    HapticFeedback.mediumImpact();
    final action = await showChatListContextMenu(
      context,
      tapPosition: position,
      isPinned: entry.chatPinnedAt != null,
      isMuted: entry.muted,
      isBlocked: entry.blockedByMe,
    );
    if (action == null || !mounted) return;

    switch (action) {
      case ChatListMenuAction.pin:
        await ChatStore.setChatPinned(entry.peerLogin, true);
        break;
      case ChatListMenuAction.unpin:
        await ChatStore.setChatPinned(entry.peerLogin, false);
        break;
      case ChatListMenuAction.mute:
        await _setMuted(entry, true);
        break;
      case ChatListMenuAction.unmute:
        await _setMuted(entry, false);
        break;
      case ChatListMenuAction.block:
        await _setBlocked(entry, true);
        break;
      case ChatListMenuAction.unblock:
        await _setBlocked(entry, false);
        break;
      case ChatListMenuAction.clearHistory:
        await _clearOrDeleteChat(entry, alsoDeleteChat: false);
        break;
      case ChatListMenuAction.deleteChat:
        await _clearOrDeleteChat(entry, alsoDeleteChat: true);
        break;
    }
  }

  Future<void> _setMuted(ChatSummary entry, bool muted) async {
    await ChatStore.setChatMuted(entry.peerLogin, muted);
    final accountId = entry.lastKnownAccountId;
    if (accountId == null) return;
    try {
      final token = await Session.getToken();
      if (token == null) return;
      if (muted) {
        await ApiClient().muteChat(token, accountId);
      } else {
        await ApiClient().unmuteChat(token, accountId);
      }
    } catch (_) {
      // Локальный флаг уже выставлен — сервер подтянет его при следующем
      // успешном вызове (следующий тап по пункту меню) или следующей
      // _syncMutedChats.
    }
  }

  Future<void> _setBlocked(ChatSummary entry, bool blocked) async {
    await ChatStore.setChatBlockedByMe(entry.peerLogin, blocked);
    final accountId = entry.lastKnownAccountId;
    if (accountId == null) return;
    try {
      final token = await Session.getToken();
      if (token == null) return;
      if (blocked) {
        await ApiClient().blockContact(token, accountId);
      } else {
        await ApiClient().unblockContact(token, accountId);
      }
    } catch (_) {
      // Локальный флаг уже выставлен — сервер подтянет его при следующем
      // успешном вызове или следующей _syncBlockedContacts.
    }
  }

  /// Общая реализация "очистить историю"/"удалить диалог" — отличаются
  /// только тем, остаётся ли сам чат в списке после удаления сообщений
  /// (см. ChatStore.clearHistory vs .removeChat). Диалог с галочкой "у
  /// собеседника тоже" — тот же виджет, что и для удаления сообщений внутри
  /// чата (see delete_message_dialog.dart), с другим заголовком.
  /// Свежий device_id собеседника с сервера — тот же запрос, что делает тап
  /// по чату перед его открытием (см. onTap в _buildChatList), только тут
  /// синхронно, потому что от результата зависит, дойдёт ли control-
  /// сообщение. Возвращает null, только если и живой запрос не удался, и
  /// кэша тоже никогда не было — тогда отправлять действительно некуда.
  Future<String?> _resolveCurrentDeviceId(ChatSummary entry) async {
    try {
      final token = await Session.getToken();
      if (token == null) return entry.lastKnownDeviceId;
      final result = await ApiClient().getDevicesByLogin(
        token,
        entry.peerLogin,
      );
      if (result.devices.isNotEmpty) {
        final freshId = result.devices.first['device_id'] as String;
        await ChatStore.setLastKnownDeviceId(entry.peerLogin, freshId);
        return freshId;
      }
      return entry.lastKnownDeviceId;
    } catch (_) {
      return entry.lastKnownDeviceId;
    }
  }

  Future<void> _clearOrDeleteChat(
    ChatSummary entry, {
    required bool alsoDeleteChat,
  }) async {
    final result = await showDeleteMessagesDialog(
      context,
      peerName: entry.peerLogin,
      title: alsoDeleteChat
          ? tr('chatMenu.deleteChatTitle')
          : tr('chatMenu.clearHistoryTitle'),
      confirmLabel: alsoDeleteChat
          ? tr('chatMenu.deleteChatConfirm')
          : tr('chatMenu.clearHistoryConfirm'),
    );
    if (result == null || !mounted) return;

    if (result.alsoForPeer) {
      final messages = await ChatStore.getMessages(entry.peerLogin);
      final ids = messages.map((m) => m.messageId).toList();
      // Закэшированный entry.lastKnownDeviceId мог устареть (например,
      // собеседник переустановил приложение и получил новый device_id) —
      // ControlMessageSender молча проглатывает любую ошибку отправки
      // (см. его catch), так что письмо на несуществующее устройство просто
      // терялось без следа: у нас всё чистилось, у собеседника — нет. Перед
      // отправкой всегда переспрашиваем сервер за актуальным id, как и при
      // обычном открытии чата (см. onTap в _buildChatList), а на кэш
      // откатываемся только если сам запрос не удался (например, нет сети).
      final deviceId = await _resolveCurrentDeviceId(entry);
      if (deviceId != null && deviceId.isNotEmpty) {
        if (ids.isNotEmpty) {
          await ControlMessageSender.send(
            peerLogin: entry.peerLogin,
            peerDeviceId: deviceId,
            inner: InnerMessage.delete(targetMessageIds: ids),
          );
        }
        // Для "удалить диалог" (в отличие от просто "очистить историю")
        // собеседник должен не просто остаться с пустым чатом, а увидеть,
        // что чат целиком пропал из его списка — см. InnerMessage.deleteChat
        // и обработку 'delete_chat' в message_router.dart на его стороне.
        if (alsoDeleteChat) {
          await ControlMessageSender.send(
            peerLogin: entry.peerLogin,
            peerDeviceId: deviceId,
            inner: InnerMessage.deleteChat(),
          );
        }
      }
    }

    if (alsoDeleteChat) {
      await ChatStore.removeChat(entry.peerLogin);
    } else {
      await ChatStore.clearHistory(entry.peerLogin);
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
    ]..sort(ChatStore.compareForList);

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
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOut,
        );
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

          return GestureDetector(
            onLongPressStart: isNotes
                ? null
                : (details) => _openChatMenu(entry, details.globalPosition),
            child: Container(
              color: entry.unreadCount > 0
                  ? AppColors.primary.withValues(alpha: 0.12)
                  : Colors.transparent,
              child: ListTile(
                leading: _ChatAvatarLeading(
                  isNotes: isNotes,
                  accountId: entry.lastKnownAccountId,
                ),
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
                          entry.unreadCount > 9 ? '9+' : '${entry.unreadCount}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    if (entry.chatPinnedAt != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(
                          Icons.push_pin,
                          size: 13,
                          color: AppColors.textMuted,
                        ),
                      ),
                    if (entry.muted)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(
                          Icons.notifications_off,
                          size: 14,
                          color: AppColors.textMuted,
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
                    final myAccountId = await Session.getAccountId() ?? '';
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
                        await ChatStore.setPeerDeletedStatus(login, false);
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
            ),
          );
        },
      ),
    );
  }
}

/// Миниатюрка фото профиля собеседника рядом с логином в списке чатов —
/// для "Заметок" всегда своё фото (лежит под своим же account_id, а не
/// lastKnownAccountId — та запись для заметок не всегда успевает
/// проставиться), для остальных чатов — фото того, с кем переписка.
/// bytes == null (нет фото/не удалось скачать) — заглушка (см.
/// AvatarThumbnail), не ошибка, показывать нечего гонять лишний раз.
class _ChatAvatarLeading extends StatelessWidget {
  final bool isNotes;
  final String? accountId;

  const _ChatAvatarLeading({required this.isNotes, required this.accountId});

  Future<Uint8List?> _resolve() async {
    final id = isNotes ? await Session.getAccountId() : accountId;
    if (id == null || id.isEmpty) return null;
    return AvatarCache.get(id);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _resolve(),
      builder: (context, snapshot) {
        return AvatarThumbnail(bytes: snapshot.data);
      },
    );
  }
}
