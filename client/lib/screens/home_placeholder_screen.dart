import 'dart:async';
import 'dart:typed_data';
import 'package:animations/animations.dart';
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
import '../services/local_notifications.dart';
import '../services/message_router.dart';
import '../services/my_avatar_store.dart';
import '../services/my_email_store.dart';
import '../services/my_profile_store.dart';
import '../services/peer_profile_cache.dart';
import '../services/pip_service.dart';
import '../services/send_queue_processor.dart';
import '../services/push_service.dart';
import '../services/websocket_service.dart';
import '../session.dart';
import '../storage/chat_store.dart';
import '../storage/peer_account_store.dart';
import '../theme/app_theme.dart';
import '../utils/time_format.dart';
import '../widgets/avatar_settings_tile.dart';
import '../widgets/bottom_action_bar.dart';
import '../widgets/cached_avatar_image.dart';
import '../widgets/chat_list_context_menu.dart';
import '../widgets/connection_status_indicator.dart';
import '../widgets/delete_message_dialog.dart';
import '../widgets/peer_name_text.dart';
import '../widgets/swipe_back_page_route.dart';
import '../widgets/theme_reactive.dart';
import 'chat_screen.dart';
import 'incoming_call_screen.dart';
import 'my_profile_screen.dart';
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

class _HomePlaceholderScreenState extends State<HomePlaceholderScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final _webSocketService = WebSocketService.instance;
  List<ChatSummary> _entries = [];

  // Чаты/настройки/профиль — три "стороны" одного и того же экрана, не
  // отдельные route (панель снизу всегда одна и та же, см. build), между
  // ними переключает нижний таб-бар (см. _buildFlippableBody).
  // 0=чаты, 1=настройки, 2=профиль.
  int _selectedTab = 0;
  // Направление Shared Axis перехода фиксируется в момент переключения
  // таба (а не на каждый build — иначе не отличить "снова открыли тот
  // же таб" от "перешли из другого") — true, если новый таб левее
  // текущего в панели.
  bool _transitionReverse = false;

  void _selectTab(int index) {
    if (index == _selectedTab) return;
    // Ушли с вкладки чатов (единственной, где вообще виден поиск) — форма
    // поиска должна закрыться сама, а не остаться висеть развёрнутой до
    // следующего возврата на чаты (см. ТЗ пользователя).
    if (_searchActive) _closeSearch();
    setState(() {
      _transitionReverse = index < _selectedTab;
      _selectedTab = index;
    });
  }

  // Свайп по кругу между вкладками (см. ТЗ пользователя): направление
  // определяется самим жестом, а не разницей индексов — иначе, например,
  // свайп-переход с чатов (0) на профиль (2) "в обход" настроек посчитал
  // бы себя движением вперёд, хотя по кругу это шаг назад.
  static const _tabCount = 3;

  void _swipeToNextTab() {
    if (_searchActive) _closeSearch();
    setState(() {
      _transitionReverse = false;
      _selectedTab = (_selectedTab + 1) % _tabCount;
    });
  }

  void _swipeToPrevTab() {
    if (_searchActive) _closeSearch();
    setState(() {
      _transitionReverse = true;
      _selectedTab = (_selectedTab - 1 + _tabCount) % _tabCount;
    });
  }

  // Стартовая точка текущего горизонтального жеста — null, если жест
  // начался слишком близко к краю экрана (там должен сработать системный
  // свайп-назад, а не переключение таба) либо ещё не набрал порог.
  double? _swipeStartDx;
  double _swipeAccumDx = 0;

  static const _swipeEdgeMargin = 24.0;
  static const _swipeThreshold = 60.0;

  void _onHorizontalDragStart(DragStartDetails details) {
    final width = MediaQuery.of(context).size.width;
    final dx = details.globalPosition.dx;
    if (dx < _swipeEdgeMargin || dx > width - _swipeEdgeMargin) {
      _swipeStartDx = null;
      return;
    }
    _swipeStartDx = dx;
    _swipeAccumDx = 0;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_swipeStartDx == null) return;
    _swipeAccumDx += details.delta.dx;
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_swipeStartDx == null) return;
    if (_swipeAccumDx <= -_swipeThreshold) {
      _swipeToNextTab();
    } else if (_swipeAccumDx >= _swipeThreshold) {
      _swipeToPrevTab();
    }
    _swipeStartDx = null;
    _swipeAccumDx = 0;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connect();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchDebounce?.cancel();
    _searchAnimController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  // Поиск пользователя прямо в шапке списка чатов (см. ТЗ пользователя —
  // отдельный экран NewChatScreen больше не нужен): лупа в actions
  // разворачивается в поле поиска, растущее СПРАВА НАЛЕВО поверх
  // ConnectionStatusIndicator (см. _buildAppBarTitle), результат — плашка
  // под шапкой (см. _buildSearchResultsPanel).
  bool _searchActive = false;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  late final AnimationController _searchAnimController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  Timer? _searchDebounce;
  bool _searchLoading = false;
  bool _searchFoundIsSelf = false;
  String? _searchFoundLogin;
  // Отображаемое имя найденного пользователя (см. ТЗ пользователя) —
  // приходит ОДНИМ ответом вместе с остальным (см. _runSearch,
  // ApiClient.getAccountProfile), а не отдельным асинхронным запросом
  // следом — раньше строка сперва показывала login, а через мгновение
  // резко "прыгала" на отображаемое имя (жалоба пользователя), потому что
  // оно резолвилось отдельно (PeerNameText) уже ПОСЛЕ первой отрисовки.
  String? _searchFoundDisplayName;
  String? _searchFoundAccountId;
  String? _searchFoundDeviceId;
  String? _searchNotFoundMessage;

  void _openSearch() {
    setState(() => _searchActive = true);
    unawaited(_searchAnimController.forward());
    // На следующий кадр — сам разворот пилюли уже пошёл, поле точно
    // смонтировано и готово принять фокус (запрос фокуса ДО первого build
    // с _searchActive=true иногда молча теряется).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searchActive) _searchFocusNode.requestFocus();
    });
  }

  void _closeSearch() {
    _searchDebounce?.cancel();
    _searchFocusNode.unfocus();
    unawaited(_searchAnimController.reverse());
    setState(() {
      _searchActive = false;
      _searchController.clear();
      _searchLoading = false;
      _searchFoundIsSelf = false;
      _searchFoundLogin = null;
      _searchFoundDisplayName = null;
      _searchFoundAccountId = null;
      _searchFoundDeviceId = null;
      _searchNotFoundMessage = null;
    });
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      setState(() {
        _searchLoading = false;
        _searchFoundIsSelf = false;
        _searchFoundLogin = null;
        _searchFoundDisplayName = null;
        _searchFoundAccountId = null;
        _searchFoundDeviceId = null;
        _searchNotFoundMessage = null;
      });
      return;
    }
    setState(() => _searchLoading = true);
    // Дебаунс — не бьём в сеть на каждое нажатие клавиши, а только когда
    // пользователь на миг остановился печатать.
    _searchDebounce = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(_runSearch(query)),
    );
  }

  Future<void> _runSearch(String query) async {
    final myLogin = await Session.getLogin();
    if (!mounted || _searchController.text.trim() != query) return;

    if (myLogin != null && query == myLogin) {
      setState(() {
        _searchLoading = false;
        _searchFoundIsSelf = true;
        _searchFoundLogin = myLogin;
        _searchFoundDisplayName = null;
        _searchFoundAccountId = null;
        _searchFoundDeviceId = null;
        _searchNotFoundMessage = null;
      });
      return;
    }

    try {
      final token = await Session.getToken();
      // getAccountProfile вместо прежнего getDevicesByLogin — тем же одним
      // ответом сразу приходит и список устройств, и отображаемое имя (см.
      // ТЗ пользователя): раньше имя резолвилось ОТДЕЛЬНЫМ асинхронным
      // запросом уже ПОСЛЕ первой отрисовки строки результата (через
      // PeerNameText) — из-за этого строка сперва показывала login и
      // через мгновение резко "прыгала" на имя. Теперь всё приходит и
      // отображается одним куском, скачка нет.
      final result = await ApiClient().getAccountProfile(token!, query);
      if (!mounted || _searchController.text.trim() != query) return;
      if (result == null) {
        setState(() {
          _searchLoading = false;
          _searchFoundIsSelf = false;
          _searchFoundLogin = null;
          _searchFoundDisplayName = null;
          _searchFoundAccountId = null;
          _searchFoundDeviceId = null;
          _searchNotFoundMessage = tr('error.userNotFound');
        });
        return;
      }
      final deviceId = result.devices.isNotEmpty
          ? (result.devices.first['device_id'] ??
                    result.devices.first['deviceId'])
                ?.toString()
          : null;
      if (deviceId != null && deviceId.isNotEmpty) {
        await PeerAccountStore.save(deviceId, result.accountId);
      }
      if (!mounted) return;
      setState(() {
        _searchLoading = false;
        _searchFoundIsSelf = false;
        _searchFoundLogin = query;
        // displayName у getAccountProfile уже с фолбэком на login на
        // сервере (см. account_profile.go) — сравниваем, чтобы понять,
        // есть ли у пользователя РЕАЛЬНОЕ кастомное имя (тогда покажем
        // его основным, а login — мельче под ним) или нет (тогда просто
        // login, без второй строки).
        _searchFoundDisplayName = result.displayName != result.login
            ? result.displayName
            : null;
        _searchFoundAccountId = result.accountId;
        _searchFoundDeviceId = deviceId;
        _searchNotFoundMessage = null;
      });
    } catch (e) {
      if (!mounted || _searchController.text.trim() != query) return;
      setState(() {
        _searchLoading = false;
        _searchFoundIsSelf = false;
        _searchFoundLogin = null;
        _searchFoundDisplayName = null;
        _searchFoundAccountId = null;
        _searchFoundDeviceId = null;
        _searchNotFoundMessage = e.toString();
      });
    }
  }

  Future<void> _openSearchResult() async {
    if (_searchFoundIsSelf) {
      final myAccountId = await Session.getAccountId() ?? '';
      if (!mounted) return;
      _closeSearch();
      Navigator.push(
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
    final login = _searchFoundLogin;
    final accountId = _searchFoundAccountId;
    if (login == null || accountId == null) return;
    final deviceId = _searchFoundDeviceId ?? '';
    _closeSearch();
    Navigator.push(
      context,
      SwipeBackPageRoute(
        builder: (context) => ChatScreen(
          peerDeviceId: deviceId,
          peerAccountId: accountId,
          peerLogin: login,
        ),
      ),
    );
  }

  /// Заголовок шапки чатов — обычно просто ConnectionStatusIndicator, а во
  /// время поиска сверху вырастает пилюля поля ввода: растёт она СПРАВА
  /// (от места, где сидит лупа в actions) НАЛЕВО, поверх статуса — Align с
  /// анимированным widthFactor и ClipRect режут по живому края фиксированной
  /// по ширине (= вся доступная ширина заголовка) SizedBox с полем, поэтому
  /// сам TextField ни разу не меняет собственные constraints/раскладку за
  /// время анимации, дёргается только видимая "открытая" часть.
  Widget _buildAppBarTitle() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        return AnimatedBuilder(
          animation: _searchAnimController,
          builder: (context, _) {
            final t = Curves.easeOut.transform(_searchAnimController.value);
            return Stack(
              alignment: Alignment.centerLeft,
              clipBehavior: Clip.none,
              children: [
                if (t < 1)
                  Opacity(
                    opacity: (1 - t).clamp(0.0, 1.0),
                    child: const ConnectionStatusIndicator(),
                  ),
                if (t > 0)
                  ClipRect(
                    child: Align(
                      alignment: Alignment.centerRight,
                      widthFactor: t,
                      child: SizedBox(
                        width: maxWidth > 0 ? maxWidth : null,
                        child: _buildSearchField(),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSearchField() {
    // isCollapsed (прошлая версия) на практике так и оставлял текст/хинт
    // прижатыми к верху поля даже с textAlignVertical.center — судя по
    // всему, конфликтует с тем, как InputDecorator в collapsed-режиме
    // резервирует вертикальное место. Тут — надёжная, многократно
    // проверенная связка: Row с ручными боковыми отступами вместо padding
    // у самого TextField, isDense+contentPadding:zero вместо isCollapsed —
    // вертикальное центрирование делает Row (у него по умолчанию
    // crossAxisAlignment.center), а не InputDecorator.
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(19),
      ),
      child: Row(
        children: [
          const SizedBox(width: 14),
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              textAlignVertical: TextAlignVertical.center,
              style: TextStyle(color: AppColors.textPrimary, fontSize: 15),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                hintText: tr('newChat.loginHint'),
                hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 15),
              ),
            ),
          ),
          const SizedBox(width: 14),
        ],
      ),
    );
  }

  /// Плашка результата поиска — сразу под шапкой, поверх списка чатов;
  /// пусто, пока поле поиска пустое ИЛИ поиск ещё не активен.
  Widget _buildSearchResultsPanel() {
    if (!_searchActive) return const SizedBox.shrink();
    final query = _searchController.text.trim();
    if (query.isEmpty) return const SizedBox.shrink();

    Widget content;
    if (_searchLoading) {
      content = const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    } else if (_searchFoundLogin != null) {
      content = Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          leading: _searchFoundIsSelf
              ? ValueListenableBuilder<Uint8List?>(
                  valueListenable: MyAvatarStore.notifier,
                  builder: (context, bytes, _) =>
                      AvatarThumbnail(bytes: bytes, radius: 20),
                )
              : CachedAvatarImage(
                  accountId: _searchFoundAccountId!,
                  radius: 20,
                ),
          title: Text(
            _searchFoundIsSelf
                ? tr('home.notes')
                : (_searchFoundDisplayName ?? _searchFoundLogin!),
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          // Логин — второй строкой, мельче, ТОЛЬКО когда у пользователя
          // есть настоящее отображаемое имя (тогда оно ушло в title выше,
          // а login один остаться не может — иначе логина не видно вообще
          // нигде). Если отображаемого имени нет, login и так уже в title,
          // вторая строка не нужна (см. ТЗ пользователя).
          subtitle: _searchFoundDisplayName != null
              ? Text(
                  _searchFoundLogin!,
                  style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                )
              : null,
          onTap: () => unawaited(_openSearchResult()),
        ),
      );
    } else if (_searchNotFoundMessage != null) {
      content = Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        child: Text(
          _searchNotFoundMessage!,
          style: TextStyle(color: AppColors.textMuted),
        ),
      );
    } else {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: content,
    );
  }

  // Раньше пуш "У вас новое сообщение" так и висел в шторке уведомлений
  // даже после того, как пользователь открыл приложение и увидел
  // сообщение своими глазами — нигде в клиенте не было ни одного
  // WidgetsBindingObserver, чтобы вообще заметить возврат в foreground.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      localNotifications.cancelAll();
    }
  }

  Future<void> _connect() async {
    final token = await Session.getToken();
    final deviceId = await KeyStore.getStoredDeviceId();
    if (token == null || deviceId == null) return;

    _webSocketService.connect(token, deviceId);
    MessageRouter.start();
    SendQueueProcessor.instance.start();
    ChatStore.changes.listen((_) => _refreshChats());
    // Разово чинит галочки прочтения для чатов, заведённых ДО появления
    // этой фичи (см. ChatStore.backfillLastMessageMeta) — сама допишет в
    // хранилище и вызовет ChatStore.changes, если что-то реально
    // пересчиталось, список выше сам перерисуется.
    unawaited(ChatStore.backfillLastMessageMeta());
    PushService.init();
    unawaited(_syncMutedChats(token));
    unawaited(_syncBlockedContacts(token));
    unawaited(MyAvatarStore.init());
    unawaited(MyEmailStore.init());
    unawaited(MyProfileStore.init());
    // Живой сигнал "кто-то поменял блокировку" (см. notifyBlockStatusChanged
    // на сервере) — без него локальный кэш обновлялся бы только при
    // следующем подключении/входе в конкретный чат, а не сразу, пока
    // список чатов уже открыт.
    _webSocketService.blockStatusEvents.listen(
      (_) => unawaited(_syncBlockedContacts(token)),
    );
    // Живой сигнал "у контакта поменялось что-то в профиле" — единый на
    // все поля (имя/статус/дата рождения/фото — см. websocket_service.dart:
    // profileChangedEvents), сервер шлёт только реальным контактам (см.
    // таблицу contacts) и доставляет офлайн-получателю при следующем
    // подключении. avatar сбрасывает AvatarCache (отдельный от
    // PeerProfileCache — тот байты фото не хранит), остальные поля —
    // PeerProfileCache, не ждём, пока истечёт TTL.
    _webSocketService.profileChangedEvents.listen((event) {
      if (event.field == 'avatar') {
        AvatarCache.invalidate(event.accountId);
      } else {
        PeerProfileCache.invalidate(event.accountId);
      }
    });

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
      String peerAccountId = '';
      if (currentToken != null) {
        final owner = await ApiClient().getDeviceOwnerInfo(
          currentToken,
          info.peerDeviceId,
        );
        if (owner != null) {
          peerLogin = owner.login;
          peerAccountId = owner.accountId;
        }
      }
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => IncomingCallScreen(
            peerLogin: peerLogin,
            peerAccountId: peerAccountId,
          ),
        ),
      );
    });

    _webSocketService.sessionInvalidated.listen((_) async {
      await Session.clearToken();
      await KeyStore.clearAll();
      await CallRingPlugin.clearCredentials();
      MyAvatarStore.reset();
      MyEmailStore.reset();
      MyProfileStore.reset();
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
      if (blocked == null) return;
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
    // Серверный вызов не прошёл (или accountId ещё не известен) —
    // ОТКАТЫВАЕМ локальный флаг, а не оставляем его молча висеть
    // "заблокировано" при том, что сервер об этом не знает: именно так
    // выглядел баг "плашка блокировки на миг появляется и тут же
    // пропадает" — композер держался на неправде до следующей
    // синхронизации с сервером, которая её и поправляла обратно.
    if (accountId == null) {
      debugPrint(
        '_setBlocked: peerLogin=${entry.peerLogin} has no lastKnownAccountId, '
        'cannot call server — is this chat fully resolved yet?',
      );
      await ChatStore.setChatBlockedByMe(entry.peerLogin, !blocked);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('error.blockFailed'))));
      }
      return;
    }
    try {
      final token = await Session.getToken();
      if (token == null) throw Exception('no session token');
      if (blocked) {
        await ApiClient().blockContact(token, accountId);
      } else {
        await ApiClient().unblockContact(token, accountId);
      }
    } catch (e) {
      debugPrint('_setBlocked: server call failed for $accountId: $e');
      await ChatStore.setChatBlockedByMe(entry.peerLogin, !blocked);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('error.blockFailed'))));
      }
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
      peerAccountId: entry.lastKnownAccountId,
      title: alsoDeleteChat
          ? tr('chatMenu.deleteChatTitle')
          : tr('chatMenu.clearHistoryTitle'),
      confirmLabel: alsoDeleteChat
          ? tr('chatMenu.deleteChatConfirm')
          : tr('chatMenu.clearHistoryConfirm'),
    );
    if (result == null || !mounted) return;

    if (result.alsoForPeer) {
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
        // Раньше здесь слался список СВОИХ id (InnerMessage.delete) — но
        // записи о звонках и подобное могли не совпасть 1:1 с тем, что
        // реально есть у собеседника, и часть истории у него оставалась
        // (см. фидбэк по этому багу). Теперь — один безусловный сигнал
        // "сотри у себя всё", без сверки по id (см. InnerMessage.clearChat/
        // .deleteChat) — получателю нечего сравнивать, поэтому проблема
        // рассинхрона id тут в принципе не может возникнуть.
        if (alsoDeleteChat) {
          // "Удалить диалог" — этого одного сигнала достаточно: он и
          // стирает всё содержимое, и убирает сам чат из списка
          // получателя (см. 'delete_chat' в message_router.dart).
          await ControlMessageSender.send(
            peerLogin: entry.peerLogin,
            peerDeviceId: deviceId,
            inner: InnerMessage.deleteChat(),
          );
        } else {
          await ControlMessageSender.send(
            peerLogin: entry.peerLogin,
            peerDeviceId: deviceId,
            inner: InnerMessage.clearChat(),
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
    return PopScope(
      // На "обратной стороне" (настройки/профиль) системный back должен
      // сначала развернуть карточку обратно к чатам, а не сразу закрывать
      // приложение — это то же самое действие, что и тап по табу чатов
      // на нижней панели. Активный поиск перехватывает back ЕЩЁ раньше и
      // сам, в два шага (см. ТЗ пользователя): первый back только прячет
      // клавиатуру, второй — сворачивает саму пилюлю поиска обратно в лупу.
      canPop: _selectedTab == 0 && !_searchActive,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_searchActive) {
          if (_searchFocusNode.hasFocus) {
            _searchFocusNode.unfocus();
          } else {
            _closeSearch();
          }
          return;
        }
        _selectTab(0);
      },
      child: Scaffold(
        // На табе "Профиль" заголовка НЕТ (крупный кружок с фото и так сам
        // по себе явно даёт понять, где мы, а надпись "Профиль" сверху
        // была лишним дублированием таба снизу, см. ТЗ пользователя), но
        // сам AppBar остаётся — просто пустой, БЕЗ title. Раньше здесь
        // было null: Scaffold.appBar — не то, что анимированно переключает
        // PageTransitionSwitcher body ниже, а отдельный слот, который
        // меняется МГНОВЕННО в момент setState. AppBar → null убирал сразу
        // все ~56px его высоты, тело экрана тут же дорастало вверх на
        // освободившееся место — и это происходило РАНЬШЕ, чем успевала
        // начаться сама анимация смены содержимого, отсюда и заметный
        // "прыжок"/мелькание при переходе именно в этот таб и обратно
        // (см. видео пользователя). Пустой AppBar() держит одну и ту же
        // высоту на всех трёх табах — реальный контент вкладки Профиль
        // (MyProfileContent) теперь сам добавляет лишь небольшой отступ
        // (16), а не весь MediaQuery.padding.top — раньше он это делал
        // именно ПОТОМУ, что AppBar отсутствовал.
        appBar: _selectedTab == 1
            ? AppBar(title: Text(tr('settings.title')))
            : _selectedTab == 2
            ? AppBar()
            : AppBar(
                title: _buildAppBarTitle(),
                centerTitle: false,
                // Скруглённые нижние углы (см. ТЗ пользователя) — верхние
                // сознательно НЕ трогаем, они и так уже прижаты к самому
                // верху экрана статус-баром, скруглять там нечего видеть.
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(
                    bottom: Radius.circular(20),
                  ),
                ),
                actions: [
                  _BouncyIconButton(
                    icon: _searchActive ? Icons.close : Icons.search,
                    onPressed: _searchActive ? _closeSearch : _openSearch,
                  ),
                ],
              ),
        body: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: _onHorizontalDragStart,
                onHorizontalDragUpdate: _onHorizontalDragUpdate,
                onHorizontalDragEnd: _onHorizontalDragEnd,
                // БЕЗ Padding(bottom:) снаружи — иначе сам прокручиваемый
                // viewport списка обрезан этой высотой и последний чат
                // физически не может доехать до зоны под капсулой, ни при
                // каком скролле (см. скриншоты пользователя — Notes
                // упирался в границу). Тот же по величине отступ теперь
                // висит на паддинге прокрутки внутри каждой вкладки (см.
                // bottomActionBarReservedHeight — _buildChatList/
                // SettingsContent/MyProfileContent) — в покое выглядит
                // так же, но последний элемент можно докрутить под
                // капсулу и увидеть его сквозь блюр.
                child: _buildFlippableBody(),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: BottomActionBar(
                items: [
                  BottomTabItem(
                    icon: Icons.chat_bubble_outline,
                    label: tr('nav.chats'),
                  ),
                  BottomTabItem(icon: Icons.tune, label: tr('nav.settings')),
                  BottomTabItem(
                    avatar: MyAvatarStore.notifier,
                    label: tr('nav.profile'),
                  ),
                ],
                selectedIndex: _selectedTab,
                onTabSelected: _selectTab,
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: _buildSearchResultsPanel(),
            ),
          ],
        ),
      ),
    );
  }

  /// Shared axis (horizontal) — из пакета animations (тот же
  /// PageTransitionSwitcher/SharedAxisTransition, что и в официальном
  /// демо Material), теперь на 3 таба вместо 2 — направление берётся из
  /// _transitionReverse, зафиксированного в момент переключения таба
  /// (см. _selectTab), а не пересчитывается на каждый build.
  Widget _buildFlippableBody() {
    final Widget child;
    switch (_selectedTab) {
      case 1:
        child = const SettingsContent();
      case 2:
        child = const MyProfileContent();
      default:
        child = _buildChatList();
    }
    return PageTransitionSwitcher(
      duration: const Duration(milliseconds: 400),
      reverse: _transitionReverse,
      transitionBuilder: (child, animation, secondaryAnimation) {
        return SharedAxisTransition(
          animation: animation,
          secondaryAnimation: secondaryAnimation,
          transitionType: SharedAxisTransitionType.horizontal,
          fillColor: AppColors.background,
          child: child,
        );
      },
      child: KeyedSubtree(key: ValueKey(_selectedTab), child: child),
    );
  }

  Widget _buildChatList() {
    return ScrollConfiguration(
      behavior: _NoGlowScrollBehavior(),
      child: ListView.builder(
        padding: EdgeInsets.only(
          bottom: bottomActionBarReservedHeight(context),
        ),
        itemCount: _entries.length,
        itemBuilder: (context, index) {
          final entry = _entries[index];
          final isNotes = entry.peerLogin == notesPeerLogin;

          return GestureDetector(
            onLongPressStart: isNotes
                ? null
                : (details) => _openChatMenu(entry, details.globalPosition),
            // Material вместо Container(color:) — ListTile рисует ripple
            // (рябь под пальцем при тапе) на ближайшем Material-предке;
            // непрозрачная заливка обычного Container поверх нею полностью
            // перекрывала эту анимацию (Flutter в debug-режиме честно
            // предупреждал об этом). Material.color красит фон точно так
            // же, но САМ и есть тот холст, на котором рисуется ripple —
            // так что она снова видна поверх подсветки непрочитанного.
            child: Material(
              color: entry.unreadCount > 0
                  ? AppColors.primary.withValues(alpha: 0.12)
                  : Colors.transparent,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                minVerticalPadding: 12,
                leading: _ChatAvatarLeading(
                  isNotes: isNotes,
                  accountId: entry.lastKnownAccountId,
                ),
                title: isNotes || entry.isDeleted || entry.lastKnownAccountId == null
                    ? Text(
                        isNotes
                            ? tr('home.notes')
                            : (entry.isDeleted
                                  ? tr('home.deletedAccount')
                                  : entry.peerLogin),
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 17,
                          fontWeight: entry.unreadCount > 0
                              ? FontWeight.bold
                              : FontWeight.w600,
                        ),
                      )
                    : PeerNameText(
                        accountId: entry.lastKnownAccountId!,
                        fallbackLogin: entry.peerLogin,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 17,
                          fontWeight: entry.unreadCount > 0
                              ? FontWeight.bold
                              : FontWeight.w600,
                        ),
                      ),
                subtitle: Text(
                  entry.lastMessage,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 14,
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
                    // Заблокировано в любую сторону (я заблокировал или
                    // заблокировали меня) — оба случая одинаково означают
                    // "переписка в этом чате сейчас недоступна", см.
                    // композер-заглушку в chat_screen.dart.
                    if (entry.blockedByMe || entry.blockingMe)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(
                          Icons.block,
                          size: 13,
                          color: AppColors.textMuted,
                        ),
                      ),
                    if (entry.lastTimestamp > 0) ...[
                      // Галочки — только когда последнее сообщение МОЁ (см.
                      // ТЗ пользователя): одна, если ещё не прочитано, две
                      // — если собеседник уже прочитал. Тот же цвет, что и
                      // у времени рядом, чтобы читалось одной группой.
                      if (entry.lastMessageIsMine)
                        Padding(
                          padding: const EdgeInsets.only(right: 3),
                          child: Icon(
                            entry.lastMessageIsRead
                                ? Icons.done_all
                                : Icons.done,
                            size: 14,
                            color: entry.unreadCount > 0
                                ? AppColors.primary
                                : AppColors.textMuted,
                          ),
                        ),
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
/// для "Заметок" всегда своё фото, но берём его из MyAvatarStore (единый
/// источник истины для СВОЕГО фото, см. this file's _connect()), а не
/// через отдельный сетевой запрос на каждую перерисовку строки. Для
/// остальных чатов — фото того, с кем переписка, через общий AvatarCache.
class _ChatAvatarLeading extends StatelessWidget {
  final bool isNotes;
  final String? accountId;

  const _ChatAvatarLeading({required this.isNotes, required this.accountId});

  @override
  Widget build(BuildContext context) {
    if (isNotes) {
      return ValueListenableBuilder<Uint8List?>(
        valueListenable: MyAvatarStore.notifier,
        builder: (context, bytes, _) =>
            AvatarThumbnail(bytes: bytes, radius: 27),
      );
    }
    return _OtherAvatarLeading(accountId: accountId);
  }
}

/// bytes == null (нет фото/не удалось скачать) — заглушка (см.
/// AvatarThumbnail), не ошибка, показывать нечего гонять лишний раз.
/// StatefulWidget НАМЕРЕННО, а не FutureBuilder(future: _resolve()) прямо
/// в build() — тот пересоздавал бы future при КАЖДОЙ перерисовке строки
/// (любое обновление списка чатов), а значит и заново гонял бы сеть/кэш
/// каждый раз вместо одного раза за время жизни этого элемента списка.
class _OtherAvatarLeading extends StatefulWidget {
  final String? accountId;

  const _OtherAvatarLeading({required this.accountId});

  @override
  State<_OtherAvatarLeading> createState() => _OtherAvatarLeadingState();
}

class _OtherAvatarLeadingState extends State<_OtherAvatarLeading> {
  late Future<Uint8List?> _future = _resolve();
  StreamSubscription<String>? _changesSub;

  @override
  void initState() {
    super.initState();
    _listenForChanges();
  }

  // Живой сигнал (см. AvatarCache.changes/_connect() в этом файле) — если
  // ИМЕННО этот accountId только что обновился где-то ещё, перезапрашиваем
  // сразу, а не ждём, пока строка списка перестроится сама по себе (а без
  // смены accountId она бы и не перестроилась).
  void _listenForChanges() {
    _changesSub = AvatarCache.changes.listen((changedId) {
      if (changedId == widget.accountId && mounted) {
        setState(() => _future = _resolve());
      }
    });
  }

  Future<Uint8List?> _resolve() async {
    final id = widget.accountId;
    if (id == null || id.isEmpty) return null;
    return AvatarCache.get(id);
  }

  @override
  void didUpdateWidget(covariant _OtherAvatarLeading old) {
    super.didUpdateWidget(old);
    if (old.accountId != widget.accountId) {
      _future = _resolve();
    }
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snapshot) {
        return AvatarThumbnail(bytes: snapshot.data, radius: 27);
      },
    );
  }
}

/// Кнопка-лупа поиска в шапке списка чатов (см. _openSearch/_closeSearch) —
/// сама иконка чуть проседает и снова пружинит обратно при нажатии, вместо
/// мгновенной, никак визуально не подтверждённой реакции. GestureDetector,
/// а не встроенный InkResponse/splash у IconButton — тот даёт только
/// заливку без движения самой иконки.
class _BouncyIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _BouncyIconButton({required this.icon, required this.onPressed});

  @override
  State<_BouncyIconButton> createState() => _BouncyIconButtonState();
}

class _BouncyIconButtonState extends State<_BouncyIconButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
    lowerBound: 0,
    upperBound: 1,
  );
  late final Animation<double> _scale = Tween(
    begin: 1.0,
    end: 0.8,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _controller.forward(),
      onTapCancel: () => _controller.reverse(),
      onTapUp: (_) {
        _controller.reverse();
        widget.onPressed();
      },
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: ScaleTransition(
          scale: _scale,
          child: Icon(widget.icon, color: AppColors.textPrimary),
        ),
      ),
    );
  }
}
