import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import '../api/api_client.dart';
import '../crypto/double_ratchet.dart';
import '../crypto/key_store.dart';
import '../crypto/media_cipher.dart';
import '../crypto/message_cipher.dart';
import '../crypto/message_envelope.dart';
import '../crypto/session_store.dart';
import '../crypto/streaming_file_cipher.dart';
import '../crypto/x3dh.dart';
import '../models/picked_media.dart';
import '../screens/call_screen.dart';
import '../screens/camera_capture_screen.dart';
import '../screens/media_viewer_screen.dart';
import '../services/active_chat_tracker.dart';
import '../services/call_service.dart';
import '../services/chat_scroll_position_store.dart';
import '../services/keyboard_height_store.dart';
import '../services/send_lock.dart';
import '../services/websocket_service.dart';
import '../session.dart';
import '../storage/chat_store.dart';
import '../storage/media_cache.dart';
import '../storage/peer_account_store.dart';
import '../storage/peer_identity_store.dart';
import '../theme/app_theme.dart';
import '../utils/time_format.dart';
import '../storage/default_reaction_store.dart';
import '../widgets/delete_message_dialog.dart';
import '../widgets/full_emoji_picker.dart';
import '../widgets/media_picker_sheet.dart';
import '../widgets/message_context_menu.dart';
import '../widgets/ongoing_call_banner.dart';
import '../widgets/swipe_back_page_route.dart';
import 'forward_screen.dart';

class ChatScreen extends StatefulWidget {
  final String peerDeviceId;
  final String peerAccountId;
  final String peerLogin;
  final List<String>? forwardedTexts;

  const ChatScreen({
    super.key,
    required this.peerDeviceId,
    required this.peerAccountId,
    required this.peerLogin,
    this.forwardedTexts,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static const int _autoDownloadLimitBytes = 10 * 1024 * 1024; // 10 МБ
  static const int _streamingThresholdBytes = 20 * 1024 * 1024; // 20 МБ
  static const int _maxAttachmentSizeBytes = 500 * 1024 * 1024; // 500 МБ

  final _textController = TextEditingController();
  final _textFocusNode = FocusNode();
  // Не final: до тех пор, пока _bootstrapHistory() не узнает сохранённую
  // позицию прокрутки, здесь висит одноразовая "заглушка" (ни к чему не
  // подключена — список ещё не построен, см. _scrollReady), а как только
  // позиция известна, поле подменяется на настоящий ScrollController с уже
  // выставленным initialScrollOffset — так список строится СРАЗУ в нужном
  // месте, без видимого "сверху, а потом прыжок туда, где я был".
  ScrollController _scrollController = ScrollController();
  bool _scrollReady = false;
  final _apiClient = ApiClient();
  final Map<String, Future<Uint8List>> _mediaFutures = {};
  final Map<String, Uint8List> _resolvedMedia = {};
  final Map<String, Future<bool>> _existsChecks = {};
  final Map<String, Future<void>> _chunkedDownloads = {};

  String _currentPeerDeviceId = '';
  Map<String, dynamic>? _pendingInitHeader;
  bool _isPeerDeleted = false;
  bool _userAtBottom = true;
  bool _initialLoadComplete = false;
  int _lastMessageCount = 0;
  Timer? _scrollSaveDebounce;

  bool _emojiMode = false;
  double _keyboardHeight = 280;
  double _targetReserve = 0;
  bool _switchingMode = false;
  bool _hasText = false;
  double _lastReserved = 0;

  List<StoredMessage> _messages = [];

  // Ответ на сообщение — баннер над полем ввода, сбрасывается после отправки.
  StoredMessage? _replyTarget;

  // Закреп — id закреплённого сообщения этого чата (один на чат).
  String? _pinnedMessageId;

  // Редактирование своего текстового сообщения без группы.
  StoredMessage? _editingMessage;

  // Пересылка в этот чат — тексты, полученные из ForwardScreen.
  List<String>? _forwardingTexts;

  // Режим выбора сообщений.
  bool _selectionMode = false;
  final Set<String> _selectedMessageIds = {};

  final Map<String, GlobalKey> _messageKeys = {};

  // Ручное распознавание одиночный/двойной тап по сообщению (см.
  // _wrapInteractive): единственный тап откладывает открытие контекстного
  // меню на _doubleTapWindow — если за это время придёт второй тап по тому
  // же сообщению, это двойной тап (реакция по умолчанию), а не одиночный.
  static const _doubleTapWindow = Duration(milliseconds: 150);
  Timer? _pendingTapTimer;
  String? _lastTapMessageId;
  DateTime? _lastTapTime;

  @override
  void initState() {
    super.initState();
    ActiveChatTracker.currentPeerLogin = widget.peerLogin;
    ChatStore.clearUnread(widget.peerLogin);
    _currentPeerDeviceId = widget.peerDeviceId;
    _forwardingTexts = widget.forwardedTexts;
    _textFocusNode.addListener(_onFocusChange);
    _textController.addListener(_onTextChanged);
    _loadKnownDeletedStatus();
    _bootstrapHistory();
    ChatStore.changes.listen((_) {
      _loadHistory();
      _loadKnownDeletedStatus();
    });
    KeyboardHeightStore.getKnownHeight().then((height) {
      if (mounted) setState(() => _keyboardHeight = height);
    });
  }

  void _onFocusChange() {
    if (_textFocusNode.hasFocus) {
      setState(() {
        _emojiMode = false;
        _targetReserve = _keyboardHeight;
      });
    } else {
      if (_switchingMode) {
        _switchingMode = false;
        return;
      }
      setState(() => _targetReserve = 0);
    }
  }

  void _onTextChanged() {
    final hasText = _textController.text.trim().isNotEmpty;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
    }
  }

  Future<void> _loadKnownDeletedStatus() async {
    final peers = await ChatStore.getKnownPeers();
    final match = peers.where((p) => p.peerLogin == widget.peerLogin);
    if (match.isNotEmpty && mounted) {
      setState(() {
        _isPeerDeleted = match.first.isDeleted;
        _pinnedMessageId = match.first.pinnedMessageId;
      });
    }
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    _userAtBottom =
        _scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 40;

    // Сохраняем позицию не только при выходе из экрана (dispose может
    // вообще не вызваться — например, если приложение просто убили из
    // диспетчера задач, пока чат был открыт), а при КАЖДОЙ остановке
    // скролла — debounce, чтобы не писать на диск на каждый кадр жеста.
    _scrollSaveDebounce?.cancel();
    _scrollSaveDebounce = Timer(const Duration(milliseconds: 400), () {
      if (_scrollController.hasClients) {
        unawaited(
          ChatScrollPositionStore.set(
            widget.peerLogin,
            _scrollController.offset,
          ),
        );
      }
    });
  }

  /// Первая загрузка истории — единственное место, где создаётся настоящий
  /// (подключаемый к списку) _scrollController. Ждём и сообщения, и
  /// сохранённую позицию ДО первого построения списка, чтобы он сразу
  /// появился в нужном месте — никакого "сверху, а через мгновение прыжок
  /// туда, где был" (именно так выглядело раньше: список строился в
  /// дефолтные 0, а сохранённая позиция подставлялась только постфактум,
  /// уже видимым прыжком).
  Future<void> _bootstrapHistory() async {
    final messagesFuture = ChatStore.getMessages(widget.peerLogin);
    final savedFuture = ChatScrollPositionStore.get(widget.peerLogin);
    final messages = await messagesFuture;
    final saved = await savedFuture;
    if (!mounted) return;

    _lastMessageCount = messages.length;

    final oldController = _scrollController;
    _scrollController = ScrollController(initialScrollOffset: saved ?? 0);
    _scrollController.addListener(_handleScroll);
    oldController.dispose();

    setState(() {
      _messages = messages;
      _scrollReady = true;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_scrollController.hasClients) return;
      // saved == 0 — совершенно законная позиция (самый верх чата), не то
      // же самое, что "позиции никогда не было" (null).
      if (saved != null) {
        // initialScrollOffset уже поставил список туда — это только
        // страховочная донастройка на случай, если maxScrollExtent в первые
        // кадры был занижен (см. _settleScrollTo).
        await _settleScrollTo(saved);
      } else {
        await _scrollToBottom(animate: false);
      }
      // Пересчитываем "у низа ли я" уже по ОКОНЧАТЕЛЬНОЙ, устоявшейся
      // позиции — во время самой раскладки первых кадров (список ещё
      // пустой/неизмеренный) _handleScroll мог мимоходом выставить этот
      // флаг в true просто потому, что 0>=0-40, и без этой явной
      // перепроверки чат тут же сам съезжал вниз сразу после восстановления.
      if (mounted && _scrollController.hasClients) {
        _userAtBottom =
            _scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 40;
      }
      _initialLoadComplete = true;
    });
  }

