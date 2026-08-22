import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback, KeyboardInsertedContent;
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api/api_client.dart';
import '../crypto/double_ratchet.dart';
import '../crypto/key_store.dart';
import '../crypto/media_cipher.dart';
import '../crypto/message_cipher.dart';
import '../crypto/message_envelope.dart';
import '../crypto/session_store.dart';
import '../crypto/streaming_file_cipher.dart';
import '../crypto/x3dh.dart';
import '../l10n/app_strings.dart';
import '../models/picked_media.dart';
import '../screens/call_screen.dart';
import '../screens/camera_capture_screen.dart';
import '../screens/media_viewer_screen.dart';
import '../services/active_chat_tracker.dart';
import '../widgets/cached_avatar_image.dart';
import '../services/call_service.dart';
import '../services/chat_scroll_position_store.dart';
import '../services/debug_log.dart';
import '../services/keyboard_height_store.dart';
import '../services/media_asset_cache.dart';
import '../services/my_avatar_store.dart';
import '../services/send_lock.dart';
import '../services/send_queue_processor.dart';
import '../services/websocket_service.dart';
import '../session.dart';
import '../storage/chat_store.dart';
import '../storage/media_cache.dart';
import '../storage/peer_account_store.dart';
import '../storage/peer_identity_store.dart';
import '../theme/app_theme.dart';
import '../utils/presence_format.dart';
import '../utils/time_format.dart';
import '../storage/default_reaction_store.dart';
import '../widgets/attach_launcher_overlay.dart';
import '../widgets/avatar_settings_tile.dart' show AvatarThumbnail;
import '../widgets/delete_message_dialog.dart';
import '../widgets/full_emoji_picker.dart';
import '../widgets/media_picker_sheet.dart';
import '../widgets/message_context_menu.dart';
import '../widgets/ongoing_call_banner.dart';
import '../widgets/particle_shatter_overlay.dart';
import '../widgets/hero_zoom_page_route.dart';
import '../widgets/report_message_dialog.dart';
import '../widgets/swipe_back_page_route.dart';
import '../widgets/theme_reactive.dart';
import '../widgets/video_note_player.dart';
import '../widgets/voice_message_player.dart';
import 'forward_screen.dart';
import 'peer_profile_screen.dart';

enum _RecKind { voice, video }

enum _RecPhase { idle, dragging, locked }

// Пузырь СВОЕГО сообщения всегда AppColors.primary (фиксированный синий,
// одинаковый в обеих темах) — на нём белый текст корректен всегда. Пузырь
// ЧУЖОГО — AppColors.surface, а он теперь цвет темы (белый в светлой!) —
// когда-то жёстко зашитый белый текст поверх такого пузыря в светлой теме
// становился белым по белому, невидимым. Эти два хелпера — единая точка,
// откуда весь контент пузыря (текст, время, иконки вложений) берёт цвет
// в зависимости от того, чей это пузырь.
Color _bubbleTextColor(bool isMine) =>
    isMine ? Colors.white : AppColors.textPrimary;
Color _bubbleMutedColor(bool isMine) =>
    isMine ? Colors.white70 : AppColors.textMuted;