  Future<void> _loadHistory() async {
    final messages = await ChatStore.getMessages(widget.peerLogin);
    if (!mounted) return;

    final countChanged = messages.length != _lastMessageCount;
    _lastMessageCount = messages.length;

    setState(() => _messages = messages);

    if (_initialLoadComplete && _userAtBottom && countChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  /// Прыгает к offset'у, а затем несколько раз перепроверяет и
  /// доскакивает — ленивый ListView.builder ещё не измерил всё дерево до
  /// этой точки в первые кадры (особенно если рядом есть медиа-превью,
  /// которые сами дорастают асинхронно), поэтому maxScrollExtent в момент
  /// первого прыжка может быть занижен, и наивный clamp() к нему обрезает
  /// целевую позицию — отсюда систематическое "не доехал на пару сообщений".
  Future<void> _settleScrollTo(double target) async {
    if (!_scrollController.hasClients) return;
    double clampedTarget() =>
        target.clamp(0, _scrollController.position.maxScrollExtent);
    _scrollController.jumpTo(clampedTarget());
    for (var i = 0; i < 6; i++) {
      await Future.delayed(const Duration(milliseconds: 80));
      if (!mounted || !_scrollController.hasClients) return;
      final next = clampedTarget();
      if ((next - _scrollController.offset).abs() < 1) return;
      _scrollController.jumpTo(next);
    }
  }

  /// Едет в самый низ и затем ТАК ЖЕ доскакивает несколько раз, если
  /// maxScrollExtent продолжает расти уже после первого прыжка/анимации —
  /// см. _settleScrollTo. Это единственная точка, из которой стоит вызывать
  /// прокрутку к низу — весь остальной код должен звать именно её, а не
  /// трогать _scrollController напрямую, иначе снова разъедемся на
  /// несколько независимых, не всегда согласованных реализаций "низа".
  Future<void> _scrollToBottom({bool animate = true}) async {
    if (!_scrollController.hasClients) return;
    if (animate) {
      await _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
    for (var i = 0; i < 6; i++) {
      if (!mounted || !_scrollController.hasClients) return;
      await Future.delayed(const Duration(milliseconds: 80));
      if (!mounted || !_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if ((target - _scrollController.offset).abs() < 1) return;
      _scrollController.jumpTo(target);
    }
  }

  Future<void> _refreshPeerDeviceId() async {
    try {
      final token = await Session.getToken();
      final result = await _apiClient.getDevicesByLogin(
        token!,
        widget.peerLogin,
      );
      if (result.devices.isNotEmpty) {
        _currentPeerDeviceId = result.devices.first['device_id'] as String;
        await ChatStore.setLastKnownDeviceId(
          widget.peerLogin,
          _currentPeerDeviceId,
        );
        await ChatStore.setPeerDeletedStatus(widget.peerLogin, false);
        if (mounted) setState(() => _isPeerDeleted = false);
      }
    } on ApiException catch (_) {
      await ChatStore.setPeerDeletedStatus(widget.peerLogin, true);
      if (mounted) setState(() => _isPeerDeleted = true);
    } catch (_) {
      // Сетевая ошибка — не трогаем текущий статус.
    }
  }

  void _startCall() {
    if (_isPeerDeleted) return;
    // Экран разговора должен открыться сразу — актуализация device_id и
    // сам обмен WebRTC идут уже в фоне, с живым статусом на самом экране
    // (см. CallService.statusUpdates), а не как задержка перед его показом.
    unawaited(_refreshPeerDeviceId());
    unawaited(CallService.instance.startCall(_currentPeerDeviceId));
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CallScreen(peerLogin: widget.peerLogin),
      ),
    );
  }

  void _setReplyTarget(StoredMessage msg) {
    setState(() {
      _replyTarget = msg;
      _editingMessage = null;
    });
    _textFocusNode.requestFocus();
  }

  void _cancelReply() => setState(() => _replyTarget = null);

  void _startEdit(StoredMessage msg) {
    setState(() {
      _editingMessage = msg;
      _replyTarget = null;
      _textController.text = msg.text;
      _textController.selection = TextSelection.collapsed(
        offset: msg.text.length,
      );
    });
    _textFocusNode.requestFocus();
  }

  void _cancelEdit() {
    setState(() {
      _editingMessage = null;
      _textController.clear();
    });
  }

  Future<void> _handleReaction(StoredMessage msg, String? emoji) async {
    await ChatStore.setReaction(
      widget.peerLogin,
      msg.messageId,
      isMine: true,
      emoji: emoji,
    );
    await _loadHistory();
    await _sendControlMessage(
      InnerMessage.reaction(targetMessageId: msg.messageId, emoji: emoji),
    );
  }

  /// Двойной тап по сообщению — ставит личную реакцию по умолчанию (как
  /// повторный тап по уже стоящей реакции в панели — снимает её).
  Future<void> _applyDefaultReaction(StoredMessage msg) async {
    final defaultEmoji = await DefaultReactionStore.get();
    final isRemoving = msg.myReaction == defaultEmoji;
    await _handleReaction(msg, isRemoving ? null : defaultEmoji);
  }

  Future<void> _togglePin(StoredMessage msg, {required bool pin}) async {
    final targetId = pin ? msg.messageId : null;
    setState(() => _pinnedMessageId = targetId);
    await ChatStore.setPinned(widget.peerLogin, targetId);
    await _sendControlMessage(
      InnerMessage.pin(targetMessageId: msg.messageId, pinned: pin),
    );
  }

  Future<void> _copyText(StoredMessage msg) async {
    await Clipboard.setData(ClipboardData(text: msg.text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Скопировано'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  Future<void> _copySelectedTexts() async {
    final texts = _selectedTexts();
    if (texts.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: texts.join('\n')));
    _exitSelectionMode();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Скопировано'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  void _enterSelectionMode(StoredMessage msg, {List<String>? groupMessageIds}) {
    setState(() {
      _selectionMode = true;
      _selectedMessageIds
        ..clear()
        ..addAll(groupMessageIds ?? [msg.messageId]);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedMessageIds.clear();
    });
  }

  /// Групповой пузырь (несколько сообщений под одним groupId, см. объяснение
  /// выше про _buildGroupBubble) выбирается/удаляется ЦЕЛИКОМ, одним тапом —
  /// поэтому переключение выбора всегда идёт по полному списку id, который
  /// составляет этот пузырь (для одиночного сообщения это список из одного
  /// элемента). Снятие выбора с ПОСЛЕДНЕГО оставшегося сообщения само
  /// закрывает режим выбора — состояния "выбрано 0 сообщений" не бывает.
  void _toggleGroupSelected(List<String> ids) {
    final allSelected = ids.every(_selectedMessageIds.contains);
    setState(() {
      if (allSelected) {
        _selectedMessageIds.removeAll(ids);
      } else {
        _selectedMessageIds.addAll(ids);
      }
      if (_selectedMessageIds.isEmpty) {
        _selectionMode = false;
      }
    });
  }

  List<String> _selectedTexts() {
    return _messages
        .where(
          (m) =>
              _selectedMessageIds.contains(m.messageId) &&
              !m.isMedia &&
              !m.isCallLog,
        )
        .map((m) => m.text)
        .toList();
  }

  /// Диалог подтверждения — тот же путь для одиночного и массового удаления.
  /// Если среди удаляемых — закреплённое сообщение, открепляем его в шапке:
  /// у себя всегда (раз сообщения больше нет), у собеседника — только если
  /// удаление реально дошло и до него ("у собеседника тоже").
  Future<void> _deleteMessages(List<String> ids) async {
    if (ids.isEmpty) return;

    final result = await showDeleteMessagesDialog(
      context,
      peerName: widget.peerLogin,
    );
    if (result == null || !mounted) return;

    final deletingPinned =
        _pinnedMessageId != null && ids.contains(_pinnedMessageId);
    final pinnedId = _pinnedMessageId;

    if (result.alsoForPeer) {
      await _sendControlMessage(InnerMessage.delete(targetMessageIds: ids));
      if (deletingPinned && pinnedId != null) {
        await _sendControlMessage(
          InnerMessage.pin(targetMessageId: pinnedId, pinned: false),
        );
      }
    }
    if (deletingPinned) {
      setState(() => _pinnedMessageId = null);
      await ChatStore.setPinned(widget.peerLogin, null);
    }
    await ChatStore.deleteMessages(widget.peerLogin, ids);
    if (_selectionMode) _exitSelectionMode();
    await _loadHistory();
  }

  void _openForward(List<String> texts) {
    if (texts.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ForwardScreen(messageTexts: texts),
      ),
    );
  }

  void _scrollToMessage(String messageId) {
    final ctx = _messageKeys[messageId]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        alignment: 0.5,
      );
    }
  }

  Future<void> _openContextMenu(
    StoredMessage msg,
    Offset tapPosition, {
    List<String>? groupMessageIds,
  }) async {
    if (_selectionMode) {
      _toggleGroupSelected(groupMessageIds ?? [msg.messageId]);
      return;
    }

    // Прячем клавиатуру/эмодзи-панель ДО открытия меню — иначе после
    // закрытия меню (в том числе простым тапом мимо, по барьеру) Flutter
    // восстанавливает фокус текстовому полю, если оно было в фокусе до
    // открытия диалога, и клавиатура снова выезжает сама по себе.
    if (_textFocusNode.hasFocus || _emojiMode) {
      _textFocusNode.unfocus();
      setState(() {
        _emojiMode = false;
        _targetReserve = 0;
      });
    }

    final showEdit =
        msg.isMine && !msg.isMedia && !msg.isCallLog && msg.groupId == null;
    final showCopy = !msg.isMedia && !msg.isCallLog;
    final isPinned = _pinnedMessageId == msg.messageId;

    final selection = await showMessageContextMenu(
      context,
      tapPosition: tapPosition,
      isMine: msg.isMine,
      showCopy: showCopy,
      showEdit: showEdit,
      isPinned: isPinned,
      currentMyReaction: msg.myReaction,
    );
    if (selection == null || !mounted) return;

    if (selection.isReaction) {
      await _handleReaction(msg, selection.emoji);
      return;
    }

    switch (selection.action!) {
      case MessageMenuAction.reply:
        _setReplyTarget(msg);
        break;
      case MessageMenuAction.copy:
        await _copyText(msg);
        break;
      case MessageMenuAction.pin:
        await _togglePin(msg, pin: true);
        break;
      case MessageMenuAction.unpin:
        await _togglePin(msg, pin: false);
        break;
      case MessageMenuAction.forward:
        _openForward([msg.text]);
        break;
      case MessageMenuAction.edit:
        _startEdit(msg);
        break;
      case MessageMenuAction.select:
        _enterSelectionMode(msg, groupMessageIds: groupMessageIds);
        break;
      case MessageMenuAction.delete:
        await _deleteMessages(groupMessageIds ?? [msg.messageId]);
        break;
    }
  }

  Future<RatchetState> _ensureSessionForSending() async {
    await _refreshPeerDeviceId();
    var state = await SessionStore.getState(_currentPeerDeviceId);
    if (state != null) return state;

    final token = await Session.getToken();
    final myDeviceId = await KeyStore.getStoredDeviceId();
    final bundle = await _apiClient.getPrekeyBundle(
      token!,
      _currentPeerDeviceId,
    );
    await PeerAccountStore.save(
      _currentPeerDeviceId,
      bundle['account_id'] as String,
    );
    await PeerIdentityStore.save(
      _currentPeerDeviceId,
      bundle['identity_dh_pubkey'] as String,
    );

    final outgoing = await establishOutgoingRoot(
      bundle: bundle,
      myDeviceId: myDeviceId!,
    );
    state = await RatchetState.initAsSender(
      rootKey: outgoing.rootKey,
      ephemeralKeyPair: outgoing.ephemeralKeyPair,
    );
    _pendingInitHeader = outgoing.initHeader;
    return state;
  }

  Future<void> _handleSendPressed() async {
    final text = _textController.text.trim();

    if (_editingMessage != null) {
      if (text.isEmpty) return;
      await _commitEdit(text);
      return;
    }

    final forwarding = _forwardingTexts;
    if (forwarding != null && forwarding.isNotEmpty) {
      _textController.clear();
      setState(() => _forwardingTexts = null);
      await _sendMultipleTexts([...forwarding, if (text.isNotEmpty) text]);
      return;
    }

    if (text.isEmpty) return;
    _textController.clear();
    await _sendTextMessage(text);
  }

  Future<void> _commitEdit(String newText) async {
    final target = _editingMessage!;
    _textController.clear();
    setState(() => _editingMessage = null);
    await ChatStore.editMessageText(
      widget.peerLogin,
      target.messageId,
      newText,
    );
    await _loadHistory();
    await _sendControlMessage(
      InnerMessage.edit(targetMessageId: target.messageId, newText: newText),
    );
  }

  /// Отправляет служебное control-сообщение (реакция/пин/изменение/удаление)
  /// тем же каналом (Double Ratchet + офлайн-очередь на сервере), что и
  /// обычные сообщения — но без записи в локальную историю чата, у этих
  /// типов нет собственного пузыря.
  Future<void> _sendControlMessage(InnerMessage inner) async {
    try {
      await SendLock.run(widget.peerLogin, () async {
        final myDeviceId = await KeyStore.getStoredDeviceId();
        final state = await _ensureSessionForSending();
        final initHeader = _pendingInitHeader;
        _pendingInitHeader = null;

        final next = await state.nextSendingKey();
        await SessionStore.saveState(_currentPeerDeviceId, state);

        final encrypted = await encryptMessage(next.messageKey, inner.encode());
        final envelope = <String, dynamic>{
          ...encrypted,
          ...next.header,
          'sender_device_id': myDeviceId,
          if (initHeader != null) ...initHeader,
        };

        await WebSocketService.instance.sendEnvelope(
          _currentPeerDeviceId,
          envelope,
          inner.messageId,
          silent: true,
        );
      });
    } catch (e) {
      debugPrint('Ошибка отправки служебного сообщения: $e');
    }
  }

  Future<void> _sendTextMessage(String text) async {
    final replyId = _replyTarget?.messageId;
    final replyPreview = _replyTarget?.text;
    final inner = InnerMessage.text(
      text,
      replyToMessageId: replyId,
      replyToPreview: replyPreview,
    );
    await ChatStore.addMessage(
      widget.peerLogin,
      StoredMessage(
        inner.messageId,
        text,
        true,
        inner.sentAt,
        status: 'sending',
        replyToMessageId: replyId,
        replyToPreview: replyPreview,
      ),
      accountId: widget.peerAccountId,
    );
    if (_replyTarget != null) setState(() => _replyTarget = null);
    // Своё исходящее сообщение — прокрутка в самый низ ВСЕГДА, даже если до
    // этого читали историю выше: иначе только что отправленное сообщение
    // может остаться не видно за пределами экрана.
    _userAtBottom = true;
    await _loadHistory();
    await _sendTextNetwork(
      text,
      inner.messageId,
      replyToMessageId: replyId,
      replyToPreview: replyPreview,
    );
  }

  Future<void> _sendTextNetwork(
    String text,
    String messageId, {
    String? replyToMessageId,
    String? replyToPreview,
  }) async {
    final inner = InnerMessage(
      messageId: messageId,
      type: 'text',
      sentAt: DateTime.now().millisecondsSinceEpoch,
      body: text,
      replyToMessageId: replyToMessageId,
      replyToPreview: replyToPreview,
    );

    try {
      await SendLock.run(widget.peerLogin, () async {
        final myDeviceId = await KeyStore.getStoredDeviceId();
        final state = await _ensureSessionForSending();
        final initHeader = _pendingInitHeader;
        _pendingInitHeader = null;

        final next = await state.nextSendingKey();
        await SessionStore.saveState(_currentPeerDeviceId, state);

        final encrypted = await encryptMessage(next.messageKey, inner.encode());
        final envelope = <String, dynamic>{
          ...encrypted,
          ...next.header,
          'sender_device_id': myDeviceId,
          if (initHeader != null) ...initHeader,
        };

        final status = await WebSocketService.instance.sendEnvelope(
          _currentPeerDeviceId,
          envelope,
          inner.messageId,
        );

        await ChatStore.updateMessageStatus(
          widget.peerLogin,
          inner.messageId,
          status,
        );
      });
    } catch (_) {
      await ChatStore.updateMessageStatus(
        widget.peerLogin,
        messageId,
        'failed',
      );
    } finally {
      await _loadHistory();
    }
  }

  /// Пересылка нескольких сообщений разом: ВСЕ сразу кладутся в локальную
  /// историю и появляются в чате одним движением (со статусом "отправка"),
  /// и только ПОСЛЕ этого поочерёдно уходят в сеть — а не по одному, с
  /// появлением каждого следующего только после того, как предыдущее
  /// целиком долетело. Каждое всё равно продолжает жить своей отдельной
  /// сетевой отправкой (Double Ratchet требует строгого порядка ключей
  /// в рамках одной цепочки), поэтому сетевая часть остаётся
  /// последовательной — меняется только то, когда сообщения появляются
  /// на экране.
  Future<void> _sendMultipleTexts(List<String> texts) async {
    if (texts.isEmpty) return;
    final pending = <({String messageId, String text})>[];
    for (final t in texts) {
      final inner = InnerMessage.text(t);
      await ChatStore.addMessage(
        widget.peerLogin,
        StoredMessage(
          inner.messageId,
          t,
          true,
          inner.sentAt,
          status: 'sending',
        ),
        accountId: widget.peerAccountId,
      );
      pending.add((messageId: inner.messageId, text: t));
    }
    _userAtBottom = true;
    await _loadHistory();
    for (final p in pending) {
      await _sendTextNetwork(p.text, p.messageId);
    }
  }

  Future<void> _openAttachmentSheet() async {
    _textFocusNode.unfocus();
    setState(() {
      _emojiMode = false;
      _targetReserve = 0;
    });

    final result = await showMediaPickerSheet(context);

    if (result == 'open_camera') {
      final cameraResult = await Navigator.push<CameraCaptureResult>(
        context,
        MaterialPageRoute(builder: (context) => const CameraCaptureScreen()),
      );
      if (cameraResult != null) {
        await _sendPickedMedia([
          PickedMedia(file: cameraResult.file),
        ], cameraResult.caption);
      }
      return;
    }

    if (result is MediaPickerSheetResult) {
      final files = <PickedMedia>[];
      for (final asset in result.items) {
        final file = await asset.file;
        if (file != null) {
          files.add(
            PickedMedia(file: file, isVideo: asset.type == AssetType.video),
          );
        }
      }
      if (files.isNotEmpty) {
        await _sendPickedMedia(files, result.caption);
      }
    }
  }