// Ссылка не должна сливаться ни с фоном пузыря, ни с обычным текстом на
// нём — на своих (синих) пузырях обычный светло-голубой акцент почти не
// отличим от фона, поэтому там нужен контрастный жёлтый, а не тот же
// оттенок синего.
Color _linkColor(bool isMine) =>
    isMine ? const Color(0xFFFFD54F) : const Color(0xFF2AABEE);

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
  // Голосовые — без ограничения по времени, только видео-кружочки: у них
  // заметно тяжелее байт на секунду (видео+аудио), и на них же завязан
  // enablePersistentRecording, который держит файл открытым всё время
  // записи (см. _beginRecording).
  static const Duration _maxVideoNoteDuration = Duration(minutes: 5);

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
  // См. _loadKnownDeletedStatus/ChatSummary.blockedByMe/.blockingMe —
  // определяют, какая из двух приоритетных надписей (если вообще) заменяет
  // панель ввода целиком (см. _buildComposer/_buildBlockedPlaceholder).
  bool _blockedByMe = false;
  bool _blockingMe = false;
  bool _userAtBottom = true;
  bool _initialLoadComplete = false;
  int _lastMessageCount = 0;
  Timer? _scrollSaveDebounce;

  bool _emojiMode = false;
  double _keyboardHeight = 280;
  static const _keyboardHeightSettleDelay = Duration(milliseconds: 180);
  Timer? _keyboardHeightSettleTimer;
  // См. build(): держит anyPanelOpen=true на те несколько кадров между
  // тапом по иконке клавиатуры (переключение из эмодзи-режима) и моментом,
  // когда настоящая клавиатура реально поднимется и realInset это заметит.
  bool _awaitingKeyboardOpen = false;
  bool _hasText = false;
  double _lastReserved = 0;
  double? _lastLoggedBottomInset;

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

  // Контекстное меню сообщения теперь показывается через Overlay, а не
  // через Navigator route (см. showMessageContextMenu) — само по себе оно
  // больше не участвует в системном back. Пока меню открыто, здесь лежит
  // его функция анимированного закрытия — PopScope ниже (canPop) и
  // _handleBackAction используют её, чтобы системная кнопка "назад"
  // сначала закрывала меню, а не сразу уходила из чата.
  VoidCallback? _closeContextMenu;

  final Map<String, GlobalKey> _messageKeys = {};
  // ids всей группы (или [id] для одиночного сообщения), по тому же ключу,
  // что и _messageKeys — см. handleLongPressMoveUpdate в _wrapInteractive:
  // непрерывная протяжка пальца по другим сообщениям без отрыва должна
  // выделять/снимать выделение с них тоже, а не только с исходного.
  final Map<String, List<String>> _groupIdsByRepId = {};
  String? _dragSelectLastHoverId;

  // Ключи RepaintBoundary вокруг пузыря каждого сообщения (по тому же
  // представительскому id, что и _messageKeys) — используются только для
  // снимка изображения перед particle-shatter анимацией удаления, см.
  // _captureShatterImages в _deleteMessages.
  final Map<String, GlobalKey> _shatterBoundaryKeys = {};

  // Представительские id пузырей, которые прямо сейчас "растворяются" в
  // частицах (см. _deleteMessages) — такой пузырь ещё числится в
  // _messages/списке (место в ленте не схлопывается раньше времени), но
  // рисуется невидимым (Opacity 0, см. _wrapInteractive): сам эффект летит
  // поверх, ровно на его месте.
  final Set<String> _dissolvingMessageIds = {};

  // Живой статус собеседника (онлайн/офлайн/печатает), см. _handlePresenceEvent
  // — null, пока сервер ещё не ответил на подписку (presence_subscribe).
  bool? _peerOnline;
  int? _peerLastSeenMs;
  bool _peerTyping = false;
  Timer? _peerTypingClearTimer;
  StreamSubscription<Map<String, dynamic>>? _presenceSub;
  StreamSubscription<ConnectionStatus>? _wsStatusSub;
  StreamSubscription<void>? _blockStatusSub;
  Timer? _presenceTickTimer;
  DateTime? _lastTypingSentAt;

  // Голосовые/видео-сообщения (запись) — см. _beginRecording и всё, что
  // рядом. _recCameraSelected — какая иконка сейчас показана в состоянии
  // покоя (false=микрофон, true=камера), переключается одиночным тапом.
  final _audioRecorder = AudioRecorder();
  List<CameraDescription> _availableCameras = [];
  CameraController? _recCameraController;
  CameraLensDirection _recLensDirection = CameraLensDirection.front;
  static const _recordButtonKey = ValueKey('record_control_button');
  // Настоящее положение панели ввода на экране (см. _buildVideoLivePreview
  // и _buildFlipCameraButton) — измеряется через RenderBox, а не
  // пересчитывается вручную из reserved/банеров/etc., чтобы автоматически
  // учитывать ЛЮБОЕ их текущее сочетание (открытая клавиатура, баннер
  // ответа/редактирования и т.п.). _bodyStackKey — точка отсчёта: body
  // Scaffold'а начинается НЕ с абсолютного верха экрана (выше есть AppBar),
  // так что нужно всегда мерить позицию панели ОТНОСИТЕЛЬНО этого Stack'а
  // (передавая его как ancestor в localToGlobal), а не в абсолютных
  // координатах экрана — иначе высота AppBar'а лишний раз прибавляется,
  // и всё, что позиционируется от неё, уезжает вниз.
  final _composerAreaKey = GlobalKey();
  final _bodyStackKey = GlobalKey();

  bool _recCameraSelected = false;
  // Независимое от жеста отслеживание "палец реально ещё на кнопке" (см.
  // Listener в _buildRecordControlButton) — при первом долгом тапе после
  // установки приложения система показывает диалог разрешения на
  // микрофон/камеру ПРЯМО ПОСЕРЕДИНЕ долгого тапа. Диалог перехватывает
  // палец, и когда пользователь его отпускает, чтобы нажать "Разрешить",
  // Flutter никогда не получает onLongPressEnd для уже начатого жеста —
  // без этого флага _beginRecording() после await разрешения молча уходил
  // бы в _RecPhase.dragging, как будто палец всё ещё держит кнопку, и
  // единственный выход (свайп влево) тоже не работал, потому что тот же
  // GestureDetector считает предыдущий жест ещё не завершённым.
  bool _recPointerDown = false;
  _RecPhase _recPhase = _RecPhase.idle;
  _RecKind? _recActiveKind;
  DateTime? _recStartedAt;
  Duration _recElapsed = Duration.zero;
  Timer? _recTicker;
  String? _recAudioPath;
  // Текущее смещение пальца во время dragging — только для визуальной
  // обратной связи (см. _buildRecordingLockIndicator/_buildRecordingComposerChildren):
  // чем ближе к порогу (замочек/отмена), тем заметнее реагируют иконка и
  // подсказка, а не просто щелчок по достижении порога.
  Offset _recDragOffset = Offset.zero;

  // Ручное распознавание одиночный/двойной тап по сообщению (см.
  // _wrapInteractive): единственный тап откладывает открытие контекстного
  // меню на _doubleTapWindow — если за это время придёт второй тап по тому
  // же сообщению, это двойной тап (реакция по умолчанию), а не одиночный.
  static const _doubleTapWindow = Duration(milliseconds: 220);
  Timer? _pendingTapTimer;
  String? _lastTapMessageId;
  DateTime? _lastTapTime;

  /// "Заметки" — переписка с самим собой (см. notesPeerLogin в
  /// chat_store.dart): тот же ChatScreen, но без настоящего собеседника —
  /// весь Double Ratchet/сетевой обмен ниже нужно пропускать, оставляя
  /// только локальное сохранение в ChatStore и (для медиа) загрузку на
  /// MinIO под собственным account id.
  bool get _isNotes => widget.peerLogin == notesPeerLogin;

  /// Панель ввода целиком заменяется заглушкой, если блокировка есть хоть
  /// в одну сторону (см. _blockedByMe/_blockingMe и приоритет текста в
  /// chat.blockedByMe/chat.blockingMe — если обе стороны заблокировали
  /// друг друга, показывается именно первый приоритет).
  bool get _composerBlocked => _blockedByMe || _blockingMe;

  /// Три возможных формулировки, а не две — если блокировка взаимная,
  /// показываем отдельный, третий текст, а не приоритет 1 (см. правку по
  /// итогам ручного тестирования: изначально при взаимной блокировке
  /// молча показывался приоритет 1, что и является правильным поведением
  /// ТОЛЬКО когда блокировка не взаимная).
  String get _blockedComposerText {
    if (_blockedByMe && _blockingMe) return tr('chat.blockedMutual');
    if (_blockedByMe) return tr('chat.blockedByMe');
    return tr('chat.blockingMe');
  }

  // Поиск по истории чата — целиком клиентская функция (вся история и так
  // уже расшифрована и лежит в _messages, см. ChatStore), никакого похода
  // на сервер не требуется. _searchMatches ниже пересчитывается на лету из
  // _messages при каждой перестройке — истории редко бывает настолько
  // много, чтобы это стало заметно дороже, чем сам ре-рендер списка.
  bool _searchMode = false;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  String _searchQuery = '';
  // Индекс ТЕКУЩЕГО совпадения внутри _searchMatches (0-based) — тот самый
  // "N1" в счётчике "N1/N2" на панели поиска.
  int _currentMatchIndex = 0;
  // false — режим "chat" (кнопки Show as list / переход по совпадениям
  // видны), true — режим "list" (справа кнопка "Show as chat").
  bool _searchShowAsList = false;
  String? _highlightedMessageId;

  List<StoredMessage> get _searchMatches {
    if (_searchQuery.isEmpty) return const [];
    final q = _searchQuery.toLowerCase();
    return _messages
        .where((m) => !m.isCallLog && m.text.toLowerCase().contains(q))
        .toList();
  }

  int get _searchTotalCount => _searchQuery.isEmpty
      ? _messages.where((m) => !m.isCallLog).length
      : _searchMatches.length;

  int get _searchCurrentNumber {
    if (_searchQuery.isEmpty) return _searchTotalCount > 0 ? 1 : 0;
    final matches = _searchMatches;
    if (matches.isEmpty) return 0;
    return _currentMatchIndex.clamp(0, matches.length - 1) + 1;
  }

  void _enterSearchMode() {
    setState(() {
      _searchMode = true;
      _searchQuery = '';
      _currentMatchIndex = 0;
      _searchShowAsList = false;
    });
    _searchController.clear();
  }

  void _exitSearchMode() {
    _searchFocusNode.unfocus();
    setState(() {
      _searchMode = false;
      _searchShowAsList = false;
      _highlightedMessageId = null;
    });
  }

  void _onSearchQueryChanged(String value) {
    setState(() {
      _searchQuery = value;
      _currentMatchIndex = 0;
    });
    if (value.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToSearchMatch());
    }
  }

  void _searchGoNext() {
    final matches = _searchMatches;
    if (matches.isEmpty) return;
    setState(
      () => _currentMatchIndex = (_currentMatchIndex + 1) % matches.length,
    );
    _jumpToSearchMatch();
  }

  void _searchGoPrev() {
    final matches = _searchMatches;
    if (matches.isEmpty) return;
    setState(
      () => _currentMatchIndex =
          (_currentMatchIndex - 1 + matches.length) % matches.length,
    );
    _jumpToSearchMatch();
  }

  void _jumpToSearchMatch() {
    final matches = _searchMatches;
    if (matches.isEmpty || _currentMatchIndex >= matches.length) return;
    final target = matches[_currentMatchIndex];
    _scrollToMessage(target.messageId);
    _flashHighlight(target.messageId);
  }

  /// Подсветка пузыря, к которому только что перенесло поиском/закрепом —
  /// без неё "анимированный переход" (см. спецификацию) выглядел бы просто
  /// как скролл в случайное место без объяснения, куда именно и почему.
  /// Держится, пока пользователь не перейдёт к другому совпадению (тогда
  /// подсветка просто переезжает на новый messageId) или не выйдет из
  /// поиска (см. _exitSearchMode) — НЕ по таймеру: непрерывная пульсация
  /// (см. _PulsingHighlight) должна идти бесконечно, а не пару раз мигнуть
  /// и погаснуть сама по себе.
  void _flashHighlight(String messageId) {
    setState(() => _highlightedMessageId = messageId);
  }

  void _selectSearchResult(StoredMessage msg) {
    final idx = _searchMatches.indexWhere((m) => m.messageId == msg.messageId);
    setState(() {
      _searchShowAsList = false;
      if (idx != -1) _currentMatchIndex = idx;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToSearchMatch());
  }

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
    unawaited(_refreshBlockStatusFromServer());
    // Живой сигнал "кто-то поменял блокировку" (см. notifyBlockStatusChanged
    // на сервере) — пока этот чат открыт, композер-заглушка должна
    // появиться/исчезнуть сразу, а не только при повторном заходе в чат.
    _blockStatusSub = WebSocketService.instance.blockStatusEvents.listen(
      (_) => unawaited(_refreshBlockStatusFromServer()),
    );
    ChatStore.changes.listen((_) {
      _loadHistory();
      _loadKnownDeletedStatus();
    });
    KeyboardHeightStore.getKnownHeight().then((height) {
      if (mounted) setState(() => _keyboardHeight = height);
    });
    if (!_isNotes) {
      _subscribePeerPresence();
      _presenceSub = WebSocketService.instance.presenceEvents.listen(
        _handlePresenceEvent,
      );
      // Пересоздавшееся соединение (после обрыва сети и т.п.) не помнит,
      // что нас надо было переподписать — сервер отвечает актуальным
      // статусом только В МОМЕНТ подписки, поэтому подписываемся заново на
      // каждое новое "connected".
      _wsStatusSub = WebSocketService.instance.statusUpdates.listen((status) {
        if (status == ConnectionStatus.connected) _subscribePeerPresence();
      });
      // "N минут назад" должно само устаревать по часам, даже если больше
      // никаких событий от собеседника не приходит — просто перерисовываем
      // текст статуса раз в полминуты, дешевле не завязываться на точный
      // момент смены "0 → 1 минуту назад".
      _presenceTickTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _subscribePeerPresence() {
    WebSocketService.instance.subscribePresence(_currentPeerDeviceId);
  }

  void _handlePresenceEvent(Map<String, dynamic> event) {
    if (event['FromDeviceId'] != _currentPeerDeviceId) return;
    final type = event['Type'] as String?;

    if (type == 'presence') {
      final online = event['Online'] as bool? ?? false;
      final lastSeenMs = (event['LastSeenMs'] as num?)?.toInt() ?? 0;
      if (!mounted) return;
      setState(() {
        _peerOnline = online;
        _peerLastSeenMs = lastSeenMs;
        // Собеседник только что появился в сети — значит, точно не
        // "печатает" из предыдущей сессии; свежий "typing" при необходимости
        // придёт отдельным кадром следом.
        if (online) _peerTyping = false;
      });
      return;
    }

    if (type == 'typing') {
      _peerTypingClearTimer?.cancel();
      if (mounted) setState(() => _peerTyping = true);
      // Явного "закончил печатать" от сервера нет (чистый relay) — считаем,
      // что печать закончилась, если новый пинг не пришёл в течение
      // разумного окна (как в Телеграме/WhatsApp).
      _peerTypingClearTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _peerTyping = false);
      });
    }
  }

  // Троттлинг исходящих "печатает" — шлём не чаще раза в 3 секунды, а не на
  // каждое нажатие клавиши: получателю всё равно не нужна такая точность,
  // а трафика/будильников в его WS-обработчике становится на порядок меньше.
  void _maybeSendTyping() {
    if (_isNotes) return;
    final now = DateTime.now();
    if (_lastTypingSentAt != null &&
        now.difference(_lastTypingSentAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastTypingSentAt = now;
    WebSocketService.instance.sendTyping(_currentPeerDeviceId);
  }

  void _onFocusChange() {
    // Резерв места (reserved в build()) сам вычисляется на лету из
    // keyboardVisible/_emojiMode на каждой перестройке — здесь нужно
    // только не дать эмодзи-панели остаться включённой, если фокус
    // получило текстовое поле (например, реальная клавиатура поднялась
    // не через нашу кнопку, а как-то иначе).
    if (_textFocusNode.hasFocus && _emojiMode) {
      setState(() => _emojiMode = false);
    }
  }

  void _onTextChanged() {
    final hasText = _textController.text.trim().isNotEmpty;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
    }
    if (hasText) _maybeSendTyping();
  }

  Future<void> _loadKnownDeletedStatus() async {
    final peers = await ChatStore.getKnownPeers();
    final match = peers.where((p) => p.peerLogin == widget.peerLogin);
    if (match.isNotEmpty && mounted) {
      setState(() {
        _isPeerDeleted = match.first.isDeleted;
        _pinnedMessageId = match.first.pinnedMessageId;
        _blockedByMe = match.first.blockedByMe;
        _blockingMe = match.first.blockingMe;
      });
    }
  }

  /// Локальный кэш блокировки (ChatSummary.blockedByMe/.blockingMe,
  /// заполняется через ChatStore.syncBlockedFromServer) синхронизируется с
  /// сервером ТОЛЬКО раз при старте приложения (см. _syncBlockedContacts в
  /// home_placeholder_screen.dart) — если собеседник заблокировал нас, пока
  /// приложение уже было запущено, локальный кэш до следующего перезапуска
  /// оставался бы устаревшим: композер продолжал бы выглядеть обычным, хотя
  /// сервер сообщения уже не пропускает (сам факт недоставки — не баг, см.
  /// проверку в websocket.go, но пользователь должен узнать об этом сразу,
  /// открыв чат, а не наткнуться на молча пропавшее сообщение). Поэтому при
  /// каждом открытии конкретного чата спрашиваем сервер напрямую, в обход
  /// локального кэша.
  Future<void> _refreshBlockStatusFromServer() async {
    if (_isNotes) return;
    try {
      final token = await Session.getToken();
      if (token == null) return;
      final blocked = await _apiClient.getBlockedContacts(token);
      if (blocked == null) return;
      if (mounted) {
        setState(() {
          _blockedByMe = blocked.blockedByMe.contains(widget.peerAccountId);
          _blockingMe = blocked.blockingMe.contains(widget.peerAccountId);
        });
      }
      // Заодно освежаем общий локальный кэш (список чатов/меню), раз уже
      // сходили на сервер — без этого он бы обновился только при следующем
      // перезапуске приложения.
      unawaited(
        ChatStore.syncBlockedFromServer(
          blocked.blockedByMe.toSet(),
          blocked.blockingMe.toSet(),
        ),
      );
    } catch (_) {
      // Не удалось — остаёмся с тем, что уже успело прийти из локального
      // кэша (см. _loadKnownDeletedStatus), не критично.
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
    unawaited(_maybeSendReadReceipts());

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
    unawaited(_maybeSendReadReceipts());

    if (_initialLoadComplete && _userAtBottom && countChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  /// Открытие чата (и любое последующее обновление истории, пока он
  /// открыт) считается "увидел все входящие сообщения" — упрощённо, без
  /// отслеживания видимости конкретных пузырей во вьюпорте: этого
  /// достаточно для 1:1 переписки, где вся история грузится целиком (см.
  /// _bootstrapHistory), а не постранично. markReadReceiptsSent делает
  /// повторные вызовы дешёвыми — уже отмеченные сообщения просто
  /// отфильтровываются здесь и на диск повторно не пишутся.
  Future<void> _maybeSendReadReceipts() async {
    if (_isNotes) return;
    final toMark = _messages
        .where((m) => !m.isMine && !m.readReceiptSent)
        .map((m) => m.messageId)
        .toList();
    if (toMark.isEmpty) return;
    // Раньше помечали "квитанция отправлена" ДО подтверждения, что отправка
    // реально прошла — любой разовый сбой (например, сессия ещё не
    // установлена, или временная проблема сети) навсегда и незаметно терял
    // именно эту квитанцию: флаг уже стоял, повторной попытки никогда не
    // случалось. Теперь помечаем только по РЕАЛЬНОМУ ack от сервера (см.
    // onAcked/SendQueueProcessor) — просто "поставили в очередь" (то, что
    // возвращает _sendControlMessage) больше не значит "доставлено", это
    // асинхронно. При неудаче/потере колбэка (например, если приложение
    // убьют между постановкой в очередь и ack) эти же id просто снова
    // попадут в toMark при следующем естественном триггере (открытие
    // чата, новое сообщение от собеседника) — идемпотентно, без
    // отдельного специального retry-механизма.
    await _sendControlMessage(
      InnerMessage.readReceipt(targetMessageIds: toMark),
      onAcked: () => ChatStore.markReadReceiptsSent(widget.peerLogin, toMark),
    );
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
    if (_isPeerDeleted || _isNotes) return;
    // Экран разговора должен открыться сразу — актуализация device_id и
    // сам обмен WebRTC идут уже в фоне, с живым статусом на самом экране
    // (см. CallService.statusUpdates), а не как задержка перед его показом.
    unawaited(_refreshPeerDeviceId());
    unawaited(CallService.instance.startCall(_currentPeerDeviceId));
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CallScreen(
          peerLogin: widget.peerLogin,
          peerAccountId: widget.peerAccountId,
        ),
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
    HapticFeedback.vibrate();
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
        SnackBar(
          content: Text(tr('common.copied')),
          duration: const Duration(seconds: 1),
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
        SnackBar(
          content: Text(tr('common.copied')),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  void _enterSelectionMode(StoredMessage msg, {List<String>? groupMessageIds}) {
    HapticFeedback.vibrate();
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
    HapticFeedback.vibrate();
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
  ///
  /// Порядок событий намеренно именно такой, а не "пузырь мгновенно исчез,
  /// а частицы появились поверх пустого места": (1) снимаем пузырь картинкой
  /// (2) СРАЗУ же прячем сам пузырь (Opacity 0, но место в списке остаётся —
  /// см. _dissolvingMessageIds) и запускаем частицы ровно на его месте — со
  /// стороны выглядит так, будто сообщение само превращается в пыль, ничего
  /// не оставляя (3) и только когда частицы долетели, по-настоящему удаляем
  /// сообщение из списка — вот тогда соседние сообщения и сдвигаются на
  /// освободившееся место, а не раньше.
  Future<void> _deleteMessages(List<String> ids) async {
    if (ids.isEmpty) return;

    final result = await showDeleteMessagesDialog(
      context,
      peerName: widget.peerLogin,
      showPeerCheckbox: !_isNotes,
    );
    if (result == null || !mounted) return;

    final shatterCaptures = await _captureShatterImages(ids);

    if (shatterCaptures.isNotEmpty && mounted) {
      setState(() {
        _dissolvingMessageIds.addAll(shatterCaptures.map((c) => c.messageId));
      });
    }
    final effectFutures = mounted
        ? shatterCaptures
              .map(
                (c) => showShatterEffect(context, image: c.image, rect: c.rect),
              )
              .toList()
        : const <Future<void>>[];

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

    if (effectFutures.isNotEmpty) await Future.wait(effectFutures);

    await ChatStore.deleteMessages(widget.peerLogin, ids);
    if (_selectionMode) _exitSelectionMode();
    await _loadHistory();

    if (mounted) {
      setState(() {
        _dissolvingMessageIds.removeAll(
          shatterCaptures.map((c) => c.messageId),
        );
      });
    }
  }

  /// Снимки пузырей сообщений [ids], которые сейчас реально отрисованы на
  /// экране (см. _shatterBoundaryKeys в _wrapInteractive) — по одному на
  /// bubble, а не на id: у сгруппированных сообщений один общий пузырь
  /// зарегистрирован только под id представителя группы, остальные id
  /// группы просто не находят себе ключ и пропускаются, чтобы не снимать
  /// один и тот же пузырь несколько раз. messageId в результате — id
  /// представителя (тот же, что ключ в _shatterBoundaryKeys/_messageKeys) —
  /// именно по нему _wrapInteractive проверяет _dissolvingMessageIds.
  Future<List<({ui.Image image, Rect rect, String messageId})>>
  _captureShatterImages(List<String> ids) async {
    final pixelRatio = MediaQuery.of(context).devicePixelRatio;
    final captures = <({ui.Image image, Rect rect, String messageId})>[];
    for (final id in ids) {
      final renderObject = _shatterBoundaryKeys[id]?.currentContext
          ?.findRenderObject();
      if (renderObject is! RenderRepaintBoundary) continue;
      try {
        final image = await renderObject.toImage(pixelRatio: pixelRatio);
        final position = renderObject.localToGlobal(Offset.zero);
        captures.add((
          image: image,
          rect: position & renderObject.size,
          messageId: id,
        ));
      } catch (_) {
        // boundary мог не успеть ни разу отрисоваться — просто без эффекта.
      }
    }
    return captures;
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

  /// Какое сообщение (точнее, id его "представителя" — см. _messageKeys)
  /// сейчас находится под пальцем, по глобальным координатам — используется
  /// протяжкой в режиме выбора (см. handleLongPressMoveUpdate). Заведомо
  /// недорого: на экране одновременно построено разумное число сообщений, а
  /// для всех остальных ключей currentContext уже null (ListView.builder
  /// снял их с дерева) и итерация пропускает их почти бесплатно.
  String? _messageRepIdAtGlobalPosition(Offset globalPosition) {
    for (final entry in _messageKeys.entries) {
      final renderObject = entry.value.currentContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.attached) continue;
      final origin = renderObject.localToGlobal(Offset.zero);
      final rect = origin & renderObject.size;
      if (rect.contains(globalPosition)) return entry.key;
    }
    return null;
  }

  /// Прыжок к произвольному сообщению — например, для закрепа он почти
  /// всегда УЖЕ построен (ленивый ListView.builder держит недавние элементы
  /// в дереве), тогда достаточно Scrollable.ensureVisible. Но для поиска
  /// цель сплошь и рядом ГДЕ-ТО ДАЛЕКО за пределами текущего viewport'а —
  /// там currentContext ещё null (элемент физически не построен), и
  /// ensureVisible молча ничего не делает. В этом случае сначала грубо
  /// летим по линейной оценке позиции (доля индекса группы от общего
  /// числа групп × maxScrollExtent — сообщения разной высоты, так что это
  /// именно оценка, не точный расчёт) НАСТОЯЩЕЙ анимацией (не jumpTo —
  /// иначе список телепортируется, минуя кадры, и не видно самого
  /// "пролистывания" мимо сообщений между стартом и целью), затем в
  /// несколько попыток ждём кадр и проверяем, построился ли наконец нужный
  /// элемент, и только тогда доводим до пикселя отдельной, более медленной
  /// и плавной анимацией — так "быстрый перелёт" и "плавное торможение на
  /// цели" ощущаются как две разные фазы одного движения.
  Future<void> _scrollToMessage(String messageId) async {
    final existingCtx = _messageKeys[messageId]?.currentContext;
    if (existingCtx != null) {
      await Scrollable.ensureVisible(
        existingCtx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        alignment: 0.5,
      );
      return;
    }
    if (!_scrollController.hasClients) return;

    final groups = _groupedMessages();
    final groupIndex = groups.indexWhere(
      (g) => g.any((m) => m.messageId == messageId),
    );
    if (groupIndex == -1) return;

    final maxExtent = _scrollController.position.maxScrollExtent;
    final estimate = groups.length <= 1
        ? 0.0
        : (groupIndex / (groups.length - 1)) * maxExtent;
    final clampedEstimate = estimate.clamp(0.0, maxExtent);

    // Скорость перелёта — фиксированные px/мс (не константная длительность),
    // чтобы близкая цель летела быстро, а очень дальняя не растягивалась на
    // неадекватно долгую анимацию — и то и другое ограничено снизу/сверху.
    final distance = (clampedEstimate - _scrollController.offset).abs();
    final flightMs = (distance / 3.2).clamp(280, 900).round();
    await _scrollController.animateTo(
      clampedEstimate,
      duration: Duration(milliseconds: flightMs),
      curve: Curves.easeOut,
    );

    for (var attempt = 0; attempt < 8; attempt++) {
      if (!mounted || !_scrollController.hasClients) return;
      final ctx = _messageKeys[messageId]?.currentContext;
      if (ctx != null) {
        await Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOutCubic,
          alignment: 0.5,
        );
        return;
      }
      await Future.delayed(const Duration(milliseconds: 50));
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

    final showEdit =
        msg.isMine && !msg.isMedia && !msg.isCallLog && msg.groupId == null;
    final showCopy = !msg.isMedia && !msg.isCallLog;
    final isPinned = _pinnedMessageId == msg.messageId;

    HapticFeedback.mediumImpact();
    final selection = await showMessageContextMenu(
      context,
      tapPosition: tapPosition,
      isMine: msg.isMine,
      showCopy: showCopy,
      showEdit: showEdit,
      isPinned: isPinned,
      currentMyReaction: msg.myReaction,
      // onOpened стреляет из initState виджета оверлея — это происходит
      // ВНУТРИ активной фазы построения дерева (просто в другой, не
      // родительской для ChatScreen ветке — у Overlay), и в эту секунду
      // Flutter запрещает setState на ЛЮБОМ виджете, который не является
      // предком того, что сейчас строится (иначе — ровно то самое красное
      // "setState() or markNeedsBuild() called during build"). Поэтому
      // просто откладываем на кадр вперёд — к следующему кадру текущая
      // фаза построения уже точно завершена, вызывать setState safe.
      onOpened: (close) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _closeContextMenu = close);
        });
      },
    );
    if (mounted) setState(() => _closeContextMenu = null);
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
      case MessageMenuAction.report:
        await showReportMessageDialog(
          context,
          reportedDeviceId: _currentPeerDeviceId,
          messageText: msg.text,
        );
        break;
    }
  }

  Future<RatchetState> _ensureSessionForSending() async {
    await _refreshPeerDeviceId();
    var state = await SessionStore.getState(_currentPeerDeviceId);
    if (state != null) return state;

    DebugLog.log(
      'ChatScreen establishing fresh X3DH outgoing session to=$_currentPeerDeviceId '
      '(no local session found)',
    );
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
  /// тем же каналом (Double Ratchet + единая надёжная очередь, см.
  /// SendQueueProcessor), что и обычные сообщения — но без записи в
  /// локальную историю чата, у этих типов нет собственного пузыря.
  ///
  /// Возвращает true, если удалось поставить в очередь (шифрование
  /// прошло успешно) — НЕ то же самое, что "доставлено", это теперь
  /// асинхронно и гарантируется самой очередью. Если конкретному вызову
  /// нужна реакция именно на подтверждённую ДОСТАВКУ (а не просто
  /// постановку в очередь) — используйте [onAcked].
  Future<bool> _sendControlMessage(
    InnerMessage inner, {
    Future<void> Function()? onAcked,
  }) async {
    if (_isNotes) return true;
    try {
      await SendLock.run(widget.peerLogin, () async {
        final myDeviceId = await KeyStore.getStoredDeviceId();
        final state = await _ensureSessionForSending();
        final initHeader = _pendingInitHeader;
        _pendingInitHeader = null;

        final next = await state.nextSendingKey();
        DebugLog.log(
          'ChatScreen sending key (control msg type=${inner.type}) '
          'to=$_currentPeerDeviceId messageNumber=${next.header['message_number']} '
          'ratchetPubkey=${next.header['ratchet_pubkey']}',
        );
        await SessionStore.saveState(_currentPeerDeviceId, state);

        final encrypted = await encryptMessage(next.messageKey, inner.encode());
        final envelope = <String, dynamic>{
          ...encrypted,
          ...next.header,
          'sender_device_id': myDeviceId,
          if (initHeader != null) ...initHeader,
        };

        await SendQueueProcessor.instance.enqueue(
          toDeviceId: _currentPeerDeviceId,
          envelope: envelope,
          deliveryId: inner.messageId,
          silent: true,
          onAcked: onAcked,
        );
      });
      return true;
    } catch (e) {
      debugPrint('Ошибка отправки служебного сообщения: $e');
      return false;
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

    if (_isNotes) {
      await ChatStore.updateMessageStatus(widget.peerLogin, messageId, 'sent');
      await _loadHistory();
      return;
    }

    try {
      await SendLock.run(widget.peerLogin, () async {
        final myDeviceId = await KeyStore.getStoredDeviceId();
        final state = await _ensureSessionForSending();
        final initHeader = _pendingInitHeader;
        _pendingInitHeader = null;

        final next = await state.nextSendingKey();
        DebugLog.log(
          'ChatScreen sending key (text messageId=${inner.messageId}) '
          'to=$_currentPeerDeviceId messageNumber=${next.header['message_number']} '
          'ratchetPubkey=${next.header['ratchet_pubkey']}',
        );
        await SessionStore.saveState(_currentPeerDeviceId, state);

        final encrypted = await encryptMessage(next.messageKey, inner.encode());
        final envelope = <String, dynamic>{
          ...encrypted,
          ...next.header,
          'sender_device_id': myDeviceId,
          if (initHeader != null) ...initHeader,
        };

        // Статус на 'sent' проставляет сама очередь по факту реального
        // ack от сервера (см. SendQueueProcessor._attempt), не раньше —
        // до этого момента пузырь остаётся в статусе, с которым был
        // создан (см. _sendTextMessage), это уже честно "в очереди на
        // доставку", а не "точно ушло".
        await SendQueueProcessor.instance.enqueue(
          toDeviceId: _currentPeerDeviceId,
          envelope: envelope,
          deliveryId: inner.messageId,
          messageId: inner.messageId,
          peerLogin: widget.peerLogin,
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

  // ===== Голосовые/видео-сообщения =====
  //
  // Состояния: idle (просто иконка микрофона/камеры) → dragging (палец
  // держит кнопку, запись идёт) → либо locked (палец довели до замочка,
  // можно отпускать — запись продолжается), либо запись сразу
  // завершается/отменяется по отпусканию/свайпу влево. См. _RecPhase.

  void _toggleRecordKindIcon() {
    if (_recPhase != _RecPhase.idle) return;
    setState(() => _recCameraSelected = !_recCameraSelected);
  }

  String _formatRecTimer(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _beginRecording() async {
    if (_recPhase != _RecPhase.idle) return;
    final isVideo = _recCameraSelected;

    if (isVideo) {
      if (_availableCameras.isEmpty) {
        try {
          _availableCameras = await availableCameras();
        } catch (_) {
          return;
        }
      }
      if (_availableCameras.isEmpty) return;
      final desc = _availableCameras.firstWhere(
        (c) => c.lensDirection == _recLensDirection,
        orElse: () => _availableCameras.first,
      );
      final controller = CameraController(
        desc,
        ResolutionPreset.medium,
        enableAudio: true,
      );
      try {
        await controller.initialize();
        // enablePersistentRecording — держит запись живой, пока мы потом
        // разворачиваем камеру через setDescription() (см.
        // _flipRecordingCamera): БЕЗ этого Android обрывает запись при
        // смене объектива, и получаются два несклеенных файла вместо
        // одного целого.
        await controller.startVideoRecording(enablePersistentRecording: true);
      } catch (_) {
        controller.dispose();
        return;
      }
      if (!mounted) {
        try {
          await controller.stopVideoRecording();
        } catch (_) {}
        controller.dispose();
        return;
      }
      _recCameraController = controller;
    } else {
      bool hasPermission;
      try {
        hasPermission = await _audioRecorder.hasPermission();
      } catch (_) {
        hasPermission = false;
      }
      if (!hasPermission) return;
      final tempDir = await getTemporaryDirectory();
      final path =
          '${tempDir.path}/voice_${DateTime.now().microsecondsSinceEpoch}.m4a';
      try {
        await _audioRecorder.start(
          const RecordConfig(encoder: AudioEncoder.aacLc),
          path: path,
        );
      } catch (_) {
        return;
      }
      _recAudioPath = path;
    }

    if (!mounted || !_recPointerDown) {
      // Палец отпустился ещё во время системного диалога разрешения (или
      // просто пока шла инициализация камеры/микрофона) — см.
      // _recPointerDown. Жест по факту уже закончился, Flutter об этом не
      // узнал, а мы уже успели что-то начать записывать — аккуратно всё
      // отменяем и остаёмся в idle: следующий долгий тап сработает штатно,
      // разрешение уже выдано, диалог второй раз не всплывёт.
      if (isVideo) {
        final controller = _recCameraController;
        _recCameraController = null;
        try {
          if (controller != null && controller.value.isRecordingVideo) {
            final xfile = await controller.stopVideoRecording();
            final f = File(xfile.path);
            if (await f.exists()) await f.delete();
          }
        } catch (_) {}
        controller?.dispose();
      } else {
        try {
          await _audioRecorder.cancel();
        } catch (_) {}
        final path = _recAudioPath;
        _recAudioPath = null;
        if (path != null) {
          try {
            final f = File(path);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      }
      return;
    }

    _recStartedAt = DateTime.now();
    _recTicker?.cancel();
    _recTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted || _recStartedAt == null) return;
      setState(() => _recElapsed = DateTime.now().difference(_recStartedAt!));
      // Только видео-кружочки — голосовые нарочно без ограничения (см.
      // _maxVideoNoteDuration). send: true — ведём себя так, будто
      // пользователь сам отпустил палец, а не обрываем запись молча.
      if (_recActiveKind == _RecKind.video &&
          _recElapsed >= _maxVideoNoteDuration) {
        _finishRecording(send: true);
      }
    });

    setState(() {
      _recActiveKind = isVideo ? _RecKind.video : _RecKind.voice;
      _recPhase = _RecPhase.dragging;
      _recElapsed = Duration.zero;
      _recDragOffset = Offset.zero;
    });
  }

  /// Дистанция свайпа влево до отмены записи — половина ширины экрана
  /// (не фиксированные пиксели): иначе на широких экранах отмена
  /// срабатывала от совсем небольшого, случайного смещения пальца.
  double get _recCancelThresholdPx => MediaQuery.of(context).size.width * 0.5;

  /// offsetFromOrigin — уже НАКОПЛЕННОЕ смещение пальца от точки начала
  /// долгого тапа (даёт сам LongPressMoveUpdateDetails), считать дельты
  /// самим не нужно.
  void _updateRecordingDrag(Offset offsetFromOrigin) {
    if (_recPhase != _RecPhase.dragging) return;
    // Живое смещение — двигает замочек/подсказку отмены навстречу пальцу
    // ещё ДО достижения порога (см. _buildRecordingLockIndicator и
    // _buildRecordingComposerChildren), а не толькощёлкает по факту.
    setState(() => _recDragOffset = offsetFromOrigin);
    if (offsetFromOrigin.dx < -_recCancelThresholdPx) {
      HapticFeedback.vibrate();
      _cancelRecording();
      return;
    }
    if (offsetFromOrigin.dy < -70) {
      HapticFeedback.vibrate();
      setState(() => _recPhase = _RecPhase.locked);
    }
  }

  void _endRecordingGesture() {
    if (_recPhase == _RecPhase.dragging) {
      _finishRecording(send: true);
    }
    // locked — палец можно было отпустить ещё раньше, запись продолжается
    // без него; ничего тут делать не нужно.
  }

  Future<void> _cancelRecording() async {
    if (_recPhase == _RecPhase.idle) return;
    final kind = _recActiveKind;
    _recTicker?.cancel();
    _recTicker = null;
    setState(() {
      _recPhase = _RecPhase.idle;
      _recActiveKind = null;
      _recElapsed = Duration.zero;
    });

    if (kind == _RecKind.video) {
      final controller = _recCameraController;
      _recCameraController = null;
      try {
        if (controller != null && controller.value.isRecordingVideo) {
          final xfile = await controller.stopVideoRecording();
          final f = File(xfile.path);
          if (await f.exists()) await f.delete();
        }
      } catch (_) {}
      controller?.dispose();
    } else {
      try {
        await _audioRecorder.cancel();
      } catch (_) {}
      final path = _recAudioPath;
      _recAudioPath = null;
      if (path != null) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _finishRecording({required bool send}) async {
    if (_recPhase == _RecPhase.idle) return;
    if (!send) {
      await _cancelRecording();
      return;
    }

    final kind = _recActiveKind;
    final duration = _recElapsed;
    _recTicker?.cancel();
    _recTicker = null;

    File? resultFile;
    if (kind == _RecKind.video) {
      final controller = _recCameraController;
      _recCameraController = null;
      try {
        if (controller != null && controller.value.isRecordingVideo) {
          final xfile = await controller.stopVideoRecording();
          resultFile = File(xfile.path);
        }
      } catch (_) {}
      controller?.dispose();
    } else {
      try {
        final path = await _audioRecorder.stop();
        if (path != null) resultFile = File(path);
      } catch (_) {}
      _recAudioPath = null;
    }

    setState(() {
      _recPhase = _RecPhase.idle;
      _recActiveKind = null;
      _recElapsed = Duration.zero;
    });

    if (resultFile == null || duration.inMilliseconds < 700) {
      // Слишком короткая запись — почти наверняка случайный тап, а не
      // осознанное сообщение.
      try {
        if (resultFile != null && await resultFile.exists()) {
          await resultFile.delete();
        }
      } catch (_) {}
      return;
    }

    await _sendRecordedMessage(
      file: resultFile,
      duration: duration,
      isVideo: kind == _RecKind.video,
    );
  }

  /// Разворот камеры ПРЯМО В ТОЙ ЖЕ записи, без остановки/склейки — камера-
  /// плагин это умеет через CameraController.setDescription() (на Android
  /// требует enablePersistentRecording: true при самом startVideoRecording,
  /// см. _beginRecording), тот же контроллер и тот же файл продолжают
  /// писаться, просто с другого объектива.
  Future<void> _flipRecordingCamera() async {
    final controller = _recCameraController;
    if (_recActiveKind != _RecKind.video || controller == null) return;
    if (_availableCameras.length < 2) return;

    final newDirection = _recLensDirection == CameraLensDirection.front
        ? CameraLensDirection.back
        : CameraLensDirection.front;
    final desc = _availableCameras.firstWhere(
      (c) => c.lensDirection == newDirection,
      orElse: () => _availableCameras.first,
    );

    try {
      await controller.setDescription(desc);
      _recLensDirection = newDirection;
      if (mounted) setState(() {});
    } catch (_) {
      // Не удалось развернуть — остаёмся на прежней камере, запись как
      // шла, так и продолжает идти.
    }
  }

  /// Шифрует, грузит и отправляет уже записанный голосовой/видео файл —
  /// тот же путь (encrypt → upload → InnerMessage → SendLock), что и для
  /// обычных вложений, см. _uploadAndDescribeMedia/_processQueuedMedia.
  Future<void> _sendRecordedMessage({
    required File file,
    required Duration duration,
    required bool isVideo,
  }) async {
    final size = await file.length();
    final messageId =
        '${DateTime.now().microsecondsSinceEpoch}_${isVideo ? 'vnote' : 'voice'}';

    await ChatStore.addMessage(
      widget.peerLogin,
      StoredMessage(
        messageId,
        isVideo ? '🎥 ${tr('media.videoNote')}' : '🎤 ${tr('media.voiceNote')}',
        true,
        DateTime.now().millisecondsSinceEpoch,
        isMedia: true,
        isVoice: !isVideo,
        isVideoNote: isVideo,
        fileSize: size,
        chunked: size > _streamingThresholdBytes,
        durationMs: duration.inMilliseconds,
        status: 'sending',
        processingStep: tr('chat.queued'),
      ),
      accountId: widget.peerAccountId,
    );
    _userAtBottom = true;
    await _loadHistory();

    if (_isNotes) {
      try {
        final token = await Session.getToken();
        final myAccountId = await Session.getAccountId() ?? '';
        await _uploadAndDescribeMedia(
          PickedMedia(file: file, isVideo: isVideo),
          messageId,
          size,
          isVideo ? 'video_note.mp4' : 'voice.m4a',
          token!,
          myAccountId,
        );
        await ChatStore.updateMessageStatus(
          widget.peerLogin,
          messageId,
          'sent',
        );
      } catch (e, stackTrace) {
        debugPrint(
          'Ошибка загрузки голосового/видео в заметки: $e\n$stackTrace',
        );
        await ChatStore.updateMessageStatus(
          widget.peerLogin,
          messageId,
          'failed',
        );
      } finally {
        await _loadHistory();
        try {
          await file.delete();
        } catch (_) {}
      }
      return;
    }

    try {
      // runHeavy — глобальная (across всех собеседников) сериализация
      // самой загрузки: следующее тяжёлое (фото/видео/файл/голосовое)
      // не начинает грузиться, пока не закончилось (успехом или
      // неудачей) предыдущее. SendLock внутри — как и раньше, отдельная,
      // более узкая сериализация именно крипто-состояния ЭТОГО
      // собеседника, друг другу эти два уровня не мешают.
      await SendQueueProcessor.instance.runHeavy(
        () => SendLock.run(widget.peerLogin, () async {
          final token = await Session.getToken();
          final myDeviceId = await KeyStore.getStoredDeviceId();
          final state = await _ensureSessionForSending();
          final initHeader = _pendingInitHeader;
          _pendingInitHeader = null;

          final peerAccountIdForUpload =
              await PeerAccountStore.get(_currentPeerDeviceId) ??
              widget.peerAccountId;

          final desc = await _uploadAndDescribeMedia(
            PickedMedia(file: file, isVideo: isVideo),
            messageId,
            size,
            isVideo ? 'video_note.mp4' : 'voice.m4a',
            token!,
            peerAccountIdForUpload,
          );

          await ChatStore.updateProcessingStep(
            widget.peerLogin,
            messageId,
            tr('chat.sending'),
          );

          final inner = isVideo
              ? InnerMessage.videoNote(
                  messageId: messageId,
                  mediaId: desc['media_id'] as String,
                  keyBase64: desc['key'] as String,
                  nonceBase64: desc['nonce'] as String?,
                  macBase64: desc['mac'] as String?,
                  fileSize: size,
                  chunked: desc['chunked'] as bool,
                  durationMs: duration.inMilliseconds,
                )
              : InnerMessage.voice(
                  messageId: messageId,
                  mediaId: desc['media_id'] as String,
                  keyBase64: desc['key'] as String,
                  nonceBase64: desc['nonce'] as String?,
                  macBase64: desc['mac'] as String?,
                  fileSize: size,
                  chunked: desc['chunked'] as bool,
                  durationMs: duration.inMilliseconds,
                );

          final next = await state.nextSendingKey();
          DebugLog.log(
            'ChatScreen sending key (voice/video_note type=${inner.type} '
            'messageId=${inner.messageId}) to=$_currentPeerDeviceId '
            'messageNumber=${next.header['message_number']} '
            'ratchetPubkey=${next.header['ratchet_pubkey']}',
          );
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

          await SendQueueProcessor.instance.enqueue(
            toDeviceId: _currentPeerDeviceId,
            envelope: envelope,
            deliveryId: messageId,
            messageId: messageId,
            peerLogin: widget.peerLogin,
          );
        }),
      );
    } catch (e, stackTrace) {
      debugPrint('Ошибка отправки голосового/видео сообщения: $e\n$stackTrace');
      await ChatStore.updateMessageStatus(
        widget.peerLogin,
        messageId,
        'failed',
      );
    } finally {
      await _loadHistory();
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  /// "Переворот монеты" — общий эффект для переключаемых иконок композера
  /// (микрофон⇄камера, эмодзи⇄клавиатура): старая иконка довращивается
  /// только до 90° (ребром, дальше её не видно — без этой отсечки при
  /// вращении дальше показалась бы её зеркальная изнанка), а новая в это
  /// же время довращивается ОТ 90° до 0°, создавая видимость одной
  /// непрерывно переворачивающейся монеты. stateKey — текущее состояние
  /// (например, _emojiMode) — по нему решается, какая из двух copies
  /// "сверху", а какая "снизу".
  Widget _buildFlipIcon({required Object stateKey, required Widget icon}) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      transitionBuilder: (child, animation) {
        final rotateAnim = Tween<double>(
          begin: math.pi,
          end: 0.0,
        ).animate(animation);
        return AnimatedBuilder(
          animation: rotateAnim,
          child: child,
          builder: (context, child) {
            final isUnder = child!.key != ValueKey(stateKey);
            final value = isUnder
                ? math.min(rotateAnim.value, math.pi / 2)
                : rotateAnim.value;
            return Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.001)
                ..rotateY(value),
              child: child,
            );
          },
        );
      },
      child: KeyedSubtree(key: ValueKey(stateKey), child: icon),
    );
  }

  /// Кнопка микрофона/камеры — тап переключает иконку (когда в покое) или
  /// отправляет запись (когда режим "замка" уже активен), долгий тап
  /// начинает запись и ведёт её пальцем. Ключ ОБЯЗАТЕЛЕН и должен
  /// оставаться одним и тем же между состояниями — иначе Flutter при
  /// смене соседних виджетов в Row (иконка эмодзи ⇄ таймер и т.п.) решит,
  /// что это другой виджет, пересоздаст его и потеряет уже идущий жест
  /// прямо посреди записи.
  Widget _buildRecordControlButton() {
    final showSend = _recPhase == _RecPhase.locked;
    final Widget icon;
    if (showSend) {
      icon = Icon(Icons.send, color: AppColors.primary);
    } else if (_recPhase == _RecPhase.dragging) {
      icon = Icon(
        _recActiveKind == _RecKind.video ? Icons.videocam : Icons.mic,
        color: Colors.redAccent,
      );
    } else {
      icon = _buildFlipIcon(
        stateKey: _recCameraSelected,
        icon: Icon(
          _recCameraSelected ? Icons.camera_alt : Icons.mic,
          color: AppColors.textMuted,
        ),
      );
    }

    return Listener(
      // См. комментарий у _recPointerDown — источник истины "палец реально
      // ещё на кнопке" независимо от того, что сейчас решил жест-детектор
      // ниже (тот может застрять, если долгий тап прервал системный диалог
      // разрешения). onPointerCancel — на случай, если ОС сама отменит
      // указатель (например, тем же самым системным диалогом).
      onPointerDown: (_) => _recPointerDown = true,
      onPointerUp: (_) => _recPointerDown = false,
      onPointerCancel: (_) => _recPointerDown = false,
      child: GestureDetector(
        key: _recordButtonKey,
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_recPhase == _RecPhase.locked) {
            _finishRecording(send: true);
          } else if (_recPhase == _RecPhase.idle) {
            _toggleRecordKindIcon();
          }
        },
        onLongPressStart: _recPhase == _RecPhase.idle
            ? (_) => _beginRecording()
            : null,
        onLongPressMoveUpdate: _recPhase == _RecPhase.dragging
            ? (details) => _updateRecordingDrag(details.offsetFromOrigin)
            : null,
        onLongPressEnd: _recPhase == _RecPhase.dragging
            ? (_) => _endRecordingGesture()
            : null,
        child: Padding(padding: const EdgeInsets.all(8), child: icon),
      ),
    );
  }

  /// Заменяет всю строку композера на время записи: таймер вместо иконки
  /// эмодзи, подсказка про отмену (или кнопка отмены после блокировки)
  /// вместо текстового поля, и кнопка записи/отправки в конце — она же
  /// самая обычная _buildRecordControlButton, просто в другом месте Row.
  List<Widget> _buildRecordingComposerChildren() {
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _PulsingRecDot(),
            const SizedBox(width: 6),
            Text(
              _formatRecTimer(_recElapsed),
              style: TextStyle(
                color: AppColors.textPrimary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
      Expanded(
        child: _recPhase == _RecPhase.locked
            ? InkWell(
                onTap: () => _finishRecording(send: false),
                child: Center(
                  child: Text(
                    tr('chat.cancelRecording'),
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 13,
                    ),
                  ),
                ),
              )
            : Builder(
                builder: (context) {
                  // Живая реакция на протяжку влево — ещё ДО порога отмены:
                  // подсказка едет навстречу пальцу и краснеет по мере
                  // приближения к порогу, а не молча ждёт щелчка по факту.
                  final cancelProgress =
                      (-_recDragOffset.dx / _recCancelThresholdPx).clamp(
                        0.0,
                        1.0,
                      );
                  final tint = Color.lerp(
                    AppColors.textMuted,
                    Colors.redAccent,
                    cancelProgress,
                  )!;
                  return Transform.translate(
                    offset: Offset(-18 * cancelProgress, 0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.chevron_left, color: tint, size: 16),
                        Flexible(
                          child: Text(
                            tr('chat.swipeLeftToCancel'),
                            style: TextStyle(color: tint, fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      _buildRecordControlButton(),
    ];
  }

  /// Замочек (блокировки записи) и живое превью камеры для видео-сообщений
  /// — плавают НАД панелью композера, см. Stack в build().
  /// Замочек блокировки — плавает над кнопкой микрофона/камеры, пока идёт
  /// перетаскивание (см. Positioned в build()).
  Widget _buildRecordingLockIndicator() {
    // Живая реакция на протяжку вверх — ещё ДО порога блокировки: замочек
    // подтягивается навстречу пальцу, слегка растёт и загорается акцентным
    // цветом по мере приближения к порогу, а не молча ждёт щелчка по факту.
    final lockProgress = (-_recDragOffset.dy / 70).clamp(0.0, 1.0);
    final tint = Color.lerp(
      AppColors.textMuted,
      AppColors.primary,
      lockProgress,
    )!;
    return Transform.translate(
      offset: Offset(0, -10 * lockProgress),
      child: Transform.scale(
        scale: 1.0 + 0.18 * lockProgress,
        child: Container(
          width: 38,
          height: 64,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(Icons.keyboard_arrow_up, color: tint, size: 18),
              Icon(Icons.lock_outline, color: tint, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  /// Верх панели ввода, В КООРДИНАТАХ body-Stack'а (_bodyStackKey), а НЕ
  /// абсолютных экранных — Scaffold.body уже начинается НИЖЕ AppBar'а, и
  /// если по ошибке взять composerBox.localToGlobal БЕЗ ancestor, к
  /// результату лишний раз прибавляется высота AppBar'а/статус-бара: всё,
  /// что дальше позиционируется от этого значения внутри Stack'а (сам он
  /// стоит уже НИЖЕ AppBar'а), уезжает вниз ровно на эту лишнюю добавку —
  /// именно так раньше "уезжал" квадрат видеозаписи. null, если оба
  /// RenderBox-а ещё не готовы (самый первый кадр).
  double? _composerTopYInBodyStack() {
    final composerBox =
        _composerAreaKey.currentContext?.findRenderObject() as RenderBox?;
    final stackBox =
        _bodyStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (composerBox == null ||
        !composerBox.attached ||
        stackBox == null ||
        !stackBox.attached) {
      return null;
    }
    return composerBox.localToGlobal(Offset.zero, ancestor: stackBox).dy;
  }

  /// Живое превью записываемого видео-квадрата — во всю ширину экрана
  /// (высота такая же, это квадрат), поверх чата. Раньше центрировался по
  /// ВСЕЙ высоте экрана фиксированно; теперь — только по промежутку между
  /// верхним краем экрана и верхним краем панели ввода, чтобы при поднятой
  /// клавиатуре (когда сама панель ввода тоже поднята) квадрат не залезал
  /// на неё. Верх панели измеряется через RenderBox — это учитывает
  /// автоматически ЛЮБОЕ её текущее положение (клавиатура, эмодзи-панель,
  /// баннер ответа/редактирования), без ручного суммирования всех этих
  /// слагаемых здесь же ещё раз.
  Widget _buildVideoLivePreview() {
    final controller = _recCameraController;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    final screenSize = MediaQuery.of(context).size;
    final size = screenSize.width;
    final composerTopY = _composerTopYInBodyStack() ?? screenSize.height;

    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: composerTopY,
            child: Center(
              child: SizedBox(
                width: size,
                height: size,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: controller.value.previewSize?.height ?? size,
                      height: controller.value.previewSize?.width ?? size,
                      child: CameraPreview(controller),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static const double _flipCameraButtonSize = 44;

  /// Кнопка разворота камеры — крепится к верхнему левому углу панели
  /// ввода (см. Positioned в build(), считает позицию через
  /// _composerTopYInBodyStack) и переезжает вместе с ней, если панель
  /// поднимается клавиатурой.
  Widget _buildFlipCameraButton() {
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: _flipRecordingCamera,
      child: Container(
        width: _flipCameraButtonSize,
        height: _flipCameraButtonSize,
        decoration: const BoxDecoration(
          color: Colors.black45,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.cameraswitch, color: Colors.white, size: 22),
      ),
    );
  }

  final _attachButtonKey = GlobalKey();

  Future<void> _openAttachmentSheet() async {
    // Если клавиатура сейчас открыта — showAttachLauncherOverlay снимает
    // позицию кнопки-скрепки ОДИН раз, синхронно (см. её реализацию), а
    // клавиатура ещё не успела закрыться и композер — переехать на новое
    // место. Раньше из-за этого панель вложений "зависала в воздухе" там,
    // где скрепка была ПРИ ОТКРЫТОЙ клавиатуре. Дожидаемся, пока инсет
    // клавиатуры реально осядет, и только потом измеряем позицию.
    final wasKeyboardVisible = MediaQuery.of(context).viewInsets.bottom > 50;
    _textFocusNode.unfocus();
    setState(() => _emojiMode = false);

    if (wasKeyboardVisible) {
      for (var i = 0; i < 30; i++) {
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        if (MediaQuery.of(context).viewInsets.bottom <= 50) break;
      }
      if (!mounted) return;
    }

    final choice = await showAttachLauncherOverlay(
      context,
      anchorKey: _attachButtonKey,
      // Тот же механизм, что и у showMessageContextMenu ниже — пока это
      // меню открыто, системный back/свайп-назад должен закрыть ЕГО
      // (см. _handleBackAction/PopScope/SwipeBackDetector), а не увести с
      // экрана чата, оставив меню висеть поверх следующего экрана.
      onOpened: (close) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _closeContextMenu = close);
        });
      },
    );
    if (mounted) setState(() => _closeContextMenu = null);
    if (choice == AttachMenuChoice.media) {
      await _openMediaPanel();
    } else if (choice == AttachMenuChoice.files) {
      await _openFilesPanel();
    }
  }

  Future<void> _openFilesPanel() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;
    final files = result.files
        .where((f) => f.path != null)
        .map((f) => PickedMedia(file: File(f.path!), isFile: true))
        .toList();
    if (files.isNotEmpty) {
      await _sendPickedMedia(files, '', forceNoGroup: true);
    }
  }

  Future<void> _openMediaPanel() async {
    // Запрос доступа к галерее (см. MediaAssetCache) — ровно в момент
    // выбора "Медиа" в меню скрепки, а не заранее при входе в чат: Google
    // Play требует спрашивать разрешение по факту намерения им
    // воспользоваться, а не на всякий случай. prefetch() стартует чуть
    // раньше, чем откроется сама шторка (showMediaPickerSheet ниже) — так
    // список успевает частично подгрузиться, пока играет анимация
    // открытия, без полноценного холодного запроса внутри шторки.
    MediaAssetCache.prefetch();
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

  /// Изображение, скопированное в системный буфер обмена Android (например,
  /// долгим тапом по картинке в Chrome — "Копировать изображение") и
  /// вставленное через полоску подсказок над клавиатурой — приходит сюда
  /// напрямую от Flutter engine (Android-only API, см. contentInsertionConfiguration
  /// у TextField ниже), уже готовыми байтами. Отправляем сразу же, как
  /// обычное фото-вложение — так же, как просил пользователь.
  Future<void> _handleContentInserted(KeyboardInsertedContent content) async {
    final data = content.data;
    if (data == null || data.isEmpty) return;
    final ext = content.mimeType.contains('png')
        ? 'png'
        : content.mimeType.contains('gif')
        ? 'gif'
        : content.mimeType.contains('webp')
        ? 'webp'
        : 'jpg';
    final tempDir = await getTemporaryDirectory();
    final file = File(
      '${tempDir.path}/pasted_${DateTime.now().microsecondsSinceEpoch}.$ext',
    );
    await file.writeAsBytes(data);
    await _sendPickedMedia([PickedMedia(file: file, isVideo: false)], '');
  }

  Future<void> _sendPickedMedia(
    List<PickedMedia> media,
    String caption, {
    bool forceNoGroup = false,
  }) async {
    String? textMessageId;
    final queue =
        <({PickedMedia item, String messageId, int size, String fileName})>[];

    final hasCaption = caption.isNotEmpty;
    final groupId = (!forceNoGroup && (media.length + (hasCaption ? 1 : 0)) > 1)
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
              content: Text(
                '${tr('chat.fileTooLarge')} (${_formatFileSize(size)})',
              ),
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
          item.isFile
              ? '📎 ${tr('media.file')}'
              : item.isVideo
              ? '🎬 ${tr('media.video')}'
              : '📷 ${tr('media.photo')}',
          true,
          DateTime.now().millisecondsSinceEpoch,
          isMedia: true,
          isFile: item.isFile || item.isVideo,
          fileSize: size,
          chunked: size > _streamingThresholdBytes,
          fileName: fileName,
          status: 'sending',
          processingStep: tr('chat.queued'),
          localPreviewPath: (item.isVideo || item.isFile)
              ? null
              : item.file.path,
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
      tr('chat.encrypting'),
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
        tr('chat.uploading'),
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
        tr('chat.uploading'),
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
      'is_file': item.isFile || item.isVideo,
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
    if (_isNotes) {
      try {
        final token = await Session.getToken();
        final myAccountId = await Session.getAccountId() ?? '';
        await _uploadAndDescribeMedia(
          item,
          messageId,
          size,
          fileName,
          token!,
          myAccountId,
        );
        await ChatStore.updateMessageStatus(
          widget.peerLogin,
          messageId,
          'sent',
        );
      } catch (e, stackTrace) {
        debugPrint(
          'Ошибка загрузки медиа в заметки $messageId: $e\n$stackTrace',
        );
        await ChatStore.updateMessageStatus(
          widget.peerLogin,
          messageId,
          'failed',
        );
      } finally {
        await _loadHistory();
      }
      return;
    }

    try {
      await SendQueueProcessor.instance.runHeavy(
        () => SendLock.run(widget.peerLogin, () async {
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
            tr('chat.negotiating'),
          );

          final inner = InnerMessage.media(
            messageId: messageId,
            mediaId: desc['media_id'] as String,
            keyBase64: desc['key'] as String,
            nonceBase64: desc['nonce'] as String?,
            macBase64: desc['mac'] as String?,
            fileName: fileName,
            isFile: item.isFile || item.isVideo,
            fileSize: size,
            chunked: desc['chunked'] as bool,
          );

          final next = await state.nextSendingKey();
          DebugLog.log(
            'ChatScreen sending key (media messageId=${inner.messageId}) '
            'to=$_currentPeerDeviceId messageNumber=${next.header['message_number']} '
            'ratchetPubkey=${next.header['ratchet_pubkey']}',
          );
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
            tr('chat.sending'),
          );
          await SendQueueProcessor.instance.enqueue(
            toDeviceId: _currentPeerDeviceId,
            envelope: envelope,
            deliveryId: messageId,
            messageId: messageId,
            peerLogin: widget.peerLogin,
          );
        }),
      );
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
    if (_isNotes) {
      try {
        final token = await Session.getToken();
        final myAccountId = await Session.getAccountId() ?? '';
        for (final q in items) {
          await _uploadAndDescribeMedia(
            q.item,
            q.messageId,
            q.size,
            q.fileName,
            token!,
            myAccountId,
          );
        }
        if (textMessageId != null) {
          await ChatStore.updateMessageStatus(
            widget.peerLogin,
            textMessageId,
            'sent',
          );
        }
        for (final q in items) {
          await ChatStore.updateMessageStatus(
            widget.peerLogin,
            q.messageId,
            'sent',
          );
        }
      } catch (e, stackTrace) {
        debugPrint('Ошибка загрузки группы в заметки: $e\n$stackTrace');
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
      return;
    }

    try {
      await SendQueueProcessor.instance.runHeavy(
        () => SendLock.run(widget.peerLogin, () async {
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
              tr('chat.negotiating'),
            );
          }

          final inner = InnerMessage.mediaGroup(
            groupId: groupId,
            caption: caption,
            textMessageId: textMessageId,
            files: files,
          );

          final next = await state.nextSendingKey();
          DebugLog.log(
            'ChatScreen sending key (media_group groupId=$groupId) '
            'to=$_currentPeerDeviceId messageNumber=${next.header['message_number']} '
            'ratchetPubkey=${next.header['ratchet_pubkey']}',
          );
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
              tr('chat.sending'),
            );
          }
          // Один конверт группы разворачивается в НЕСКОЛЬКО локальных
          // пузырей (подпись + каждый файл) — обычный messageId/peerLogin
          // у enqueue() бьёт только по одному id, поэтому статус всех
          // затронутых сообщений проставляем через onAcked при реальном
          // подтверждении, а не по одному месту.
          await SendQueueProcessor.instance.enqueue(
            toDeviceId: _currentPeerDeviceId,
            envelope: envelope,
            deliveryId: inner.messageId,
            onAcked: () async {
              if (textMessageId != null) {
                await ChatStore.updateMessageStatus(
                  widget.peerLogin,
                  textMessageId,
                  'sent',
                );
              }
              for (final q in items) {
                await ChatStore.updateMessageStatus(
                  widget.peerLogin,
                  q.messageId,
                  'sent',
                );
              }
            },
          );
        }),
      );
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

  /// Готовит расшифрованный файл голосового/видео-сообщения для плеера —
  /// та же логика выбора "чанковано/не чанковано", что и у остального
  /// медиа, просто отдаёт готовый File, а не байты.
  Future<File> _resolveRecordedMediaFile(StoredMessage msg) async {
    if (!(await MediaCache.exists(msg.mediaId!))) {
      if (msg.chunked) {
        await _downloadAndDecryptChunked(msg);
      } else {
        await _loadAndCacheMedia(msg);
      }
    }
    return MediaCache.fileFor(msg.mediaId!);
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
          SnackBar(
            content: Text('${tr('chat.openFileFailed')}: ${result.message}'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${tr('chat.openFileFailed')}: $e')),
        );
      }
    }
  }

  Widget _buildAttachmentBubble(StoredMessage msg, {double size = 220}) {
    // Файлы (в отличие от фото/видео) никогда не показываются квадратным
    // превью — ни во время отправки, ни при ошибке: своей картинки у них
    // нет, только имя+иконка по типу (см. _clickableFileRow ниже).
    if (msg.isFile &&
        msg.isMine &&
        (msg.status == 'sending' || msg.status == 'failed')) {
      return _clickableFileRow(msg, size: size);
    }
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
              child: Icon(
                Icons.insert_drive_file,
                color: AppColors.textMuted,
                size: 40,
              ),
            ),
          if (msg.processingStep != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: size < 150 ? 4 : 8,
                  vertical: size < 150 ? 3 : 6,
                ),
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
                    SizedBox(
                      width: size < 150 ? 9 : 12,
                      height: size < 150 ? 9 : 12,
                      child: const CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(width: size < 150 ? 4 : 6),
                    Flexible(
                      child: Text(
                        msg.processingStep!,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: size < 150 ? 9 : 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ],
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
                    return SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.textPrimary,
                      ),
                    );
                  }
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() {});
                  });
                  return Icon(
                    _iconForFileName(msg.fileName),
                    color: AppColors.textPrimary,
                    size: 28,
                  );
                },
              )
            else
              Icon(Icons.download, color: AppColors.textPrimary, size: 28),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    msg.fileName ?? msg.text,
                    style: TextStyle(color: AppColors.textPrimary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  _formatFileSize(msg.fileSize),
                  style: TextStyle(color: AppColors.textMuted, fontSize: 11),
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
                  return SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.textPrimary,
                    ),
                  );
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() {});
                });
                return Icon(
                  msg.isFile ? _iconForFileName(msg.fileName) : Icons.image,
                  color: AppColors.textPrimary,
                  size: 28,
                );
              },
            )
          else
            Icon(Icons.download, color: AppColors.textPrimary, size: 28),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  msg.isFile
                      ? (msg.fileName ?? msg.text)
                      : '📷 ${tr('media.photo')}',
                  style: TextStyle(color: AppColors.textPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                _formatFileSize(msg.fileSize),
                style: TextStyle(color: AppColors.textMuted, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Иконка по расширению имени файла — тот же принцип, что у файлового
  /// менеджера ОС: PDF показывает PDF-иконку, картинка — иконку картинки и
  /// т.д., а не одну и ту же "просто лист" на всё подряд.
  IconData _iconForFileName(String? fileName) {
    final dot = fileName?.lastIndexOf('.') ?? -1;
    if (fileName == null || dot == -1 || dot == fileName.length - 1) {
      return Icons.insert_drive_file;
    }
    switch (fileName.substring(dot + 1).toLowerCase()) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
      case 'odt':
      case 'rtf':
        return Icons.description;
      case 'xls':
      case 'xlsx':
      case 'csv':
      case 'ods':
        return Icons.table_chart;
      case 'ppt':
      case 'pptx':
      case 'odp':
        return Icons.slideshow;
      case 'txt':
        return Icons.article;
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
        return Icons.folder_zip;
      case 'mp3':
      case 'wav':
      case 'm4a':
      case 'aac':
      case 'flac':
      case 'ogg':
        return Icons.audiotrack;
      case 'mp4':
      case 'mov':
      case 'avi':
      case 'mkv':
      case 'webm':
      case '3gp':
        return Icons.videocam;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'webp':
      case 'heic':
      case 'bmp':
        return Icons.image;
      case 'apk':
        return Icons.android;
      case 'json':
      case 'xml':
      case 'html':
      case 'css':
      case 'js':
      case 'dart':
      case 'py':
      case 'java':
      case 'kt':
      case 'c':
      case 'cpp':
        return Icons.code;
      default:
        return Icons.insert_drive_file;
    }
  }

  Widget _clickableFileRow(StoredMessage msg, {double size = 220}) {
    final sending = msg.isMine && msg.processingStep != null;
    final failed = msg.isMine && msg.status == 'failed';
    final icon = failed ? Icons.error_outline : _iconForFileName(msg.fileName);
    final tappable = !sending && !failed;

    if (size < 200) {
      return InkWell(
        onTap: tappable ? () => _openFile(msg) : null,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            color: failed ? Colors.redAccent : AppColors.textMuted,
            size: 32,
          ),
        ),
      );
    }
    return InkWell(
      onTap: tappable ? () => _openFile(msg) : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            color: failed ? Colors.redAccent : _bubbleTextColor(msg.isMine),
            size: 28,
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  msg.fileName ?? msg.text,
                  style: TextStyle(color: _bubbleTextColor(msg.isMine)),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (sending)
                Text(
                  msg.processingStep!,
                  style: TextStyle(
                    color: _bubbleTextColor(msg.isMine).withValues(alpha: 0.7),
                    fontSize: 11,
                  ),
                )
              else if (failed)
                Text(
                  tr('error.uploadFailed'),
                  style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                ),
            ],
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
        label =
            '${tr('call.answered')} · '
            '${_formatCallDuration(msg.callDurationSeconds ?? 0)}';
        break;
      case 'missed':
        icon = Icons.call_missed;
        label = tr('call.missed');
        break;
      case 'no_answer':
      default:
        icon = Icons.call_made;
        label = tr('call.noAnswer');
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
              color: isMissedOrNoAnswer
                  ? Colors.redAccent
                  : AppColors.textMuted,
            ),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: AppColors.textPrimary)),
            const SizedBox(width: 6),
            Text(
              formatChatTime(msg.timestamp),
              style: TextStyle(color: AppColors.textMuted, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIconFor(String status, {bool onColoredBubble = true}) {
    switch (status) {
      case 'failed':
        return const Icon(
          Icons.error_outline,
          size: 13,
          color: Colors.redAccent,
        );
      case 'sending':
      case 'queued':
        return Icon(
          Icons.schedule,
          size: 13,
          color: onColoredBubble ? Colors.white70 : AppColors.textMuted,
        );
      case 'read':
        return const Icon(Icons.done_all, size: 13, color: Colors.white);
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

  // onColoredBubble=false — для видео-кружков: у них, в отличие от
  // остальных типов сообщений, НЕТ своего цветного фона-пузыря (см.
  // _buildVideoNoteBubble), эта строка лежит прямо на фоне чата — значит,
  // и "свой"/"чужой" тут ни при чём, цвет должен быть просто theme-aware,
  // как и сам фон под ней.
  Widget _buildMetaRow(StoredMessage msg, {bool onColoredBubble = true}) {
    final mutedColor = onColoredBubble
        ? _bubbleMutedColor(msg.isMine)
        : AppColors.textMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (msg.edited) ...[
          Icon(Icons.edit, size: 11, color: mutedColor),
          const SizedBox(width: 3),
        ],
        Text(
          formatChatTime(msg.timestamp),
          style: TextStyle(color: mutedColor, fontSize: 10),
        ),
        if (msg.isMine) ...[
          const SizedBox(width: 4),
          _buildStatusIconFor(msg.status, onColoredBubble: onColoredBubble),
        ],
      ],
    );
  }

  /// Время+статус — ВСЕГДА отдельной строкой под текстом, прижатой к
  /// правому краю, точно так же, как у голосовых/видео/фото сообщений —
  /// единое поведение для всех типов, а не только для текста, у которого
  /// раньше было отдельное "умное" встраивание в конец последней строки.
  Widget _buildTextWithMeta(StoredMessage msg, double maxTextWidth) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxTextWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildLinkifiedText(
            msg.text,
            _bubbleTextColor(msg.isMine),
            isMine: msg.isMine,
          ),
          const SizedBox(height: 2),
          _buildMetaRow(msg),
        ],
      ),
    );
  }

  // Ссылка целиком, от http(s):// или www. до ближайшего пробела/переноса
  // строки — намеренно простое правило (как у большинства мессенджеров):
  // ловит подавляющее большинство реальных ссылок, не пытаясь быть
  // формально полным URL-парсером RFC 3986.
  static final _urlRegex = RegExp(
    r'((https?:\/\/)|(www\.))[^\s]+',
    caseSensitive: false,
  );

  /// Тот же текст, что обычный Text(msg.text), но ссылки внутри —
  /// подчёркнутые и кликабельные (см. _openLink). Единая точка для обоих
  /// мест, где рендерится текст сообщения (одиночный пузырь и подпись в
  /// групповом), см. _buildGroupBubble.
  Widget _buildLinkifiedText(
    String text,
    Color baseColor, {
    required bool isMine,
    double fontSize = 16,
  }) {
    final matches = _urlRegex.allMatches(text).toList();
    if (matches.isEmpty) {
      return Text(
        text,
        style: TextStyle(color: baseColor, fontSize: fontSize),
      );
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in matches) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final url = match.group(0)!;
      spans.add(
        TextSpan(
          text: url,
          style: TextStyle(color: _linkColor(isMine)),
          recognizer: TapGestureRecognizer()..onTap = () => _openLink(url),
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return Text.rich(
      TextSpan(
        style: TextStyle(color: baseColor, fontSize: fontSize),
        children: spans,
      ),
    );
  }

  Future<void> _openLink(String rawUrl) async {
    final normalized =
        rawUrl.startsWith(RegExp(r'https?:\/\/', caseSensitive: false))
        ? rawUrl
        : 'https://$rawUrl';
    final uri = Uri.tryParse(normalized);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Нет приложения, способного открыть ссылку, или запрет от ОС —
      // молча игнорируем, как и остальные best-effort действия в этом файле.
    }
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
    _groupIdsByRepId[targetMsg.messageId] = ids;
    final isSelected = _selectedMessageIds.contains(targetMsg.messageId);
    // RepaintBoundary — снимок именно этого пузыря нужен, если сообщение
    // удалят: см. _captureShatterImages в _deleteMessages.
    final shatterKey = _shatterBoundaryKeys.putIfAbsent(
      targetMsg.messageId,
      () => GlobalKey(),
    );
    // Пока идёт particle-shatter анимация удаления этого пузыря (см.
    // _deleteMessages) — он невидим, но НЕ убран из дерева: Opacity 0
    // держит за собой прежний размер/место в ленте, а частицы летят прямо
    // поверх него, создавая впечатление, что сообщение само рассыпалось.
    final isDissolving = _dissolvingMessageIds.contains(targetMsg.messageId);
    final content = RepaintBoundary(
      key: shatterKey,
      child: IgnorePointer(
        ignoring: isDissolving,
        child: Opacity(
          opacity: isDissolving ? 0 : 1,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              bubble,
              _reactionBadges(myReaction, peerReaction, isMine),
            ],
          ),
        ),
      ),
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
    // активен, просто переключает выбор этого сообщения/группы. Дальше,
    // не отрывая палец, можно провести им вверх/вниз по другим сообщениям —
    // при входе в каждое новое (см. _messageRepIdAtGlobalPosition) оно тоже
    // переключается, а повторный проход по уже выделенному снимает выбор —
    // ровно так же, как обычный тап по сообщению в режиме выбора.
    void handleLongPressStart(LongPressStartDetails details) {
      _pendingTapTimer?.cancel();
      _pendingTapTimer = null;
      _lastTapMessageId = null;
      _lastTapTime = null;
      if (_selectionMode) {
        _toggleGroupSelected(ids);
      } else {
        _enterSelectionMode(targetMsg, groupMessageIds: groupMessageIds);
      }
      _dragSelectLastHoverId = targetMsg.messageId;
    }

    void handleLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
      if (!_selectionMode) return;
      final hoveredRepId = _messageRepIdAtGlobalPosition(
        details.globalPosition,
      );
      if (hoveredRepId == null || hoveredRepId == _dragSelectLastHoverId) {
        return;
      }
      _dragSelectLastHoverId = hoveredRepId;
      _toggleGroupSelected(_groupIdsByRepId[hoveredRepId] ?? [hoveredRepId]);
    }

    void handleLongPressEnd(LongPressEndDetails details) {
      _dragSelectLastHoverId = null;
    }

    // Пустой распорщик, забирающий всё оставшееся место по горизонтали —
    // ЗАФИКСИРОВАННОЙ (нулевой) собственной высоты, а не "растянутый на всю
    // высоту": внутри ListView высота элемента ничем не ограничена сверху,
    // и виджет, пытающийся заполнить именно эту ось целиком (как раньше
    // делал SizedBox.expand()), получает бесконечное ограничение и падает.
    // Высоту всей строки и так задаёт сам пузырь (content) — распорщику
    // подстраиваться под неё незачем.
    const filler = Expanded(child: SizedBox.shrink());

    // Слот галочки присутствует в Row ВСЕГДА (просто нулевой ширины вне
    // режима выбора), а не появляется/исчезает мгновенно вместе с
    // _selectionMode — AnimatedSize плавно раздвигает/схлопывает под него
    // место, а не дёргает пузырь в сторону одним кадром. Сама галочка
    // внутри при этом ещё и влетает сдвигом (см. _SelectionCheckmark) —
    // оба эффекта складываются.
    final selectionSlot = AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      child: _selectionMode
          ? _buildSelectionCheck(isSelected, isMine)
          : const SizedBox.shrink(),
    );

    final row = Row(
      // .center — не .end: галочка выбора должна стоять по вертикальному
      // центру сообщения, а не липнуть к его нижнему краю (у content
      // единственного child'а с реальной высотой это никак не смещает сам
      // пузырь, потому что высота строки и так равна его высоте).
      crossAxisAlignment: CrossAxisAlignment.center,
      children: isMine
          ? [filler, content, selectionSlot]
          : [selectionSlot, content, filler],
    );

    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) => tapDownPosition = details.globalPosition,
        onTap: handleTap,
        onLongPressStart: handleLongPressStart,
        onLongPressMoveUpdate: handleLongPressMoveUpdate,
        onLongPressEnd: handleLongPressEnd,
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
          left: BorderSide(color: _bubbleMutedColor(msg.isMine), width: 3),
        ),
      ),
      child: Text(
        msg.replyToPreview!,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: _bubbleMutedColor(msg.isMine), fontSize: 12),
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
    final allRead = group.every((m) => m.status == 'read');
    final aggregateStatus = hasFailed
        ? 'failed'
        : (hasPending ? 'sending' : (allRead ? 'read' : 'sent'));
    final maxWidth = MediaQuery.of(context).size.width * 0.72;
    final repMsg = textMsgs.isNotEmpty ? textMsgs.first : group.first;
    final key = _messageKeys.putIfAbsent(repMsg.messageId, () => GlobalKey());

    final isHighlighted = group.any(
      (m) => m.messageId == _highlightedMessageId,
    );
    final content = Column(
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
                child: _buildLinkifiedText(
                  textMsgs.first.text,
                  _bubbleTextColor(isMine),
                  isMine: isMine,
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
              style: TextStyle(color: _bubbleMutedColor(isMine), fontSize: 10),
            ),
            if (isMine) ...[
              const SizedBox(width: 4),
              _buildStatusIconFor(aggregateStatus),
            ],
          ],
        ),
      ],
    );
    final bubbleColor = isMine ? AppColors.primary : AppColors.surface;
    // card — сам видимый цветной пузырь БЕЗ отступа-margin (он вынесен на
    // уровень bubble ниже) — так подсветка (см. _PulsingHighlight) облегает
    // РОВНО видимые края пузыря, а не ещё и пустое поле margin вокруг него.
    final card = isHighlighted
        ? _PulsingHighlight(
            baseColor: bubbleColor,
            borderRadius: BorderRadius.circular(14),
            padding: const EdgeInsets.all(6),
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: content,
          )
        : Container(
            padding: const EdgeInsets.all(6),
            constraints: BoxConstraints(maxWidth: maxWidth),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: content,
          );
    final bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: card,
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

  /// Видео-сообщение сознательно рендерится БЕЗ обычного цветного пузыря
  /// (как и у Телеги — кружок/квадрат плавает сам по себе): это заодно и
  /// единственный вменяемый способ дать ему расширяться на всю ширину чата
  /// при проигрывании, не воюя с паддингами фиксированного пузыря.
  Widget _buildVideoNoteBubble(StoredMessage msg) {
    final expandedSize = MediaQuery.of(context).size.width - 32;
    return Column(
      crossAxisAlignment: msg.isMine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        VideoNotePlayer(
          resolveFile: () => _resolveRecordedMediaFile(msg),
          durationMs: msg.durationMs,
          expandedSize: expandedSize,
          processingStep: msg.processingStep,
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: _buildMetaRow(msg, onColoredBubble: false),
        ),
      ],
    );
  }

  Widget _buildMessageBubble(StoredMessage msg) {
    if (msg.isCallLog) {
      return KeyedSubtree(
        key: ValueKey(msg.messageId),
        child: _buildCallLogRow(msg),
      );
    }
    final key = _messageKeys.putIfAbsent(msg.messageId, () => GlobalKey());

    if (msg.isVideoNote) {
      return KeyedSubtree(
        key: ValueKey(msg.messageId),
        child: _wrapInteractive(
          msg,
          bubble: _buildVideoNoteBubble(msg),
          isMine: msg.isMine,
          myReaction: msg.myReaction,
          peerReaction: msg.peerReaction,
          key: key,
        ),
      );
    }

    final maxTextWidth = MediaQuery.of(context).size.width * 0.65;
    final isHighlighted = msg.messageId == _highlightedMessageId;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildReplyPreview(msg),
        msg.isVoice
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  VoiceMessagePlayer(
                    isMine: msg.isMine,
                    durationMs: msg.durationMs,
                    processingStep: msg.processingStep,
                    resolveFile: () => _resolveRecordedMediaFile(msg),
                  ),
                  const SizedBox(height: 4),
                  _buildMetaRow(msg),
                ],
              )
            : msg.isMedia
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildAttachmentBubble(msg),
                  const SizedBox(height: 4),
                  _buildMetaRow(msg),
                ],
              )
            : _buildTextWithMeta(msg, maxTextWidth),
      ],
    );
    final bubbleColor = msg.isMine ? AppColors.primary : AppColors.surface;
    // card — сам видимый цветной пузырь БЕЗ margin (см. комментарий в
    // _buildGroupBubble) — margin вынесен в bubble ниже, чтобы подсветка
    // облегала ровно видимые края, а не пустое поле вокруг них.
    final card = isHighlighted
        ? _PulsingHighlight(
            baseColor: bubbleColor,
            borderRadius: BorderRadius.circular(14),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: content,
          )
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: content,
          );
    final bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: card,
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
    _keyboardHeightSettleTimer?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    // Если пользователь ушёл с экрана прямо посреди записи — обрываем её
    // молча, не оставляя висящий микрофон/камеру и временный файл.
    _recTicker?.cancel();
    if (_recCameraController != null) {
      final controller = _recCameraController;
      unawaited(() async {
        try {
          if (controller!.value.isRecordingVideo) {
            final xfile = await controller.stopVideoRecording();
            final f = File(xfile.path);
            if (await f.exists()) await f.delete();
          }
        } catch (_) {}
        await controller!.dispose();
      }());
    }
    unawaited(_audioRecorder.cancel());
    unawaited(_audioRecorder.dispose());
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
    if (!_isNotes) {
      WebSocketService.instance.unsubscribePresence(_currentPeerDeviceId);
    }
    _presenceSub?.cancel();
    _wsStatusSub?.cancel();
    _blockStatusSub?.cancel();
    _presenceTickTimer?.cancel();
    _peerTypingClearTimer?.cancel();
    super.dispose();
  }

  /// Общая "таблетка" плавающей шапки — тот же приём (блюр + полупрозрачная
  /// поверхность + тонкая рамка), что и у BottomActionBar снизу, единый
  /// визуальный язык обеих плавающих панелей.
  Widget _headerPill({required Widget child, EdgeInsetsGeometry? padding}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding:
              padding ??
              const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: AppColors.textMuted.withValues(alpha: 0.18),
            ),
          ),
          child: child,
        ),
      ),
    );
  }

  /// Обычная (не выбор/не поиск) шапка — три плавающие "таблетки": круглая
  /// кнопка "назад" слева, овальная с профилем собеседника по ЦЕНТРУ ШИРИНЫ
  /// ЭКРАНА (а не просто между соседних элементов — поэтому Stack с
  /// Positioned, а не Row, см. ТЗ пользователя), и овальная с
  /// звонком+меню справа. Всё вокруг — прозрачно, список сообщений
  /// просвечивает.
  Widget _buildFloatingChatHeader() {
    final topInset = MediaQuery.of(context).padding.top;
    // Компактные IconButton (как у панели ввода снизу — padding 8,
    // BoxConstraints() без минимума, VisualDensity.compact), а не
    // стандартный 48x48 минимальный тап-таргет Material — тот был заметно
    // выше самой таблетки с логином+статусом (у неё бывает две строки
    // текста) и обрезался её высотой, отсюда и "BOTTOM OVERFLOWED" на
    // скриншоте, и визуально срезанные кружки на скрине пользователя.
    const iconPadding = EdgeInsets.all(8);
    const iconConstraints = BoxConstraints();
    return Padding(
      key: const ValueKey('normal_header'),
      padding: EdgeInsets.only(top: topInset + 8, bottom: 8),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.55,
              ),
              child: _headerPill(
                child: DefaultTextStyle(
                  style: TextStyle(color: AppColors.textPrimary),
                  child: _buildAppBarTitle(),
                ),
              ),
            ),
          ),
          Positioned(
            left: 12,
            child: _headerPill(
              padding: EdgeInsets.zero,
              child: IconButton(
                padding: iconPadding,
                constraints: iconConstraints,
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
                onPressed: () =>
                    _handleBackAction(emojiOnlyVisible: _emojiMode),
              ),
            ),
          ),
          Positioned(
            right: 12,
            child: _headerPill(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_isNotes)
                    IconButton(
                      padding: iconPadding,
                      constraints: iconConstraints,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.call_outlined,
                        color: AppColors.textPrimary,
                      ),
                      onPressed: _isPeerDeleted || _composerBlocked
                          ? null
                          : _startCall,
                    ),
                  PopupMenuButton<String>(
                    padding: iconPadding,
                    icon: Icon(Icons.more_vert, color: AppColors.textPrimary),
                    onSelected: (value) {
                      if (value == 'search') _enterSearchMode();
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'search',
                        child: Row(
                          children: [
                            const Icon(Icons.search),
                            const SizedBox(width: 10),
                            Text(tr('chat.searchAction')),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Шапка режима выбора сообщений — раньше жила в Scaffold.appBar как
  /// обычный AppBar; сам AppBar прекрасно работает и как самостоятельный
  /// виджет (сам себя высотой считает, сам добавляет отступ под статус-бар)
  /// — визуально ничего не поменялось, просто теперь это оверлей в body, а
  /// не Scaffold-слот (единый механизм с обычной и поисковой шапками, см.
  /// _buildFloatingChatHeader/_buildSearchHeader).
  Widget _buildSelectionHeader() {
    return AppBar(
      key: const ValueKey('selection_header'),
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _exitSelectionMode,
      ),
      title: Text('${tr('chat.selectedCount')}: ${_selectedMessageIds.length}'),
      actions: [
        IconButton(
          icon: const Icon(Icons.copy_outlined),
          onPressed: _selectedMessageIds.isEmpty ? null : _copySelectedTexts,
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
    );
  }

  /// Шапка режима поиска — тот же плавающий стиль, что и у обычной шапки
  /// (см. _buildFloatingChatHeader/_headerPill): кружок "назад" + овальное
  /// поле поиска, оба непрозрачны сами по себе, а вокруг них (и между
  /// ними) — прозрачно, список сообщений просвечивает (раньше тут была
  /// сплошная непрозрачная полоса на всю ширину — см. ТЗ пользователя).
  Widget _buildSearchHeader() {
    final topInset = MediaQuery.of(context).padding.top;
    return Padding(
      key: const ValueKey('search_header'),
      padding: EdgeInsets.only(
        top: topInset + 8,
        left: 12,
        right: 12,
        bottom: 8,
      ),
      child: Row(
        children: [
          _headerPill(
            padding: EdgeInsets.zero,
            child: IconButton(
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(),
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
              onPressed: _exitSearchMode,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _headerPill(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              // isDense — штатный способ сделать поле компактным без
              // "коробочной" модели InputDecorator, из-за которой курсор/
              // текст иначе плавают непредсказуемо внутри невысокой
              // таблетки.
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                autofocus: true,
                onChanged: _onSearchQueryChanged,
                textAlignVertical: TextAlignVertical.center,
                style: TextStyle(color: AppColors.textPrimary, fontSize: 15),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  border: InputBorder.none,
                  hintText: tr('chat.searchHint'),
                  hintStyle: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Заголовок обычной (не выбора) шапки чата — логин собеседника, а под
  /// ним, по центру, статус: "печатает…" / "в сети" / когда был последний
  /// раз (см. formatPresenceStatus). Для "Заметок" статуса нет и не будет —
  /// это переписка с самим собой, там нечему быть "в сети".
  Widget _buildAppBarTitle() {
    final title = Text(
      _isNotes
          ? tr('home.notes')
          : (_isPeerDeleted ? tr('home.deletedAccount') : widget.peerLogin),
    );

    final Widget textColumn;
    if (_isNotes || _isPeerDeleted) {
      textColumn = title;
    } else {
      final status = formatPresenceStatus(
        typing: _peerTyping,
        online: _peerOnline,
        lastSeenMs: _peerLastSeenMs,
      );
      textColumn = status.isEmpty
          ? title
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                title,
                Text(
                  status,
                  style: TextStyle(
                    fontSize: 12,
                    color: _peerTyping
                        ? AppColors.primary
                        : Theme.of(
                            context,
                          ).appBarTheme.foregroundColor?.withValues(alpha: 0.7),
                  ),
                ),
              ],
            );
    }

    // Удалённому аккаунту аватарку показывать незачем — его фото сервер
    // всё равно уже не отдаст, а заглушка тут выглядела бы лишней.
    if (_isPeerDeleted) return textColumn;

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildHeaderAvatar(),
        const SizedBox(width: 8),
        Flexible(child: textColumn),
      ],
    );

    // "Заметки" — это ты сам, открывать отдельный "чужой профиль" тут
    // бессмысленно (и там нет peerAccountId в смысле, ожидаемом
    // PeerProfileScreen/Hero-тегом ниже).
    if (_isNotes) return row;

    return InkWell(
      onTap: () => Navigator.push(
        context,
        HeroZoomPageRoute(
          builder: (_) => PeerProfileScreen(
            peerAccountId: widget.peerAccountId,
            peerLogin: widget.peerLogin,
          ),
        ),
      ),
      child: row,
    );
  }

  Widget _buildHeaderAvatar() {
    if (_isNotes) {
      return ValueListenableBuilder<Uint8List?>(
        valueListenable: MyAvatarStore.notifier,
        builder: (context, bytes, _) =>
            AvatarThumbnail(bytes: bytes, radius: 16),
      );
    }
    return Hero(
      tag: 'peer-avatar-${widget.peerAccountId}',
      child: CachedAvatarImage(accountId: widget.peerAccountId, radius: 16),
    );
  }

  Widget _buildPinnedBanner() {
    final pinnedId = _pinnedMessageId;
    if (pinnedId == null) return const SizedBox.shrink();
    final matches = _messages.where((m) => m.messageId == pinnedId).toList();
    final preview = matches.isNotEmpty
        ? (matches.first.isMedia
              ? (matches.first.isFile
                    ? '📎 ${tr('media.file')}'
                    : '📷 ${tr('media.photo')}')
              : matches.first.text)
        : tr('chat.pinnedMessage');
    return InkWell(
      onTap: () => _scrollToMessage(pinnedId),
      child: Container(
        width: double.infinity,
        color: AppColors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.push_pin, size: 16, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                preview,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppColors.textPrimary, fontSize: 13),
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
              style: TextStyle(color: AppColors.textPrimary, fontSize: 13),
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 18, color: AppColors.textMuted),
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
        text: tr('chat.editingMessage'),
        onClose: _cancelEdit,
      );
    }
    if (_replyTarget != null) {
      final target = _replyTarget!;
      final preview = target.isVoice
          ? '🎤 ${tr('media.voiceNote')}'
          : target.isVideoNote
          ? '🎥 ${tr('media.videoNote')}'
          : target.isMedia
          ? (target.isFile
                ? '📎 ${tr('media.file')}'
                : '📷 ${tr('media.photo')}')
          : target.text;
      return _bannerRow(
        icon: Icons.reply,
        text: '${tr('action.reply')}: $preview',
        onClose: _cancelReply,
      );
    }
    final forwarding = _forwardingTexts;
    if (forwarding != null && forwarding.isNotEmpty) {
      return _bannerRow(
        icon: Icons.forward,
        text: '${tr('chat.forwardingCount')}: ${forwarding.length}',
        onClose: () => setState(() => _forwardingTexts = null),
      );
    }
    return const SizedBox.shrink();
  }

  /// Панель управления поиском — "прилеплена" к клавиатуре (занимает то же
  /// место в Column, что и обычный композер, см. build()): счётчик
  /// N1/N2 слева, кнопки перехода к следующему/предыдущему совпадению
  /// строго по центру (только в режиме "chat"), переключатель
  /// "Show as list"/"Show as chat" справа.
  Widget _buildSearchControlPanel() {
    final hasMatches = _searchMatches.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SizedBox(
        height: 52,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '$_searchCurrentNumber/$_searchTotalCount',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (!_searchShowAsList)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildSearchNavButton(
                    Icons.keyboard_arrow_down,
                    hasMatches ? _searchGoNext : null,
                  ),
                  const SizedBox(width: 14),
                  _buildSearchNavButton(
                    Icons.keyboard_arrow_up,
                    hasMatches ? _searchGoPrev : null,
                  ),
                ],
              ),
            Align(
              alignment: Alignment.centerRight,
              child: _buildShowAsToggle(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchNavButton(IconData icon, VoidCallback? onTap) {
    return Material(
      color: AppColors.surface,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(
            icon,
            size: 30,
            color: onTap == null ? AppColors.textMuted : AppColors.textPrimary,
          ),
        ),
      ),
    );
  }

  Widget _buildShowAsToggle() {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => setState(() => _searchShowAsList = !_searchShowAsList),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          child: Text(
            _searchShowAsList ? tr('chat.showAsChat') : tr('chat.showAsList'),
            style: TextStyle(
              color: AppColors.primary,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  /// Режим "list" — все совпадения одним списком, новые сверху (как в
  /// строке поиска Телеграма); тап закрывает список и переносит к
  /// сообщению в самом чате (см. _selectSearchResult).
  Widget _buildSearchResultsList() {
    final matches = _searchMatches.reversed.toList();
    if (matches.isEmpty) {
      return Center(
        child: Text(
          tr('chat.searchNoResults'),
          style: TextStyle(color: AppColors.textMuted),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: matches.length,
      itemBuilder: (context, index) {
        final msg = matches[index];
        return ListTile(
          title: Text(
            msg.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppColors.textPrimary),
          ),
          subtitle: Text(
            formatChatTime(msg.timestamp),
            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
          onTap: () => _selectSearchResult(msg),
        );
      },
    );
  }

  /// Общая точка для системного back (см. PopScope) — в режиме выбора
  /// снимает выбор, при открытой только эмодзи-панели закрывает её, иначе
  /// уходит из чата. Интерактивный свайп-назад из любой точки экрана
  /// сознательно НЕ реализован отдельным жестом — он конфликтовал бы за
  /// одни и те же горизонтальные тачи с нативным edge-свайпом
  /// CupertinoPageRoute (см. навигацию к ChatScreen), который уже даёт
  /// живой, управляемый пальцем переход, просто только от края экрана.
  void _handleBackAction({required bool emojiOnlyVisible}) {
    if (_closeContextMenu != null) {
      _closeContextMenu!();
    } else if (_selectionMode) {
      _exitSelectionMode();
    } else if (_searchMode) {
      _exitSearchMode();
    } else if (emojiOnlyVisible) {
      setState(() => _emojiMode = false);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ThemeReactive(builder: (context) => _build(context));
  }

  Widget _build(BuildContext context) {
    final realInset = MediaQuery.of(context).viewInsets.bottom;
    final keyboardVisible = realInset > 50;
    // Настоящий (не занулённый клавиатурой) отступ до жестовой зоны ОС —
    // см. комментарий у зазора-спейсера ниже про то, почему брать его надо
    // ИМЕННО отсюда, а не из MediaQuery.padding.
    final systemBottomInset = MediaQuery.of(context).viewPadding.bottom;
    // Диагностика для жалобы "на Samsung с 3-кнопочной навигацией панель
    // сообщения перекрыта системной панелью" — на Pixel (gesture-навигация)
    // такого не воспроизвели, а слепой переход на SafeArea тут неверен
    // (сознательно отключён чуть ниже — он ломает высоту эмодзи-панели,
    // см. комментарий у зазора-спейсера). Логируем только при реальном
    // изменении значения, а не на каждый build(), чтобы не забить лог.
    if (_lastLoggedBottomInset != systemBottomInset) {
      _lastLoggedBottomInset = systemBottomInset;
      DebugLog.log(
        'Chat composer systemBottomInset=$systemBottomInset '
        'padding.bottom=${MediaQuery.of(context).padding.bottom} '
        'viewInsets.bottom=$realInset',
      );
    }

    // Измеряем высоту клавиатуры только когда она перестала МЕНЯТЬСЯ —
    // во время собственной анимации выезда ОС на некоторых устройствах
    // (замечено на Pixel 7) realInset несколько кадров подряд идёт с
    // забросом выше финального значения, и если хватать первый же кадр
    // "выше текущего known-значения" (как было раньше), в кэш улетает
    // именно этот заброс, а не настоящая итоговая высота — из-за этого
    // высота панели эмодзи (которая берёт значение из кэша) переставала
    // совпадать с реальной высотой клавиатуры. Поэтому здесь просто
    // ждём _keyboardHeightSettleDelay без новых кадров с этим realInset,
    // и то, что "устоялось", и фиксируем как настоящую высоту — не только
    // ратчетим вверх, а именно замещаем, чтобы старое завышенное значение
    // тоже само исправлялось.
    if (keyboardVisible) {
      _keyboardHeightSettleTimer?.cancel();
      _keyboardHeightSettleTimer = Timer(_keyboardHeightSettleDelay, () {
        if (!mounted) return;
        final settled = MediaQuery.of(context).viewInsets.bottom;
        if (settled <= 50) return;
        if ((settled - _keyboardHeight).abs() > 1) {
          setState(() => _keyboardHeight = settled);
        }
        KeyboardHeightStore.updateKnownHeight(settled);
      });
    }

    // Клавиатура и эмодзи-панель никогда не показываются одновременно и
    // занимают ОДНО и то же, ЗАРАНЕЕ известное место — заранее измеренную
    // (и закэшированную, см. _keyboardHeight/KeyboardHeightStore) высоту
    // клавиатуры, а НЕ живое значение realInset. Раз высота фиксирована и
    // общая для обеих панелей, между ними никогда не может быть скачка.
    // _awaitingKeyboardOpen — see handler below: короткий зазор между тапом
    // по иконке клавиатуры и моментом, когда настоящая клавиатура реально
    // поднимется (realInset превысит порог) — без него на эти несколько
    // кадров обе панели считались бы закрытыми и резерв на миг схлопнулся.
    if (_awaitingKeyboardOpen && keyboardVisible) {
      _awaitingKeyboardOpen = false;
    }
    // realInset — глобальное значение на всё приложение: если поверх этого
    // экрана открыт другой modal (например, подпись к фото в шторке
    // вложений) и клавиатура поднята ТАМ, keyboardVisible всё равно
    // становится true и здесь, хотя к полю ввода этого чата это не имеет
    // отношения — без явной проверки фокуса именно нашего текстового поля
    // чат под шторкой сам "поджимался" бы, будто открыли его собственную
    // клавиатуру.
    final anyPanelOpen =
        (keyboardVisible &&
            (_textFocusNode.hasFocus || _searchFocusNode.hasFocus)) ||
        _emojiMode ||
        _awaitingKeyboardOpen;
    final reserved = anyPanelOpen ? _keyboardHeight : 0.0;

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
      canPop:
          _closeContextMenu == null &&
          !_emojiMode &&
          !_selectionMode &&
          !_searchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBackAction(emojiOnlyVisible: _emojiMode);
      },
      child: SwipeBackDetector(
        enabled: !_emojiMode && !_selectionMode && !_searchMode,
        onBlockedSwipe: () => _handleBackAction(emojiOnlyVisible: _emojiMode),
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          // Шапки больше нет как Scaffold.appBar — весь заголовок стал
          // плавающим оверлеем ПОВЕРХ списка сообщений (см. Positioned в
          // body ниже), тем же способом и по тем же причинам, что и панель
          // ввода снизу (см. ТЗ пользователя про единый стиль: только сами
          // "таблетки" непрозрачны, всё остальное — просвечивает чат).
          appBar: null,
          body: Stack(
            key: _bodyStackKey,
            children: [
              Column(
                children: [
                  Expanded(
                    // Список не строится, пока _bootstrapHistory() не узнает
                    // сохранённую позицию — иначе он БЫ построился с нуля,
                    // пользователь увидел бы это на один кадр, и только потом
                    // прыгнул бы туда, где был (тот самый "мигает" баг).
                    // Пустая область на эти несколько миллисекунд куда менее
                    // заметна, чем видимый прыжок по уже отрисованному списку.
                    child: _searchMode && _searchShowAsList
                        ? _buildSearchResultsList()
                        : !_scrollReady
                        ? const SizedBox.shrink()
                        : Builder(
                            builder: (context) {
                              final groups = _groupedMessages();
                              return ListView.builder(
                                controller: _scrollController,
                                // Снизу — не просто 16 (как раньше), а ещё и
                                // высота непрозрачной части плавающей панели
                                // ввода (овальная "таблетка" + резерв под
                                // клавиатуру/эмодзи, когда открыты) — список
                                // теперь во весь рост Stack'а, а не сосед
                                // панели в Column (см. ниже, где эта же
                                // панель стала Positioned(bottom: 0) поверх
                                // него). НЕ добавляем сюда сам зазор-спейсер
                                // (5 + systemBottomInset) — его прозрачность
                                // и есть весь смысл (см. ТЗ пользователя):
                                // именно в этой узкой полосе должны быть
                                // видны кусочки сообщений, а не отступ под
                                // них.
                                padding: EdgeInsets.fromLTRB(
                                  16,
                                  16 + MediaQuery.of(context).padding.top + 60,
                                  16,
                                  16 + 64 + reserved,
                                ),
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
                ],
              ),
              // Шапка — плавающий оверлей ПОВЕРХ списка сообщений, тот же
              // приём, что и у панели ввода снизу (см. ниже): три овальные
              // "таблетки" (назад / профиль собеседника / звонок+меню), а
              // всё вокруг них прозрачно — список сообщений просвечивает в
              // промежутках между ними и по краям. Переключение между
              // обычным видом, режимом выбора и поиском — тот же
              // AnimatedSwitcher, что раньше жил в Scaffold.appBar, просто
              // теперь как оверлей в body, а не отдельный слот Scaffold'а
              // (тот менялся бы мгновенно без анимации при появлении/
              // исчезновении — см. аналогичный фикс на экране чатов/
              // настроек/профиля).
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) {
                    if (child.key == const ValueKey('search_header')) {
                      return ClipRect(
                        child: FractionallySizedBox(
                          alignment: Alignment.centerRight,
                          widthFactor: animation.value.clamp(0.0, 1.0),
                          child: FadeTransition(
                            opacity: animation,
                            child: child,
                          ),
                        ),
                      );
                    }
                    return FadeTransition(opacity: animation, child: child);
                  },
                  child: _selectionMode
                      ? _buildSelectionHeader()
                      : _searchMode
                      ? _buildSearchHeader()
                      : _buildFloatingChatHeader(),
                ),
              ),
              // Баннер звонка/закреплённого сообщения — раньше был частью
              // того же Column, что и список (и потому естественно оказывался
              // ПОД Scaffold.appBar). Теперь список — самостоятельный
              // full-height Positioned (см. выше, Expanded внутри Column
              // больше не начинается ниже шапки — иначе список снова не
              // заходил бы под неё, а весь смысл этой правки как раз в
              // обратном). Баннеры поэтому — свой отдельный Positioned, НЕ
              // влияющий на позицию списка, просто отступающий от верха на
              // высоту шапки, чтобы не оказаться под её "таблетками".
              if (!_isNotes || _pinnedMessageId != null)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 60,
                  left: 0,
                  right: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!_isNotes)
                        OngoingCallBanner(peerLogin: widget.peerLogin),
                      if (_pinnedMessageId != null) _buildPinnedBanner(),
                    ],
                  ),
                ),
              // Панель ввода — плавающий оверлей ПОВЕРХ списка сообщений
              // (см. ТЗ пользователя: список должен быть на всю высоту,
              // сообщения "проплывают" под панелью, а не упираются в неё
              // как в соседа по Column). Непрозрачна тут только сама
              // овальная "таблетка" (Container с AppColors.surface внутри
              // SafeArea ниже) — ни у этого Positioned, ни у Column внутри
              // него, ни у зазора-спейсера своего фона нет вообще, так что
              // в промежутках (по бокам таблетки, и особенно в самом
              // зазоре) список снизу просвечивает.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!_composerBlocked && !_searchMode)
                      _buildComposerBanner(),
                    SafeArea(
                      key: _composerAreaKey,
                      top: false,
                      bottom: false,
                      child: _searchMode
                          ? _buildSearchControlPanel()
                          : Padding(
                              padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: AppColors.surface,
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                // right больше left — скрепка/микрофон/камера
                                // сидели слишком близко к правому краю экрана (см.
                                // ТЗ пользователя), сдвигаем их левее без смещения
                                // иконки эмодзи слева.
                                padding: const EdgeInsets.only(
                                  left: 2,
                                  right: 8,
                                ),
                                // Высота ЗАФИКСИРОВАНА явно — без этого пилюля-
                                // контейнер просто shrink-wrap'ился под текущий Row,
                                // а строка "в покое" (с TextField, ~48px по высоте
                                // из-за его contentPadding) и строка записи (таймер
                                // + кнопка, естественно чуть ниже) имели РАЗНУЮ
                                // натуральную высоту — стоило зажать иконку, и вся
                                // "овальная" панель мгновенно, без анимации,
                                // проседала на несколько пикселей: не сама панель
                                // плавно меняла размер, а буквально новая раскладка
                                // с другой высотой встала на её место за один кадр.
                                child: SizedBox(
                                  // Единая высота для обоих состояний (раньше была
                                  // 48/56 — но одновременная смена высоты ВМЕСТЕ с
                                  // 3D-переворотом (см. _FlipSwitcher ниже) выглядит
                                  // как поломанная анимация, а не монетка).
                                  height: 56,
                                  child: _FlipSwitcher(
                                    state: _composerBlocked,
                                    child: _composerBlocked
                                        ? Center(
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 16,
                                                  ),
                                              child: Text(
                                                _blockedComposerText,
                                                textAlign: TextAlign.center,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: AppColors.textMuted,
                                                  fontSize: 12.5,
                                                ),
                                              ),
                                            ),
                                          )
                                        :
                                          // Stack вместо простого условного Row — поле ввода
                                          // (со всем состоянием фокуса) теперь НЕ убирается
                                          // из дерева на время записи, а просто визуально
                                          // прячется через Offstage. Раньше при входе в
                                          // запись TextField буквально исчезал из Row (его
                                          // заменял таймер), а вместе с исчезновением
                                          // сфокусированного виджета Flutter сам снимает с
                                          // него фокус — отсюда самопроизвольно закрывалась
                                          // клавиатура. Offstage держит сам виджет (и его
                                          // FocusNode) смонтированным всё это время.
                                          Stack(
                                            children: [
                                              Positioned.fill(
                                                child: Offstage(
                                                  offstage:
                                                      _recPhase !=
                                                      _RecPhase.idle,
                                                  child: Row(
                                                    children: [
                                                      IconButton(
                                                        padding:
                                                            const EdgeInsets.all(
                                                              6,
                                                            ),
                                                        constraints:
                                                            const BoxConstraints(),
                                                        visualDensity:
                                                            VisualDensity
                                                                .compact,
                                                        icon: _buildFlipIcon(
                                                          stateKey: _emojiMode,
                                                          icon: Icon(
                                                            _emojiMode
                                                                ? Icons.keyboard
                                                                : Icons
                                                                      .emoji_emotions_outlined,
                                                            color: AppColors
                                                                .textMuted,
                                                          ),
                                                        ),
                                                        onPressed: () {
                                                          if (_emojiMode) {
                                                            // Настоящая клавиатура ещё не
                                                            // поднялась — держим reserved на
                                                            // месте (_awaitingKeyboardOpen, см.
                                                            // build()), пока realInset
                                                            // органически не догонит.
                                                            _awaitingKeyboardOpen =
                                                                true;
                                                            setState(
                                                              () => _emojiMode =
                                                                  false,
                                                            );
                                                            _textFocusNode
                                                                .requestFocus();
                                                          } else {
                                                            _textFocusNode
                                                                .unfocus();
                                                            setState(
                                                              () => _emojiMode =
                                                                  true,
                                                            );
                                                          }
                                                        },
                                                      ),
                                                      const SizedBox(width: 2),
                                                      Expanded(
                                                        child: TextField(
                                                          controller:
                                                              _textController,
                                                          focusNode:
                                                              _textFocusNode,
                                                          textCapitalization:
                                                              TextCapitalization
                                                                  .sentences,
                                                          onTap: () {
                                                            if (_emojiMode) {
                                                              setState(
                                                                () =>
                                                                    _emojiMode =
                                                                        false,
                                                              );
                                                            }
                                                          },
                                                          style: TextStyle(
                                                            color: AppColors
                                                                .textPrimary,
                                                          ),
                                                          contentInsertionConfiguration:
                                                              ContentInsertionConfiguration(
                                                                onContentInserted:
                                                                    _handleContentInserted,
                                                              ),
                                                          decoration: InputDecoration(
                                                            hintText: tr(
                                                              'chat.messageHint',
                                                            ),
                                                            border: InputBorder
                                                                .none,
                                                            isDense: true,
                                                            contentPadding:
                                                                const EdgeInsets.symmetric(
                                                                  vertical: 12,
                                                                ),
                                                            hintStyle: TextStyle(
                                                              color: AppColors
                                                                  .textMuted,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                      const SizedBox(width: 2),
                                                      if (_editingMessage !=
                                                          null)
                                                        IconButton(
                                                          padding:
                                                              const EdgeInsets.all(
                                                                6,
                                                              ),
                                                          constraints:
                                                              const BoxConstraints(),
                                                          visualDensity:
                                                              VisualDensity
                                                                  .compact,
                                                          icon: Icon(
                                                            Icons.send,
                                                            color: AppColors
                                                                .primary,
                                                          ),
                                                          onPressed: _hasText
                                                              ? _handleSendPressed
                                                              : null,
                                                        )
                                                      else if (_hasText ||
                                                          (_forwardingTexts
                                                                  ?.isNotEmpty ??
                                                              false))
                                                        IconButton(
                                                          padding:
                                                              const EdgeInsets.all(
                                                                6,
                                                              ),
                                                          constraints:
                                                              const BoxConstraints(),
                                                          visualDensity:
                                                              VisualDensity
                                                                  .compact,
                                                          icon: Icon(
                                                            Icons.send,
                                                            color: AppColors
                                                                .primary,
                                                          ),
                                                          onPressed:
                                                              _handleSendPressed,
                                                        )
                                                      else ...[
                                                        IconButton(
                                                          key: _attachButtonKey,
                                                          padding:
                                                              const EdgeInsets.all(
                                                                6,
                                                              ),
                                                          constraints:
                                                              const BoxConstraints(),
                                                          visualDensity:
                                                              VisualDensity
                                                                  .compact,
                                                          icon: Icon(
                                                            Icons.attach_file,
                                                            color: AppColors
                                                                .textMuted,
                                                          ),
                                                          onPressed:
                                                              _openAttachmentSheet,
                                                        ),
                                                        _buildRecordControlButton(),
                                                      ],
                                                    ],
                                                  ),
                                                ),
                                              ),
                                              if (_recPhase != _RecPhase.idle)
                                                // БЕЗ своего непрозрачного фона: Offstage
                                                // выше уже полностью не рисует строку покоя
                                                // (не просто прячет за чем-то, а не красит
                                                // вообще), так что закрывать её отдельным
                                                // Container(color:) не нужно — а он как раз
                                                // и был багом со скруглением: его собственный
                                                // ПРЯМОУГОЛЬНЫЙ непрозрачный фон перекрывал
                                                // скруглённые углы родительского Container'а
                                                // (тот их не клипует под себя автоматически),
                                                // отсюда и "квадратные" углы да "выпуклые"
                                                // стенки на скриншотах.
                                                Positioned.fill(
                                                  child: Row(
                                                    children:
                                                        _buildRecordingComposerChildren(),
                                                  ),
                                                ),
                                            ],
                                          ),
                                  ),
                                ),
                              ),
                            ),
                    ),
                    // Небольшой зазор до самого низа экрана — без него панель
                    // ввода (и особенно кнопка записи) сидит впритык к краю, и
                    // при попытке провести пальцем вверх до замочка (запись
                    // голосового/видео) вместо этого срабатывает системный
                    // жест "домой", перехватывающий тачи у самого края экрана.
                    // Нужен только когда СНИЗУ больше ничего нет — как только
                    // поднимается клавиатура ИЛИ наша панель эмодзи
                    // (anyPanelOpen), зазор схлопывается в 0.
                    //
                    // Системный отступ до жестовой зоны добавляем СВОИМИ
                    // руками (через viewPadding, а не SafeArea) и тоже только
                    // в состоянии покоя: MediaQuery.padding у НАСТОЯЩЕЙ
                    // клавиатуры автоматически зануляется (клавиатура уже
                    // "занимает" эту зону), а у нашей панели эмодзи — нет,
                    // ведь для ОС это просто обычный контент, а не системная
                    // клавиатура. SafeArea использует именно padding, поэтому
                    // при переключении на эмодзи-панель у неё этот отступ
                    // внезапно возвращался — ровно то самое "пустое место",
                    // из-за которого высота панели эмодзи расходилась с
                    // высотой настоящей клавиатуры.
                    //
                    // Пока БЕЗ анимаций (по просьбе) — просто мгновенная
                    // смена высоты, чтобы сначала проверить сам механизм.
                    SizedBox(height: anyPanelOpen ? 0 : 5 + systemBottomInset),
                    // Клавиатура и эмодзи-панель — ОДНО и то же место экрана,
                    // одной и той же ЗАРАНЕЕ известной высоты (_keyboardHeight,
                    // см. build()), а не живое значение realInset: показываются
                    // по очереди, никогда одновременно, без "скачков" между
                    // ними. Когда видна настоящая клавиатура, здесь просто
                    // пустой резерв места — сама клавиатура рисуется поверх
                    // всего системным оверлеем, а не этим виджетом.
                    Container(
                      height: reserved,
                      color: AppColors.surface,
                      child: _emojiMode
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
              if (_recActiveKind == _RecKind.video)
                Positioned.fill(child: _buildVideoLivePreview()),
              if (_recPhase == _RecPhase.dragging)
                Positioned(
                  right: 18,
                  // Раньше — фиксированный bottom: 76, посчитанный под
                  // состояние покоя (клавиатура закрыта). При поднятой
                  // клавиатуре сама панель ввода (и кнопка микрофона/
                  // камеры на ней) уезжает вверх намного больше, чем на
                  // 76px, а замочек — нет, оставаясь под клавиатурой (см.
                  // жалобу пользователя). Тот же приём, что уже есть у
                  // кнопки переворота камеры чуть ниже — меряем РЕАЛЬНЫЙ
                  // верх панели ввода через RenderBox, он уже учитывает
                  // любое её текущее положение (клавиатура/эмодзи-панель/
                  // баннер ответа), а не жёстко фиксированное число.
                  top:
                      (_composerTopYInBodyStack() ??
                          MediaQuery.of(context).size.height - 76) -
                      64 -
                      10,
                  child: _buildRecordingLockIndicator(),
                ),
              if (_recActiveKind == _RecKind.video &&
                  _availableCameras.length > 1)
                Positioned(
                  left: 12,
                  top:
                      (_composerTopYInBodyStack() ??
                          MediaQuery.of(context).size.height - 76) -
                      _flipCameraButtonSize -
                      10,
                  child: _buildFlipCameraButton(),
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
          // Ярко-зелёный для выбранного — раньше был акцентный цвет темы
          // (синеватый), из-за чего плохо отличался от остального UI.
          color: widget.selected
              ? const Color(0xFF00E676)
              : AppColors.textMuted,
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

/// Пульсирующая красная точка рядом с таймером записи — простой, но
/// достаточный сигнал "идёт запись" без полноценной волновой формы звука.
class _PulsingRecDot extends StatefulWidget {
  const _PulsingRecDot();

  @override
  State<_PulsingRecDot> createState() => _PulsingRecDotState();
}

class _PulsingRecDotState extends State<_PulsingRecDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(
        begin: 1,
        end: 0.25,
      ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: const DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.redAccent,
          shape: BoxShape.circle,
        ),
        child: SizedBox(width: 10, height: 10),
      ),
    );
  }
}

/// Подсветка пузыря, к которому только что перенёс поиск (см.
/// _flashHighlight в _ChatScreenState) — по периметру, непрерывно
/// затухающая и снова появляющаяся, пока виджет смонтирован (его
/// монтирование/размонтирование целиком управляется снаружи условием
/// isHighlighted — сам по себе таймер жизни не ограничивает).
///
/// ВАЖНО: это НЕ отдельная обёртка вокруг уже готового пузыря (так было
/// раньше — оборачивающий Container с собственным border вокруг ЧУЖОГО
/// Container с тем же borderRadius) — та версия давала видимый зазор между
/// рамкой и самим пузырём при малейшем несовпадении их размеров. Здесь
/// анимированная рамка — часть ТОЙ ЖЕ decoration, что красит сам пузырь
/// (цвет фона + скругление задаются здесь же, через baseColor/borderRadius,
/// а не отдельным внешним Container'ом) — то есть это буквально одна и та
/// же коробка, а не две вложенные, так что рамка физически не может
/// оторваться от края пузыря.
/// Переключение между обычным композером и заглушкой-блокировкой —
/// "переворот монетки" вокруг вертикальной оси (3D rotateY), а не
/// мгновенная подмена/кроссфейд: содержимое подменяется РОВНО в середине
/// поворота (90°, когда карточка развёрнута ребром к экрану и физически
/// не видна ни с одной стороны) — сам момент подмены незаметен, весь
/// переход читается как одно целостное вращение, а не два наложенных
/// эффекта.
class _FlipSwitcher extends StatefulWidget {
  final bool state;
  final Widget child;

  const _FlipSwitcher({required this.state, required this.child});

  @override
  State<_FlipSwitcher> createState() => _FlipSwitcherState();
}

class _FlipSwitcherState extends State<_FlipSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Widget? _oldChild;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..value = 1;
  }

  @override
  void didUpdateWidget(covariant _FlipSwitcher old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) {
      _oldChild = old.child;
      _controller
        ..value = 0
        ..forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        if (t >= 1 || _oldChild == null) {
          return widget.child;
        }
        // 0..0.5 — старое содержимое разворачивается от 0° до 90°;
        // 0.5..1 — новое досворачивается от -90° до 0°. Угол непрерывен
        // (в момент подмены оба конца совпадают на ±90°, т.е. на
        // "невидимом" ребре), поэтому визуально это одно движение.
        final showingOld = t < 0.5;
        final angle = showingOld ? t * math.pi : (t - 1) * math.pi;
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0018)
            ..rotateY(angle),
          child: showingOld ? _oldChild : widget.child,
        );
      },
    );
  }
}

class _PulsingHighlight extends StatefulWidget {
  final Widget child;
  final Color baseColor;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry padding;
  final BoxConstraints? constraints;

  const _PulsingHighlight({
    required this.child,
    required this.baseColor,
    required this.borderRadius,
    required this.padding,
    this.constraints,
  });

  @override
  State<_PulsingHighlight> createState() => _PulsingHighlightState();
}

class _PulsingHighlightState extends State<_PulsingHighlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = CurvedAnimation(
          parent: _controller,
          curve: Curves.easeInOut,
        ).value;
        return Container(
          padding: widget.padding,
          constraints: widget.constraints,
          decoration: BoxDecoration(
            color: widget.baseColor,
            borderRadius: widget.borderRadius,
            border: Border.all(
              color: Colors.amber.withValues(alpha: 0.35 + 0.65 * t),
              width: 2.5,
            ),
            // Тот же decoration, что красит сам пузырь (не отдельная
            // обёртка) — тень тут физически не может "оторваться" от
            // рамки, в отличие от прошлой версии с двумя вложенными
            // Container'ами.
            boxShadow: [
              BoxShadow(
                color: Colors.amber.withValues(alpha: 0.35 * t),
                blurRadius: 12 * t,
                spreadRadius: 1.5 * t,
              ),
            ],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