  Future<void> _sendPickedMedia(List<PickedMedia> media, String caption) async {
    String? textMessageId;
    final queue =
        <({PickedMedia item, String messageId, int size, String fileName})>[];

    final hasCaption = caption.isNotEmpty;
    final groupId = (media.length + (hasCaption ? 1 : 0)) > 1
        ? 'grp_${DateTime.now().microsecondsSinceEpoch}'
        : null;

    if (hasCaption) {
      final inner = InnerMessage.text(caption);
      textMessageId = inner.messageId;
      await ChatStore.addMessage(
        widget.peerLogin,
        StoredMessage(
          inner.messageId,
          caption,
          true,
          inner.sentAt,
          status: 'sending',
          groupId: groupId,
        ),
        accountId: widget.peerAccountId,
      );
    }

    for (var i = 0; i < media.length; i++) {
      final item = media[i];
      final size = await item.file.length();
      if (size > _maxAttachmentSizeBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Файл слишком большой (${_formatFileSize(size)})'),
            ),
          );
        }
        continue;
      }

      final messageId = '${DateTime.now().microsecondsSinceEpoch}_$i';
      final fileName = item.file.path.split('/').last;

      await ChatStore.addMessage(
        widget.peerLogin,
        StoredMessage(
          messageId,
          item.isVideo ? '🎬 Видео' : '📷 Фото',
          true,
          DateTime.now().millisecondsSinceEpoch,
          isMedia: true,
          isFile: item.isVideo,
          fileSize: size,
          chunked: size > _streamingThresholdBytes,
          fileName: fileName,
          status: 'sending',
          processingStep: 'В очереди',
          localPreviewPath: item.isVideo ? null : item.file.path,
          groupId: groupId,
        ),
        accountId: widget.peerAccountId,
      );

      queue.add((
        item: item,
        messageId: messageId,
        size: size,
        fileName: fileName,
      ));
    }

    _userAtBottom = true;
    await _loadHistory();

    if (groupId != null) {
      await _sendGroupNetwork(
        groupId,
        caption: hasCaption ? caption : null,
        textMessageId: textMessageId,
        items: queue,
      );
    } else {
      if (textMessageId != null) {
        await _sendTextNetwork(caption, textMessageId);
      }
      for (final q in queue) {
        await _processQueuedMedia(q.item, q.messageId, q.size, q.fileName);
      }
    }
  }

  /// Шифрует и грузит один файл на сервер, сохраняя прогресс локально —
  /// используется и для одиночной отправки, и для сборки группы.
  Future<Map<String, dynamic>> _uploadAndDescribeMedia(
    PickedMedia item,
    String messageId,
    int size,
    String fileName,
    String token,
    String peerAccountIdForUpload,
  ) async {
    final chunked = size > _streamingThresholdBytes;
    String mediaId;
    String keyBase64;
    String? nonceBase64;
    String? macBase64;

    await ChatStore.updateProcessingStep(
      widget.peerLogin,
      messageId,
      'Шифрование…',
    );

    if (chunked) {
      final tempDir = await getTemporaryDirectory();
      final encTempFile = File('${tempDir.path}/enc_$messageId.bin');
      final inputPath = item.file.path;
      final outputPath = encTempFile.path;
      final keyPath = '${tempDir.path}/key_$messageId.bin';
      await compute(encryptFileIsolateEntry, {
        'input': inputPath,
        'output': outputPath,
        'key': keyPath,
      });
      final keyBytes = await File(keyPath).readAsBytes();
      try {
        await File(keyPath).delete();
      } catch (_) {}

      await ChatStore.updateProcessingStep(
        widget.peerLogin,
        messageId,
        'Загрузка на сервер…',
      );
      mediaId = await _apiClient.uploadEncryptedMediaFileWithProgress(
        token,
        encTempFile.path,
        peerAccountIdForUpload,
        onProgress: (_) {},
      );
      try {
        await encTempFile.delete();
      } catch (_) {}
      await MediaCache.writeFromFile(mediaId, item.file);
      keyBase64 = base64Encode(keyBytes);
    } else {
      final bytes = await item.file.readAsBytes();
      final encrypted = await encryptFileBytes(bytes);
      await ChatStore.updateProcessingStep(
        widget.peerLogin,
        messageId,
        'Загрузка на сервер…',
      );
      mediaId = await _apiClient.uploadEncryptedMediaWithProgress(
        token,
        encrypted.ciphertext,
        peerAccountIdForUpload,
        onProgress: (_) {},
      );
      await MediaCache.write(mediaId, bytes);
      keyBase64 = base64Encode(encrypted.key);
      nonceBase64 = base64Encode(encrypted.nonce);
      macBase64 = base64Encode(encrypted.mac);
    }

    await ChatStore.updateMediaInfo(
      widget.peerLogin,
      messageId,
      mediaId: mediaId,
      keyBase64: keyBase64,
      nonceBase64: nonceBase64,
      macBase64: macBase64,
    );

    return {
      'message_id': messageId,
      'media_id': mediaId,
      'key': keyBase64,
      'nonce': nonceBase64,
      'mac': macBase64,
      'file_name': fileName,
      'is_file': item.isVideo,
      'file_size': size,
      'chunked': chunked,
    };
  }

  Future<void> _processQueuedMedia(
    PickedMedia item,
    String messageId,
    int size,
    String fileName,
  ) async {
    try {
      await SendLock.run(widget.peerLogin, () async {
        final token = await Session.getToken();
        final myDeviceId = await KeyStore.getStoredDeviceId();
        final state = await _ensureSessionForSending();
        final initHeader = _pendingInitHeader;
        _pendingInitHeader = null;

        final peerAccountIdForUpload =
            await PeerAccountStore.get(_currentPeerDeviceId) ??
            widget.peerAccountId;

        final desc = await _uploadAndDescribeMedia(
          item,
          messageId,
          size,
          fileName,
          token!,
          peerAccountIdForUpload,
        );

        await ChatStore.updateProcessingStep(
          widget.peerLogin,
          messageId,
          'Согласование с собеседником…',
        );

        final inner = InnerMessage.media(
          messageId: messageId,
          mediaId: desc['media_id'] as String,
          keyBase64: desc['key'] as String,
          nonceBase64: desc['nonce'] as String?,
          macBase64: desc['mac'] as String?,
          fileName: fileName,
          isFile: item.isVideo,
          fileSize: size,
          chunked: desc['chunked'] as bool,
        );

        final next = await state.nextSendingKey();
        await SessionStore.saveState(_currentPeerDeviceId, state);
        final encryptedEnvelope = await encryptMessage(
          next.messageKey,
          inner.encode(),
        );
        final envelope = <String, dynamic>{
          ...encryptedEnvelope,
          ...next.header,
          'sender_device_id': myDeviceId,
          if (initHeader != null) ...initHeader,
        };

        await ChatStore.updateProcessingStep(
          widget.peerLogin,
          messageId,
          'Отправка…',
        );
        final status = await WebSocketService.instance.sendEnvelope(
          _currentPeerDeviceId,
          envelope,
          messageId,
        );
        await ChatStore.updateMessageStatus(
          widget.peerLogin,
          messageId,
          status,
        );
      });
    } catch (e, stackTrace) {
      debugPrint('Ошибка отправки медиа $messageId: $e\n$stackTrace');
      await ChatStore.updateMessageStatus(
        widget.peerLogin,
        messageId,
        'failed',
      );
    } finally {
      await _loadHistory();
    }
  }

  /// Грузит все файлы группы на сервер, затем отправляет ОДИН зашифрованный
  /// конверт со ссылками на все файлы (+ подпись) — собеседник получает
  /// всю группу разом, а не по одному сообщению по мере загрузки.
  Future<void> _sendGroupNetwork(
    String groupId, {
    String? caption,
    String? textMessageId,
    required List<
      ({PickedMedia item, String messageId, int size, String fileName})
    >
    items,
  }) async {
    try {
      await SendLock.run(widget.peerLogin, () async {
        final token = await Session.getToken();
        final myDeviceId = await KeyStore.getStoredDeviceId();
        final state = await _ensureSessionForSending();
        final initHeader = _pendingInitHeader;
        _pendingInitHeader = null;

        final peerAccountIdForUpload =
            await PeerAccountStore.get(_currentPeerDeviceId) ??
            widget.peerAccountId;

        final files = <Map<String, dynamic>>[];
        for (final q in items) {
          files.add(
            await _uploadAndDescribeMedia(
              q.item,
              q.messageId,
              q.size,
              q.fileName,
              token!,
              peerAccountIdForUpload,
            ),
          );
        }

        for (final q in items) {
          await ChatStore.updateProcessingStep(
            widget.peerLogin,
            q.messageId,
            'Согласование с собеседником…',
          );
        }

        final inner = InnerMessage.mediaGroup(
          groupId: groupId,
          caption: caption,
          textMessageId: textMessageId,
          files: files,
        );

        final next = await state.nextSendingKey();
        await SessionStore.saveState(_currentPeerDeviceId, state);
        final encryptedEnvelope = await encryptMessage(
          next.messageKey,
          inner.encode(),
        );
        final envelope = <String, dynamic>{
          ...encryptedEnvelope,
          ...next.header,
          'sender_device_id': myDeviceId,
          if (initHeader != null) ...initHeader,
        };

        for (final q in items) {
          await ChatStore.updateProcessingStep(
            widget.peerLogin,
            q.messageId,
            'Отправка…',
          );
        }
        final status = await WebSocketService.instance.sendEnvelope(
          _currentPeerDeviceId,
          envelope,
          inner.messageId,
        );

        if (textMessageId != null) {
          await ChatStore.updateMessageStatus(
            widget.peerLogin,
            textMessageId,
            status,
          );
        }
        for (final q in items) {
          await ChatStore.updateMessageStatus(
            widget.peerLogin,
            q.messageId,
            status,
          );
        }
      });
    } catch (e, stackTrace) {
      debugPrint('Ошибка отправки группы: $e\n$stackTrace');
      if (textMessageId != null) {
        await ChatStore.updateMessageStatus(
          widget.peerLogin,
          textMessageId,
          'failed',
        );
      }
      for (final q in items) {
        await ChatStore.updateMessageStatus(
          widget.peerLogin,
          q.messageId,
          'failed',
        );
      }
    } finally {
      await _loadHistory();
    }
  }

  Future<Uint8List> _loadAndCacheMedia(StoredMessage msg) async {
    final cached = await MediaCache.read(msg.mediaId!);
    if (cached != null) return cached;

    final token = await Session.getToken();
    final ciphertext = await _apiClient.downloadEncryptedMedia(
      token!,
      msg.mediaId!,
    );
    final plainBytes = await decryptFileBytes(
      key: base64Decode(msg.mediaKeyBase64!),
      nonce: base64Decode(msg.mediaNonceBase64!),
      mac: base64Decode(msg.mediaMacBase64!),
      ciphertext: ciphertext,
    );
    await MediaCache.write(msg.mediaId!, plainBytes);
    return plainBytes;
  }

  Future<void> _downloadAndDecryptChunked(StoredMessage msg) async {
    final token = await Session.getToken();
    final tempDir = await getTemporaryDirectory();
    final cipherTempFile = File('${tempDir.path}/dl_${msg.mediaId}.enc');

    await _apiClient.downloadEncryptedMediaToFile(
      token!,
      msg.mediaId!,
      cipherTempFile,
    );

    final destFile = await MediaCache.fileFor(msg.mediaId!);
    await StreamingFileCipher.decryptFileToFile(
      inputFile: cipherTempFile,
      outputFile: destFile,
      keyBytes: base64Decode(msg.mediaKeyBase64!),
    );

    try {
      await cipherTempFile.delete();
    } catch (_) {}
  }

  Future<void> _openFile(StoredMessage msg) async {
    try {
      File sourceFile;

      if (msg.chunked) {
        if (!(await MediaCache.exists(msg.mediaId!))) {
          await _downloadAndDecryptChunked(msg);
        }
        sourceFile = await MediaCache.fileFor(msg.mediaId!);
      } else {
        final bytes = await _loadAndCacheMedia(msg);
        final tempDir = await getTemporaryDirectory();
        sourceFile = File('${tempDir.path}/tmp_${msg.mediaId}');
        await sourceFile.writeAsBytes(bytes);
      }

      final tempDir = await getTemporaryDirectory();
      final namedFile = File('${tempDir.path}/${msg.fileName ?? 'file'}');
      await sourceFile.copy(namedFile.path);

      final result = await OpenFile.open(namedFile.path);
      if (result.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось открыть файл: ${result.message}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Не удалось открыть файл: $e')));
      }
    }
  }

  Widget _buildAttachmentBubble(StoredMessage msg, {double size = 220}) {
    if (msg.isMine && (msg.status == 'sending' || msg.status == 'failed')) {
      if (msg.status == 'failed') {
        return Stack(
          children: [
            if (msg.localPreviewPath != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: size,
                  height: size,
                  child: Opacity(
                    opacity: 0.5,
                    child: Image.file(
                      File(msg.localPreviewPath!),
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              )
            else
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            const Center(
              child: Icon(
                Icons.error_outline,
                color: Colors.redAccent,
                size: 40,
              ),
            ),
          ],
        );
      }

      return Stack(
        children: [
          if (msg.localPreviewPath != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: size,
                height: size,
                child: Image.file(
                  File(msg.localPreviewPath!),
                  fit: BoxFit.cover,
                ),
              ),
            )
          else
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.insert_drive_file,
                color: Colors.white70,
                size: 40,
              ),
            ),
          if (msg.processingStep != null && size >= 150)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: const BoxDecoration(
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(14),
                    bottomRight: Radius.circular(14),
                  ),
                  color: Colors.black54,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      msg.processingStep!,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            )
          else if (msg.processingStep != null)
            const Positioned(
              right: 4,
              bottom: 4,
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      );
    }

    final isLarge = msg.fileSize >= _autoDownloadLimitBytes;

    if (!isLarge || msg.isMine) {
      return msg.isFile
          ? _clickableFileRow(msg, size: size)
          : _photoPreview(msg, size: size);
    }

    final existsFuture = _existsChecks.putIfAbsent(
      msg.mediaId!,
      () => MediaCache.exists(msg.mediaId!),
    );

    return FutureBuilder<bool>(
      future: existsFuture,
      builder: (context, existsSnapshot) {
        if (existsSnapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 40,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }

        final alreadyDownloaded = existsSnapshot.data == true;
        if (alreadyDownloaded) {
          return msg.isFile
              ? _clickableFileRow(msg, size: size)
              : _photoPreview(msg, size: size);
        }

        return _downloadPromptRow(msg);
      },
    );
  }

  Widget _downloadPromptRow(StoredMessage msg) {
    if (msg.chunked) {
      final downloading = _chunkedDownloads.containsKey(msg.mediaId);
      return InkWell(
        onTap: downloading
            ? null
            : () {
                setState(() {
                  _existsChecks.remove(msg.mediaId!);
                  _chunkedDownloads[msg.mediaId!] = _downloadAndDecryptChunked(
                    msg,
                  );
                });
              },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (downloading)
              FutureBuilder<void>(
                future: _chunkedDownloads[msg.mediaId!],
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    );
                  }
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() {});
                  });
                  return const Icon(
                    Icons.insert_drive_file,
                    color: Colors.white,
                    size: 28,
                  );
                },
              )
            else
              const Icon(Icons.download, color: Colors.white, size: 28),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    msg.fileName ?? msg.text,
                    style: const TextStyle(color: Colors.white),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  _formatFileSize(msg.fileSize),
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
      );
    }

    final isDownloading = _mediaFutures.containsKey(msg.mediaId);

    return InkWell(
      onTap: isDownloading
          ? null
          : () {
              setState(() {
                _existsChecks.remove(msg.mediaId!);
                _mediaFutures[msg.mediaId!] = _loadAndCacheMedia(msg);
              });
            },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isDownloading)
            FutureBuilder<Uint8List>(
              future: _mediaFutures[msg.mediaId!],
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  );
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() {});
                });
                return Icon(
                  msg.isFile ? Icons.insert_drive_file : Icons.image,
                  color: Colors.white,
                  size: 28,
                );
              },
            )
          else
            const Icon(Icons.download, color: Colors.white, size: 28),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  msg.isFile ? (msg.fileName ?? msg.text) : '📷 Фото',
                  style: const TextStyle(color: Colors.white),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                _formatFileSize(msg.fileSize),
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _clickableFileRow(StoredMessage msg, {double size = 220}) {
    if (size < 200) {
      return InkWell(
        onTap: () => _openFile(msg),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.insert_drive_file,
            color: Colors.white70,
            size: 32,
          ),
        ),
      );
    }
    return InkWell(
      onTap: () => _openFile(msg),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file, color: Colors.white, size: 28),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              msg.fileName ?? msg.text,
              style: const TextStyle(color: Colors.white),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// Список всех фото текущего чата (то, что реально может показать
  /// просмотрщик) в порядке появления в чате — используется и для
  /// определения стартового индекса, и как набор страниц для листания.
  List<StoredMessage> _viewablePhotos() =>
      _messages.where((m) => m.isMedia && !m.isFile).toList();

  void _openMediaViewer(StoredMessage msg) {
    final photos = _viewablePhotos();
    final index = photos.indexWhere((m) => m.messageId == msg.messageId);
    if (index == -1) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MediaViewerScreen<StoredMessage>(
          items: photos,
          initialIndex: index,
          resolveBytes: _resolvePhotoBytes,
        ),
      ),
    );
  }

  Widget _photoPreview(StoredMessage msg, {double size = 220}) {
    final double side = size;

    final cached = _resolvedMedia[msg.mediaId!];
    if (cached != null) {
      return GestureDetector(
        onTap: () => _openMediaViewer(msg),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: side,
            height: side,
            child: Image.memory(
              cached,
              fit: BoxFit.cover,
              cacheWidth: (side * 2).round(),
            ),
          ),
        ),
      );
    }

    final future = _mediaFutures.putIfAbsent(
      msg.mediaId!,
      () => _resolvePhotoBytes(msg),
    );

    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return SizedBox(
            width: side,
            height: side,
            child: const Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError || snapshot.data == null) {
          return SizedBox(
            width: side,
            height: side,
            child: const Center(
              child: Icon(Icons.broken_image, color: Colors.red),
            ),
          );
        }

        _resolvedMedia[msg.mediaId!] = snapshot.data!;

        return GestureDetector(
          onTap: () => _openMediaViewer(msg),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: side,
              height: side,
              child: Image.memory(
                snapshot.data!,
                fit: BoxFit.cover,
                cacheWidth: (side * 2).round(),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<Uint8List> _resolvePhotoBytes(StoredMessage msg) async {
    if (msg.chunked) {
      if (!(await MediaCache.exists(msg.mediaId!))) {
        await _downloadAndDecryptChunked(msg);
      }
      final file = await MediaCache.fileFor(msg.mediaId!);
      return file.readAsBytes();
    }
    return _loadAndCacheMedia(msg);
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes Б';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} КБ';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }

  String _formatCallDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }

  /// Запись о звонке рендерится отдельным, визуально нейтральным рядом
  /// по центру — не как обычный текстовый/медиа-пузырь — потому что это
  /// не сообщение от одной из сторон, а факт о звонке, который затрагивает
  /// обоих собеседников одинаково.
  Widget _buildCallLogRow(StoredMessage msg) {
    final isOutgoing = msg.callDirection == 'outgoing';
    final isMissedOrNoAnswer =
        msg.callOutcome == 'missed' || msg.callOutcome == 'no_answer';

    late final IconData icon;
    late final String label;
    switch (msg.callOutcome) {
      case 'answered':
        icon = isOutgoing ? Icons.call_made : Icons.call_received;
        label = 'Звонок · ${_formatCallDuration(msg.callDurationSeconds ?? 0)}';
        break;
      case 'missed':
        icon = Icons.call_missed;
        label = 'Пропущенный звонок';
        break;
      case 'no_answer':
      default:
        icon = Icons.call_made;
        label = 'Абонент не отвечает';
        break;
    }

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isMissedOrNoAnswer ? Colors.redAccent : Colors.white70,
            ),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: Colors.white)),
            const SizedBox(width: 6),
            Text(
              formatChatTime(msg.timestamp),
              style: const TextStyle(color: Colors.white70, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIconFor(String status) {
    switch (status) {
      case 'failed':
        return const Icon(
          Icons.error_outline,
          size: 13,
          color: Colors.redAccent,
        );
      case 'sending':
      case 'queued':
        return const Icon(Icons.schedule, size: 13, color: Colors.white70);
      default:
        return const Icon(Icons.done, size: 13, color: Colors.lightBlueAccent);
    }
  }

  /// Группирует подряд идущие сообщения с одинаковым непустым groupId —
  /// такие сообщения были отправлены одним действием пользователя
  /// (несколько файлов и/или файлы с общей подписью) и рендерятся как
  /// один визуальный альбом, хотя по факту остаются разными сообщениями.
  List<List<StoredMessage>> _groupedMessages() {
    final result = <List<StoredMessage>>[];
    var i = 0;
    while (i < _messages.length) {
      final groupId = _messages[i].groupId;
      if (groupId == null) {
        result.add([_messages[i]]);
        i++;
        continue;
      }
      final cluster = <StoredMessage>[];
      while (i < _messages.length && _messages[i].groupId == groupId) {
        cluster.add(_messages[i]);
        i++;
      }
      result.add(cluster);
    }
    return result;
  }

  Widget _buildMediaGrid(List<StoredMessage> mediaMsgs) {
    if (mediaMsgs.length == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: _buildAttachmentBubble(mediaMsgs.first, size: 180),
      );
    }
    const spacing = 3.0;
    final columns = mediaMsgs.length >= 3 ? 3 : 2;
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : columns * 110.0;
        final tileSize = ((availableWidth - spacing * (columns - 1)) / columns)
            .clamp(70.0, 130.0);
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: mediaMsgs
              .map(
                (m) => ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _buildAttachmentBubble(m, size: tileSize),
                ),
              )
              .toList(),
        );
      },
    );
  }

  Widget _buildMetaRow(StoredMessage msg) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (msg.edited) ...[
          const Icon(Icons.edit, size: 11, color: Colors.white70),
          const SizedBox(width: 3),
        ],
        Text(
          formatChatTime(msg.timestamp),
          style: const TextStyle(color: Colors.white70, fontSize: 10),
        ),
        if (msg.isMine) ...[
          const SizedBox(width: 4),
          _buildStatusIconFor(msg.status),
        ],
      ],
    );
  }

  Widget _buildSelectionCheck(bool selected, bool isMine) {
    return _SelectionCheckmark(selected: selected, isMine: isMine);
  }

  /// Реакции показываются РАЗДЕЛЬНО — своя и собеседника не сливаются в
  /// одну надпись, у каждой свой маленький "чип" (у своей — подсвеченная
  /// рамка цветом акцента, у чужой — приглушённая), и каждый чип плавно
  /// появляется/исчезает (см. _ReactionChip), а не выскакивает мгновенно.
  Widget _reactionBadges(
    String? myReaction,
    String? peerReaction,
    bool isMine,
  ) {
    if (myReaction == null && peerReaction == null)
      return const SizedBox.shrink();
    return Positioned(
      bottom: -8,
      left: isMine ? 8 : null,
      right: isMine ? null : 8,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ReactionChip(emoji: myReaction, mine: true),
          if (myReaction != null && peerReaction != null)
            const SizedBox(width: 4),
          _ReactionChip(emoji: peerReaction, mine: false),
        ],
      ),
    );
  }

  /// Оборачивает готовый пузырь: зона реакции на тап — вся ширина экрана
  /// на высоте этого сообщения (пустая часть строки по другую сторону от
  /// пузыря тоже считается "этим сообщением"), а не только сам пузырь.
  /// Тап открывает контекстное меню в ТОЧКЕ ТАПА (или переключает выбор —
  /// в режиме выбора); рядом появляется галочка выбора (слева для чужих
  /// сообщений, справа для своих), а бейдж реакции сидит поверх нижнего
  /// угла пузыря — слева, если сообщение своё, иначе справа.
  Widget _wrapInteractive(
    StoredMessage targetMsg, {
    required Widget bubble,
    required bool isMine,
    required String? myReaction,
    required String? peerReaction,
    GlobalKey? key,
    List<String>? groupMessageIds,
  }) {
    final ids = groupMessageIds ?? [targetMsg.messageId];
    final isSelected = _selectedMessageIds.contains(targetMsg.messageId);
    final content = Stack(
      clipBehavior: Clip.none,
      children: [bubble, _reactionBadges(myReaction, peerReaction, isMine)],
    );

    // Точка последнего onTapDown этого конкретного сообщения — локальная
    // переменная замыкания (своя на каждое сообщение, без гонок между
    // разными сообщениями); используется как точка появления меню, ЕСЛИ
    // тап признан одиночным.
    var tapDownPosition = Offset.zero;

    // Одиночный тап в обычном режиме не открывает меню сразу — сперва
    // ждём _doubleTapWindow: если за это время придёт ВТОРОЙ тап по тому же
    // сообщению, это двойной тап (ставит реакцию по умолчанию), и меню
    // открывать не нужно. В режиме выбора эта отсрочка не нужна — там тап
    // просто мгновенно переключает галочку.
    void handleTap() {
      if (_selectionMode) {
        _toggleGroupSelected(ids);
        return;
      }

      final now = DateTime.now();
      final isDoubleTap =
          _lastTapMessageId == targetMsg.messageId &&
          _lastTapTime != null &&
          now.difference(_lastTapTime!) < _doubleTapWindow;

      if (isDoubleTap) {
        _pendingTapTimer?.cancel();
        _pendingTapTimer = null;
        _lastTapMessageId = null;
        _lastTapTime = null;
        _applyDefaultReaction(targetMsg);
        return;
      }

      _lastTapMessageId = targetMsg.messageId;
      _lastTapTime = now;
      final anchor = tapDownPosition;
      _pendingTapTimer?.cancel();
      _pendingTapTimer = Timer(_doubleTapWindow, () {
        _lastTapMessageId = null;
        _lastTapTime = null;
        _openContextMenu(targetMsg, anchor, groupMessageIds: groupMessageIds);
      });
    }

    // Долгий тап (как в Телеграме) — сразу входит в режим выбора, с этим
    // сообщением (или всей группой) уже выбранным; если режим выбора уже
    // активен, просто переключает выбор этого сообщения/группы.
    void handleLongPress() {
      _pendingTapTimer?.cancel();
      _pendingTapTimer = null;
      _lastTapMessageId = null;
      _lastTapTime = null;
      if (_selectionMode) {
        _toggleGroupSelected(ids);
      } else {
        _enterSelectionMode(targetMsg, groupMessageIds: groupMessageIds);
      }
    }

    // Пустой распорщик, забирающий всё оставшееся место по горизонтали —
    // ЗАФИКСИРОВАННОЙ (нулевой) собственной высоты, а не "растянутый на всю
    // высоту": внутри ListView высота элемента ничем не ограничена сверху,
    // и виджет, пытающийся заполнить именно эту ось целиком (как раньше
    // делал SizedBox.expand()), получает бесконечное ограничение и падает.
    // Высоту всей строки и так задаёт сам пузырь (content) — распорщику
    // подстраиваться под неё незачем.
    const filler = Expanded(child: SizedBox.shrink());

    final row = Row(
      // .center — не .end: галочка выбора должна стоять по вертикальному
      // центру сообщения, а не липнуть к его нижнему краю (у content
      // единственного child'а с реальной высотой это никак не смещает сам
      // пузырь, потому что высота строки и так равна его высоте).
      crossAxisAlignment: CrossAxisAlignment.center,
      children: isMine
          ? [
              filler,
              content,
              if (_selectionMode) _buildSelectionCheck(isSelected, isMine),
            ]
          : [
              if (_selectionMode) _buildSelectionCheck(isSelected, isMine),
              content,
              filler,
            ],
    );

    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) => tapDownPosition = details.globalPosition,
        onTap: handleTap,
        onLongPress: handleLongPress,
        child: row,
      ),
    );
  }

  Widget _buildReplyPreview(StoredMessage msg) {
    if (msg.replyToPreview == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: Colors.white.withValues(alpha: 0.6),
            width: 3,
          ),
        ),
      ),
      child: Text(
        msg.replyToPreview!,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
    );
  }

  Widget _buildGroupBubble(List<StoredMessage> group) {
    final mediaMsgs = group.where((m) => m.isMedia).toList();
    final textMsgs = group.where((m) => !m.isMedia).toList();
    final isMine = group.first.isMine;
    final last = group.reduce((a, b) => a.timestamp >= b.timestamp ? a : b);
    final hasFailed = group.any((m) => m.status == 'failed');
    final hasPending = group.any(
      (m) => m.status == 'sending' || m.status == 'queued',
    );
    final aggregateStatus = hasFailed
        ? 'failed'
        : (hasPending ? 'sending' : 'sent');
    final maxWidth = MediaQuery.of(context).size.width * 0.72;
    final repMsg = textMsgs.isNotEmpty ? textMsgs.first : group.first;
    final key = _messageKeys.putIfAbsent(repMsg.messageId, () => GlobalKey());

    final bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(6),
      constraints: BoxConstraints(maxWidth: maxWidth),
      decoration: BoxDecoration(
        color: isMine ? AppColors.primary : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (mediaMsgs.isNotEmpty) _buildMediaGrid(mediaMsgs),
              if (textMsgs.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                  child: Text(
                    textMsgs.first.text,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                formatChatTime(last.timestamp),
                style: const TextStyle(color: Colors.white70, fontSize: 10),
              ),
              if (isMine) ...[
                const SizedBox(width: 4),
                _buildStatusIconFor(aggregateStatus),
              ],
            ],
          ),
        ],
      ),
    );

    return KeyedSubtree(
      key: ValueKey(group.first.groupId),
      child: _wrapInteractive(
        repMsg,
        bubble: bubble,
        isMine: isMine,
        myReaction: repMsg.myReaction,
        peerReaction: repMsg.peerReaction,
        key: key,
        groupMessageIds: group.map((m) => m.messageId).toList(),
      ),
    );
  }

  Widget _buildMessageBubble(StoredMessage msg) {
    if (msg.isCallLog) {
      return KeyedSubtree(
        key: ValueKey(msg.messageId),
        child: _buildCallLogRow(msg),
      );
    }
    final maxTextWidth = MediaQuery.of(context).size.width * 0.65;
    final key = _messageKeys.putIfAbsent(msg.messageId, () => GlobalKey());

    final bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: msg.isMine ? AppColors.primary : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildReplyPreview(msg),
          msg.isMedia
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildAttachmentBubble(msg),
                    const SizedBox(height: 4),
                    _buildMetaRow(msg),
                  ],
                )
              // Text.rich с временем/статусом как WidgetSpan В КОНЦЕ текста
              // (а не рядом в отдельном Row) — время участвует в переносе
              // строк наравне со словами: если хватает места на последней
              // строке, садится туда, иначе уходит на свою строку. Раньше
              // Row(text, время) считал ширину пузыря как max(самая длинная
              // строка) + время, и это "время" добавлялось лишним пустым
              // хвостом ко ВСЕМ строкам короче самой длинной — этот хвост
              // и был той самой "слишком большой пустотой справа".
              : ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxTextWidth),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: msg.text,
                          style: const TextStyle(color: Colors.white),
                        ),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: _buildMetaRow(msg),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ],
      ),
    );

    return KeyedSubtree(
      key: ValueKey(msg.messageId),
      child: _wrapInteractive(
        msg,
        bubble: bubble,
        isMine: msg.isMine,
        myReaction: msg.myReaction,
        peerReaction: msg.peerReaction,
        key: key,
      ),
    );
  }

  @override
  void dispose() {
    _pendingTapTimer?.cancel();
    _scrollSaveDebounce?.cancel();
    if (ActiveChatTracker.currentPeerLogin == widget.peerLogin) {
      ActiveChatTracker.currentPeerLogin = null;
    }
    if (_scrollController.hasClients) {
      // fire-and-forget — dispose() синхронный, а виджет уже уходит из
      // дерева; запись переживёт unmount, поскольку не ссылается ни на
      // context, ни на что-либо ещё, привязанное к жизни этого State. Это
      // просто последний "добивочный" flush — основной путь сохранения
      // теперь в _handleScroll (debounce на каждую остановку скролла), на
      // случай если dispose() вообще не вызовется (например, приложение
      // убили из диспетчера задач, пока чат был открыт).
      unawaited(
        ChatScrollPositionStore.set(widget.peerLogin, _scrollController.offset),
      );
    }
    _scrollController.removeListener(_handleScroll);
    _textFocusNode.removeListener(_onFocusChange);
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    _textFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Widget _buildPinnedBanner() {
    final pinnedId = _pinnedMessageId;
    if (pinnedId == null) return const SizedBox.shrink();
    final matches = _messages.where((m) => m.messageId == pinnedId).toList();
    final preview = matches.isNotEmpty
        ? (matches.first.isMedia
              ? (matches.first.isFile ? '📎 Файл' : '📷 Фото')
              : matches.first.text)
        : 'Закреплённое сообщение';
    return InkWell(
      onTap: () => _scrollToMessage(pinnedId),
      child: Container(
        width: double.infinity,
        color: AppColors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.push_pin, size: 16, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                preview,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bannerRow({
    required IconData icon,
    required String text,
    required VoidCallback onClose,
  }) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: AppColors.textMuted),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }

  Widget _buildComposerBanner() {
    if (_editingMessage != null) {
      return _bannerRow(
        icon: Icons.edit,
        text: 'Редактирование сообщения',
        onClose: _cancelEdit,
      );
    }
    if (_replyTarget != null) {
      final target = _replyTarget!;
      final preview = target.isMedia
          ? (target.isFile ? '📎 Файл' : '📷 Фото')
          : target.text;
      return _bannerRow(
        icon: Icons.reply,
        text: 'Ответить: $preview',
        onClose: _cancelReply,
      );
    }
    final forwarding = _forwardingTexts;
    if (forwarding != null && forwarding.isNotEmpty) {
      return _bannerRow(
        icon: Icons.forward,
        text: 'Количество пересылаемых сообщений: ${forwarding.length}',
        onClose: () => setState(() => _forwardingTexts = null),
      );
    }
    return const SizedBox.shrink();
  }

  /// Общая точка для системного back (см. PopScope) — в режиме выбора
  /// снимает выбор, при открытой только эмодзи-панели закрывает её, иначе
  /// уходит из чата. Интерактивный свайп-назад из любой точки экрана
  /// сознательно НЕ реализован отдельным жестом — он конфликтовал бы за
  /// одни и те же горизонтальные тачи с нативным edge-свайпом
  /// CupertinoPageRoute (см. навигацию к ChatScreen), который уже даёт
  /// живой, управляемый пальцем переход, просто только от края экрана.
  void _handleBackAction({required bool emojiPanelOnlyVisible}) {
    if (_selectionMode) {
      _exitSelectionMode();
    } else if (emojiPanelOnlyVisible) {
      setState(() {
        _emojiMode = false;
        _targetReserve = 0;
      });
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final realInset = MediaQuery.of(context).viewInsets.bottom;
    final keyboardVisible = realInset > 50;

    if (keyboardVisible && realInset > _keyboardHeight + 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _keyboardHeight = realInset);
        KeyboardHeightStore.updateKnownHeight(realInset);
      });
    }

    // Once realInset catches up to our held target — the real keyboard has
    // fully replaced the emoji panel we were holding space for — release the
    // hold and go back to live-tracking realInset directly.
    if (_switchingMode && !_emojiMode && realInset >= _targetReserve - 4) {
      _switchingMode = false;
    }

    // Резерв места либо ЖИВЬЁМ зеркалит настоящую клавиатуру (обычная печать,
    // системный back и т.п. — realInset уже несёт в себе анимацию самой ОС,
    // повторно анимировать поверх неё не нужно и вредно — именно это давало
    // эффект "резинки"/отставания), либо, во время наших СОБСТВЕННЫХ
    // переключений на эмодзи-панель и обратно (когда реальной анимации ОС,
    // на которую можно опереться, нет), держится на зафиксированной высоте.
    final isLiveTracking = !_emojiMode && !_switchingMode;
    final emojiPanelOnlyVisible = !keyboardVisible && _emojiMode;
    final reserved = isLiveTracking ? realInset : _targetReserve;

    // Клавиатура/эмодзи-панель растут снизу и СЖИМАЮТ видимую область
    // списка сообщений (Scaffold сам не резайзится, resizeToAvoidBottomInset
    // выключен намеренно, см. выше) — если пользователь и так был внизу
    // чата, съехавший вверх последний ряд сообщений нужно снова прокрутить
    // в видимую зону, иначе клавиатура визуально "накрывает" их.
    if (_initialLoadComplete && reserved > _lastReserved + 4 && _userAtBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
    _lastReserved = reserved;

    return PopScope(
      canPop: !emojiPanelOnlyVisible && !_selectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBackAction(emojiPanelOnlyVisible: emojiPanelOnlyVisible);
      },
      child: SwipeBackDetector(
        enabled: !emojiPanelOnlyVisible && !_selectionMode,
        onBlockedSwipe: () =>
            _handleBackAction(emojiPanelOnlyVisible: emojiPanelOnlyVisible),
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          appBar: _selectionMode
              ? AppBar(
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: _exitSelectionMode,
                  ),
                  title: Text('Выбрано: ${_selectedMessageIds.length}'),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.copy_outlined),
                      onPressed: _selectedMessageIds.isEmpty
                          ? null
                          : _copySelectedTexts,
                    ),
                    IconButton(
                      icon: const Icon(Icons.forward_outlined),
                      onPressed: _selectedMessageIds.isEmpty
                          ? null
                          : () => _openForward(_selectedTexts()),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: _selectedMessageIds.isEmpty
                          ? null
                          : () => _deleteMessages(_selectedMessageIds.toList()),
                    ),
                  ],
                )
              : AppBar(
                  title: Text(
                    _isPeerDeleted ? 'Удалённый аккаунт' : widget.peerLogin,
                  ),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.call_outlined),
                      iconSize: 26,
                      padding: const EdgeInsets.all(14),
                      constraints: const BoxConstraints(
                        minWidth: 56,
                        minHeight: 56,
                      ),
                      onPressed: _isPeerDeleted ? null : _startCall,
                    ),
                  ],
                ),
          body: Column(
            children: [
              OngoingCallBanner(peerLogin: widget.peerLogin),
              if (_pinnedMessageId != null) _buildPinnedBanner(),
              Expanded(
                // Список не строится, пока _bootstrapHistory() не узнает
                // сохранённую позицию — иначе он БЫ построился с нуля,
                // пользователь увидел бы это на один кадр, и только потом
                // прыгнул бы туда, где был (тот самый "мигает" баг).
                // Пустая область на эти несколько миллисекунд куда менее
                // заметна, чем видимый прыжок по уже отрисованному списку.
                child: !_scrollReady
                    ? const SizedBox.shrink()
                    : Builder(
                        builder: (context) {
                          final groups = _groupedMessages();
                          return ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.all(16),
                            itemCount: groups.length,
                            itemBuilder: (context, index) {
                              final group = groups[index];
                              return group.length == 1
                                  ? _buildMessageBubble(group.first)
                                  : _buildGroupBubble(group);
                            },
                          );
                        },
                      ),
              ),
              _buildComposerBanner(),
              SafeArea(
                top: false,
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Row(
                      children: [
                        IconButton(
                          padding: const EdgeInsets.all(6),
                          constraints: const BoxConstraints(),
                          visualDensity: VisualDensity.compact,
                          icon: Icon(
                            emojiPanelOnlyVisible
                                ? Icons.keyboard
                                : Icons.emoji_emotions_outlined,
                            color: AppColors.textMuted,
                          ),
                          onPressed: () {
                            if (emojiPanelOnlyVisible) {
                              // Реальная клавиатура ещё не поднялась — держим
                              // резерв на месте (_switchingMode), пока realInset
                              // органически не догонит цель, иначе между
                              // "спрятали эмодзи" и "клавиатура ещё не встала"
                              // мелькнёт пустота.
                              _switchingMode = true;
                              setState(() => _emojiMode = false);
                              _textFocusNode.requestFocus();
                            } else {
                              _switchingMode = true;
                              _textFocusNode.unfocus();
                              setState(() {
                                _emojiMode = true;
                                _targetReserve = _keyboardHeight;
                              });
                            }
                          },
                        ),
                        const SizedBox(width: 2),
                        Expanded(
                          child: TextField(
                            controller: _textController,
                            focusNode: _textFocusNode,
                            onTap: () {
                              if (_emojiMode)
                                setState(() => _emojiMode = false);
                            },
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                            ),
                            decoration: const InputDecoration(
                              hintText: 'Сообщение',
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                vertical: 12,
                              ),
                              hintStyle: TextStyle(color: AppColors.textMuted),
                            ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        if (_editingMessage != null)
                          IconButton(
                            padding: const EdgeInsets.all(6),
                            constraints: const BoxConstraints(),
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(
                              Icons.send,
                              color: AppColors.primary,
                            ),
                            onPressed: _hasText ? _handleSendPressed : null,
                          )
                        else if (_hasText ||
                            (_forwardingTexts?.isNotEmpty ?? false))
                          IconButton(
                            padding: const EdgeInsets.all(6),
                            constraints: const BoxConstraints(),
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(
                              Icons.send,
                              color: AppColors.primary,
                            ),
                            onPressed: _handleSendPressed,
                          )
                        else ...[
                          IconButton(
                            padding: const EdgeInsets.all(6),
                            constraints: const BoxConstraints(),
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(
                              Icons.attach_file,
                              color: AppColors.textMuted,
                            ),
                            onPressed: _openAttachmentSheet,
                          ),
                          IconButton(
                            padding: const EdgeInsets.all(6),
                            constraints: const BoxConstraints(),
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(
                              Icons.mic,
                              color: AppColors.textMuted,
                            ),
                            onPressed: () {},
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              AnimatedContainer(
                duration: isLiveTracking
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                height: reserved,
                color: AppColors.surface,
                child: reserved > 0
                    ? ClipRect(
                        child: RepaintBoundary(
                          child: FullEmojiPicker(
                            onEmojiSelected: (emoji) {
                              _textController.text += emoji;
                            },
                          ),
                        ),
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Галочка выбора сообщения — при первом появлении (переход в режим
/// выбора) влетает с соответствующего края экрана: для своих сообщений
/// с ПРАВОГО края, для чужих — с ЛЕВОГО, а не выскакивает мгновенно.
class _SelectionCheckmark extends StatefulWidget {
  final bool selected;
  final bool isMine;

  const _SelectionCheckmark({required this.selected, required this.isMine});

  @override
  State<_SelectionCheckmark> createState() => _SelectionCheckmarkState();
}

class _SelectionCheckmarkState extends State<_SelectionCheckmark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final startDx = widget.isMine ? screenWidth : -screenWidth;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_controller.value);
        return Transform.translate(
          offset: Offset(startDx * (1 - t), 0),
          child: child,
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Icon(
          widget.selected ? Icons.check_circle : Icons.radio_button_unchecked,
          color: widget.selected ? AppColors.primary : AppColors.textMuted,
          size: 22,
        ),
      ),
    );
  }
}

/// Один "чип" реакции — плавно масштабируется при появлении/исчезновении/
/// смене эмодзи (см. AnimatedSwitcher внутри), а не появляется рывком.
/// mine=true — своя реакция (рамка цветом акцента), false — реакция
/// собеседника (приглушённая рамка).
class _ReactionChip extends StatelessWidget {
  final String? emoji;
  final bool mine;

  const _ReactionChip({required this.emoji, required this.mine});

  @override
  Widget build(BuildContext context) {
    final accent = mine ? AppColors.primary : AppColors.textMuted;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      transitionBuilder: (child, anim) => ScaleTransition(
        scale: CurvedAnimation(parent: anim, curve: Curves.easeOutBack),
        child: FadeTransition(opacity: anim, child: child),
      ),
      child: emoji == null
          ? const SizedBox.shrink(key: ValueKey('_empty'))
          : Container(
              key: ValueKey('${mine}_$emoji'),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: accent, width: 1.4),
              ),
              child: Text(emoji!, style: const TextStyle(fontSize: 13)),
            ),
    );
  }
}
