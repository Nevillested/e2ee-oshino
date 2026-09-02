import 'dart:async';
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
    show
        Clipboard,
        ClipboardData,
        HapticFeedback,
        KeyboardInsertedContent,
        SystemChannels;
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api/api_client.dart';
import '../crypto/double_ratchet.dart';
import '../crypto/key_store.dart';
import '../crypto/message_cipher.dart';
import '../crypto/message_envelope.dart';
import '../crypto/session_store.dart';
import '../crypto/x3dh.dart';
import '../l10n/app_strings.dart';
import '../models/picked_media.dart';
import '../screens/call_screen.dart';
import '../screens/camera_capture_screen.dart';
import '../screens/media_viewer_screen.dart';
import '../services/active_chat_tracker.dart';
import '../services/downloads_saver.dart';
import '../widgets/cached_avatar_image.dart';
import '../services/call_service.dart';
import '../services/chat_scroll_position_store.dart';
import '../services/debug_log.dart';
import '../services/keyboard_height_store.dart';
import '../services/keyboard_insets.dart';
import '../services/media_asset_cache.dart';
import '../services/media_download_manager.dart';
import '../services/media_playback_coordinator.dart';
import '../services/media_upload.dart' as media_upload;
import '../services/message_cleanup.dart';
import '../services/message_router.dart';
import '../services/my_avatar_store.dart';
import '../services/open_with_chooser.dart';
import '../services/peer_profile_cache.dart';
import '../services/pending_send_retrier.dart';
import '../services/send_lock.dart';
import '../services/send_queue_processor.dart';
import '../services/upload_cancel_registry.dart';
import '../services/upload_progress_bus.dart';
import '../services/video_thumbnail_helper.dart';
import '../services/websocket_service.dart';
import '../session.dart';
import '../storage/chat_store.dart';
import '../storage/media_cache.dart';
import '../storage/peer_account_store.dart';
import '../storage/peer_identity_store.dart';
import '../storage/pending_send_store.dart';
import '../theme/app_theme.dart';
import '../utils/file_size_format.dart';
import '../utils/presence_format.dart';
import '../utils/time_format.dart';
import '../storage/default_reaction_store.dart';
import '../widgets/app_loading_indicator.dart';
import '../widgets/attach_launcher_overlay.dart';
import '../widgets/avatar_settings_tile.dart' show AvatarThumbnail;
import '../widgets/delete_message_dialog.dart';
import '../widgets/safe_memory_image.dart';
import '../widgets/full_emoji_picker.dart';
import '../widgets/media_picker_sheet.dart';
import '../widgets/media_status_overlay.dart';
import '../widgets/message_context_menu.dart';
import '../widgets/ongoing_call_banner.dart';
import '../widgets/particle_shatter_overlay.dart';
import '../widgets/hero_zoom_page_route.dart';
import '../widgets/report_message_dialog.dart';
import '../widgets/spoiler_overlay.dart';
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

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  // Было 10 МБ — снижено по просьбе пользователя.
  static const int _autoDownloadLimitBytes = 3 * 1024 * 1024; // 3 МБ
  // Общий с PendingSendRetrier порог (см. media_upload.dart) — единый
  // источник истины, чтобы автоматический повтор после сбоя сети грузил
  // файл тем же способом (потоково/целиком), что и обычная отправка.
  static const int _streamingThresholdBytes =
      media_upload.streamingThresholdBytes;
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
  // Живой процент скачивания (0..100) — приходит из MediaDownloadManager
  // (см. его progressChanges) по mediaId. Раньше это была самодельная
  // очередь прямо здесь, в State экрана чата; теперь весь движок
  // скачивания (две очереди — пользовательская и авто, докачка с места
  // обрыва, вытеснение) живёт в независимом от жизни экрана сервисе, а
  // экран — просто его клиент (см. ТЗ пользователя, разбор очередей).
  final Map<String, double> _downloadProgress = {};

  StreamSubscription<String>? _dlProgressSub;
  StreamSubscription<String>? _dlDoneSub;
  StreamSubscription<String>? _dlFailedSub;

  // Дебаунс "что сейчас видно на экране" -> MediaDownloadManager.setVisible.
  // Авто-очередь наполняется только файлами < 3 МБ, которые показались
  // пользователю; повторно показавшийся прыгает в начало (ТЗ). Флашим не
  // чаще раза в ~350 мс, чтобы фличащий скролл не дёргал движок на каждый
  // кадр.
  final Map<String, DownloadSpec> _visibleSpecs = {};
  final Set<String> _pendingVisibleIds = {};
  Timer? _visibleFlushTimer;

  DownloadSpec? _downloadSpecOf(StoredMessage msg) {
    final mediaId = msg.mediaId;
    final key = msg.mediaKeyBase64;
    if (mediaId == null || key == null) return null;
    return DownloadSpec(
      mediaId: mediaId,
      keyBase64: key,
      chunked: msg.chunked,
      plaintextSize: msg.fileSize,
      nonceBase64: msg.mediaNonceBase64,
      macBase64: msg.mediaMacBase64,
    );
  }

  /// Вызывается из build() плитки медиа, которое СЕЙЧАС строится (значит —
  /// на экране или у самой его кромки). Мелкие (< 3 МБ) не свои
  /// нескачанные файлы так попадают в авто-очередь; крупные движок
  /// проигнорирует (их качаем только по явному тапу пользователя).
  void _noteMediaVisible(StoredMessage msg) {
    if (msg.isMine) return;
    if (msg.fileSize >= _autoDownloadLimitBytes) return;
    if (_mediaExistsLocally(msg)) return;
    final spec = _downloadSpecOf(msg);
    if (spec == null) return;
    _visibleSpecs[spec.mediaId] = spec;
    _pendingVisibleIds.add(spec.mediaId);
    _visibleFlushTimer ??= Timer(
      const Duration(milliseconds: 350),
      _flushVisible,
    );
  }

  void _flushVisible() {
    _visibleFlushTimer = null;
    if (!mounted) return;
    final specs = _pendingVisibleIds
        .map((id) => _visibleSpecs[id])
        .whereType<DownloadSpec>()
        .toList();
    _pendingVisibleIds.clear();
    MediaDownloadManager.instance.setVisible(specs);
  }

  /// Гарантирует, что расшифрованный файл [msg] лежит в MediaCache, и
  /// возвращает его. Быстрые пути (уже в кэше; свой же файл ещё на диске)
  /// — здесь, БЕЗ сети и без движка. Иначе — отдаём в MediaDownloadManager
  /// (userInitiated: явный тап -> высший приоритет и вытеснение; иначе ->
  /// тихо в начало авто-очереди).
  Future<File> _ensureMediaFile(
    StoredMessage msg, {
    bool userInitiated = false,
    void Function(double percent)? onProgress,
  }) async {
    final mediaId = msg.mediaId!;
    final cacheFile = await MediaCache.fileFor(mediaId);
    if (await cacheFile.exists()) return cacheFile;

    // Свой же файл, ещё живой на диске — копируем в кэш, сеть не трогаем
    // (прежние комментарии в _loadAndCacheMedia про localPreviewPath /
    // localSourcePath и жалобы про перекачку своих файлов).
    if (msg.isMine) {
      if (!msg.isVideo &&
          !msg.isVideoNote &&
          !msg.isFile &&
          msg.localPreviewPath != null) {
        final f = File(msg.localPreviewPath!);
        if (await f.exists()) {
          await f.copy(cacheFile.path);
          return cacheFile;
        }
      }
      if (msg.localSourcePath != null) {
        final f = File(msg.localSourcePath!);
        if (await f.exists()) {
          await f.copy(cacheFile.path);
          return cacheFile;
        }
      }
    }

    final spec = _downloadSpecOf(msg);
    if (spec == null) throw ApiException(tr('error.downloadFailed'));

    StreamSubscription<String>? sub;
    if (onProgress != null) {
      sub = MediaDownloadManager.instance.progressChanges
          .where((id) => id == mediaId)
          .listen(
            (id) =>
                onProgress(MediaDownloadManager.instance.progressOf(id) ?? 0),
          );
    }
    try {
      return await MediaDownloadManager.instance.ensureDownloaded(
        spec,
        userInitiated: userInitiated,
      );
    } finally {
      await sub?.cancel();
    }
  }

  bool _isDownloading(String? mediaId) =>
      mediaId != null && MediaDownloadManager.instance.isWorking(mediaId);

  bool _isDownloadActive(String? mediaId) =>
      mediaId != null && MediaDownloadManager.instance.isActive(mediaId);

  /// Синхронный, всегда-актуальный ответ на вопрос "этот медиафайл уже
  /// физически на устройстве?" — ТЗ пользователя: "абсолютно всё в чате,
  /// кроме текста, должно иметь флаг — существует ли это на телефоне".
  /// Проверяется ДО построения FutureBuilder в _photoPreview (см. её
  /// комментарий), а не внутри его "не готово"-ветки — сама асинхронность
  /// проверки (а не факт реального отсутствия файла) и вызывала вспышку
  /// текста "Скачивание/В очереди" на уже скачанных фото. Порядок
  /// зеркалит быстрые пути _loadAndCacheMedia: сначала расшифрованный кэш
  /// (MediaCache — все файлы, включая свои же отправленные, после первого
  /// успешного чтения), потом — для СВОИХ медиа — исходник на диске:
  /// localPreviewPath у фото (сам файл), localSourcePath у видео/файла/
  /// голосового/видео-заметки (у НИХ localPreviewPath — это только
  /// превью-кадр или вовсе null, см. её комментарий в chat_store.dart).
  /// Раньше здесь проверялся только фото-случай — ТЗ пользователя "абсолютно
  /// всё" на видео/файл не распространялось: свои же только что отправленные
  /// видео/файл после очистки MediaCache считались недоступными и заново
  /// качались с сервера, хотя физически никуда с телефона не делись.
  bool _mediaExistsLocally(StoredMessage msg) {
    final mediaId = msg.mediaId;
    if (mediaId != null && MediaCache.existsSync(mediaId)) return true;
    if (!msg.isMine) return false;
    if (!msg.isVideo &&
        !msg.isVideoNote &&
        !msg.isFile &&
        msg.localPreviewPath != null) {
      return File(msg.localPreviewPath!).existsSync();
    }
    if (msg.localSourcePath != null) {
      return File(msg.localSourcePath!).existsSync();
    }
    return false;
  }

  // То же самое, но для ИСХОДЯЩЕЙ загрузки на сервер (см. ТЗ пользователя:
  // "а когда я отправляю файл?") — ключ здесь messageId, не mediaId (у
  // ещё не отправленного сообщения mediaId просто пока не существует).
  // Живёт только в памяти, НЕ пишется в ChatStore/processingStep —
  // processingStep остаётся простой фазовой меткой ("Загрузка на
  // сервер…"), а число берётся отсюда и приклеивается к ней уже при
  // отрисовке (см. _processingStepDisplay), иначе пришлось бы
  // перезаписывать ВЕСЬ список сообщений чата в secure storage на каждый
  // тик прогресса — см. ChatStore._replace.
  final Map<String, double> _uploadProgress = {};

  void Function(double percent) _uploadProgressUpdater(String messageId) {
    return (percent) {
      if (!mounted) return;
      setState(() => _uploadProgress[messageId] = percent);
    };
  }

  /// Текст фазы + процент отправки С УЧЁТОМ известного ограничения: dio
  /// onSendProgress считает только "клиент → сервер", а сервер после этого
  /// ЕЩЁ сохраняет файл в MinIO — второй, отдельный шаг, о котором клиент
  /// вообще не получает никакого сигнала (см. разбор с пользователем).
  /// Без этой подмены процент утыкался бы в 100% и молча висел там 5-10
  /// секунд, выглядя как зависание — поэтому как только клиент физически
  /// дослал все байты, показываем отдельную фазу вместо "100%".
  ({String text, double? percent}) _uploadPhaseFor(StoredMessage msg) {
    final percent = _uploadProgress[msg.messageId];
    if (percent != null && percent >= 100) {
      return (text: tr('chat.savingOnServer'), percent: null);
    }
    return (text: msg.processingStep ?? '', percent: percent);
  }

  /// processingStep + живой процент загрузки, если он сейчас есть для
  /// этого сообщения (только во время реальной сетевой отправки байт —
  /// на этапе шифрования числа нет, что и правильно, см. _uploadProgress).
  String? _processingStepDisplay(StoredMessage msg) {
    if (msg.processingStep == null) return null;
    final phase = _uploadPhaseFor(msg);
    // Только процент, БЕЗ фразы вроде "Загрузка на сервер…" — вместе они
    // не помещаются в маленькой плитке группы (см. ТЗ пользователя со
    // скриншотом: длинная фраза сама съедала всю ширину, а число после неё
    // просто обрезалось многоточием и было не видно). Голый процент
    // гарантированно влезает и однозначно читается.
    if (phase.percent == null) return phase.text;
    return '${phase.percent!.round()}%';
  }

  /// Только для лога (см. purgeMessageArtifacts/DebugLog — НИКОГДА
  /// содержимого/имени файла, только тип) — чтобы в debug_log.txt было
  /// видно, что именно не отправилось: фото, видео или произвольный файл.
  String _mediaKindLabel(PickedMedia item) {
    if (item.isFile) return 'file';
    if (item.isVideo) return 'video';
    return 'photo';
  }

  /// Экранные (только в памяти этого ChatScreen, не в ChatStore) следы
  /// одного сообщения — живой процент, кэш уже расшифрованных байт/видео-
  /// превью, отметки "качается прямо сейчас". Часть полной зачистки при
  /// удалении (см. purgeMessageArtifacts — та часть про диск/очереди,
  /// эта — про то, что держит сам открытый экран чата).
  void _purgeInMemoryTracking(StoredMessage msg) {
    _uploadProgress.remove(msg.messageId);
    final mediaId = msg.mediaId;
    if (mediaId == null) return;
    _downloadProgress.remove(mediaId);
    _mediaFutures.remove(mediaId);
    _resolvedMedia.remove(mediaId);
    _videoThumbCache.remove(mediaId);
    _visibleSpecs.remove(mediaId);
    _pendingVisibleIds.remove(mediaId);
    // Бросить любую идущую/очередённую закачку этого файла и снести его
    // недокачанный хвост (сообщение удалено — файл больше не нужен).
    MediaDownloadManager.instance.forget(mediaId);
  }

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
  // См. _maybeSendReadReceipts: id, для которых квитанция уже поставлена в
  // очередь и ждёт ack — InnerMessage.readReceipt() генерирует НОВЫЙ
  // messageId при каждом вызове (в отличие от обычных сообщений, у
  // квитанции нет своего стабильного id), поэтому без этого набора каждый
  // новый триггер (а он срабатывает на КАЖДОЕ входящее сообщение) заново
  // создавал отдельный конверт на те же самые ещё-не-подтверждённые id —
  // реальный кейс с устройства: соединение забито затором, ack не успевает
  // прийти за 8с у SendQueueProcessor, следующее входящее сообщение снова
  // триггерит _maybeSendReadReceipts, тот снова видит те же
  // !readReceiptSent id и штампует ещё одну квитанцию — очередь на
  // отправку выросла до 328 элементов подряд, канал полностью забился
  // дублями, из-за чего не успевали проходить pong'и на pingInterval
  // клиента (dart:io рвёт "живой" сокет каждые ~40с без ответа) и реальные
  // сообщения/медиа копились за этим мусором минутами.
  final Set<String> _readReceiptPending = {};

  bool _emojiMode = false;
  double _keyboardHeight = 280;
  static const _keyboardHeightSettleDelay = Duration(milliseconds: 180);
  Timer? _keyboardHeightSettleTimer;
  // См. build(): держит emojiReserved резервированным на те несколько кадров
  // между тапом по иконке клавиатуры (переключение из эмодзи-режима) и
  // моментом, когда настоящая клавиатура реально поднимется и realInset
  // это заметит.
  bool _awaitingKeyboardOpen = false;
  bool _hasText = false;
  double _lastReserved = 0;
  double? _lastLoggedBottomInset;
  // Диагностика жалобы "при опускании клавиатуры на миг видна пустая
  // панель эмодзи, потом резко исчезает" (особенно после выхода из чата и
  // повторного входа) — логируем состояние (keyboardVisible/_emojiMode/
  // _awaitingKeyboardOpen/emojiReserved), но только когда оно РЕАЛЬНО
  // меняется, а не на каждый build() — иначе лог захлебнётся (build()
  // вызывается на каждый кадр анимации клавиатуры).
  String? _lastLoggedEmojiKeyboardState;
  // См. _handleScroll и триггер в build() ниже: пока клавиатура/эмодзи-панель
  // открывается, viewport физически сжимается кадр за кадром, maxScrollExtent
  // растёт БЫСТРЕЕ, чем успевает докрутить компенсирующий _scrollToBottom —
  // без этого флага _handleScroll видел бы "pixels < maxScrollExtent-40" на
  // каждом таком промежуточном кадре и сбрасывал _userAtBottom в false,
  // глуша тем самым сам же механизм компенсации (он требует _userAtBottom==
  // true, чтобы вообще сработать) — реальная жалоба пользователя: отступ
  // между последним сообщением и панелью появляется при открытии клавиатуры
  // и не пропадает, пока не прокрутить вручную. При закрытии бага нет —
  // там ScrollPosition сама подрезает pixels под уменьшившийся
  // maxScrollExtent, никакой компенсации не требуется.
  bool _autoScrollingForResize = false;

  // Держит "клавиатура видна" через короткие провалы realInset до 0 —
  // системный оверлей "Change keyboard" (долгий тап на пробел) на части
  // устройств на кадр-другой обнуляет viewInsets.bottom ещё ДО того, как
  // сам оверлей закрылся; без сглаживания это мгновенно схлопывало
  // зарезервированное место под клавиатуру (см. keyboardVisible/reserved
  // ниже), что само гасило и клавиатуру, и оверлей поверх нее (ТЗ
  // пользователя). Открытие (0 → есть insets) применяется сразу, без
  // задержки — тормозить именно ЗАКРЫТИЕ.
  bool _keyboardVisibleDebounced = false;
  static const _keyboardCloseDebounceDelay = Duration(milliseconds: 250);
  Timer? _keyboardCloseDebounceTimer;

  // Попытка №1 фикса жалобы "системный свайп назад при поднятой клавиатуре —
  // пустое пространство, потом резкий прыжок панели" — гипотеза была, что
  // MediaQuery доставляет обновление inset'а с опозданием (одним прыжком
  // уже ПОСЛЕ того, как клавиатура визуально исчезла), поэтому был добавлен
  // свой "close-fallback" — synthetic-анимация, стартующая сразу по потере
  // фокуса, независимо от realInset. Проверка по debug_log с реального
  // устройства ЭТУ гипотезу ОПРОВЕРГЛА: во всех зафиксированных случаях
  // realInset к моменту срабатывания _onFocusChange уже был равен 0 —
  // MediaQuery обновлялся СИНХРОННО с потерей фокуса или раньше, никакого
  // отставания не было. Итог — сам close-fallback был единственным
  // источником искусственной 260мс паузы там, где реальная система уже
  // всё показала мгновенно: чинил не найденный баг, а создавал новый той же
  // формы. Убран целиком (см. историю правок) — снова просто realInset.

  // Растущая пилюля-композер (см. ТЗ пользователя "Enter — перенос строки,
  // а не закрытие клавиатуры") — считаем число строк по явным '\n' (не
  // мягкому переносу по ширине: без layout-контекста его точно не измерить
  // тут же, а грубая оценка регулярно расходилась бы с тем, что реально
  // отрисовывает TextField). base — высота пилюли в состоянии покоя/записи/
  // блокировки, lineDelta — эмпирическая высота одной ДОПОЛНИТЕЛЬНОЙ строки
  // при текущем размере шрифта поля, maxExtraLines — потолок роста (дальше
  // TextField сам скроллит содержимое внутри последних maxLines строк).
  static const double _composerBaseHeight = 56;
  static const double _composerLineDelta = 22;
  static const int _composerMaxExtraLines = 4;
  int _composerLineCount = 1;

  double get _composerHeight {
    if (_composerBlocked || _recPhase != _RecPhase.idle) {
      return _composerBaseHeight;
    }
    return _composerBaseHeight + (_composerLineCount - 1) * _composerLineDelta;
  }

  // Баннер реплая/редактирования/пересылки (см. _bannerRow) занимает
  // собственное место НАД пилюлей поля ввода, но список сообщений это не
  // учитывал: жалоба пользователя, что при активном реплае баннер
  // перекрывает последнее сообщение — паддинг снизу резервировал место
  // только под саму пилюлю. Высота — фиксированная сумма всех отступов
  // _bannerRow (margin 4 сверху + padding 4+4 сверху/снизу + содержимое 26).
  static const double _composerBannerHeight = 38;

  bool get _composerBannerVisible =>
      !_composerBlocked &&
      !_searchMode &&
      (_editingMessage != null ||
          _replyTarget != null ||
          (_forwardingTexts?.isNotEmpty ?? false));

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

  // Раскрытые спойлер-фото (см. StoredMessage.isSpoiler/_photoPreview) —
  // представительский Set id сообщений, ПЕРВЫЙ тап по которым уже снял
  // блюр в ЭТОМ открытии чата. Намеренно НЕ персистится никуда: у
  // _ChatScreenState свежий State на каждый повторный вход в чат (см. ТЗ
  // пользователя — эффект должен сбрасываться при перезаходе).
  final Set<String> _revealedSpoilerIds = {};

  // Единая точка координации проигрывания голосовых/видео-сообщений — см.
  // MediaPlaybackCoordinator и _buildMediaControlBar ниже (ТЗ пользователя:
  // верхняя панель с play/pause+крестиком, общая для обоих типов).
  final _mediaCoordinator = MediaPlaybackCoordinator();

  // Свайп-реплай (как в Телеге) — см. _wrapInteractive: жест стартует на
  // КОНКРЕТНОЙ строке сообщения (тем же GestureDetector, что уже ловит тап/
  // долгий тап), поэтому достаточно одного набора полей на весь экран —
  // одновременно тянуть можно только одно сообщение. _swipeReplyTargetId —
  // представительский id (messageId) строки, которая СЕЙЧАС тянется;
  // _swipeReplyDx — текущий визуальный сдвиг (всегда ≤ 0, влево), капается
  // на -10% ширины экрана и одновременно на ней же и стреляет реплай.
  String? _swipeReplyTargetId;
  double _swipeReplyDx = 0;
  bool _swipeReplyFired = false;

  // Свайп-НАЗАД (см. SwipeBackDetector/SwipeBackPageRoute), теперь дублируемый
  // и на уровне строки сообщения: сам список сообщений — это ГЛУБЖЕ
  // вложенный GestureDetector, чем SwipeBackDetector, поэтому в арене
  // жестов Flutter он всегда побеждает его, если стартовать жест прямо на
  // строке сообщения — раньше это полностью блокировало свайп-назад внутри
  // чата. Решение — не делить экран на конкурирующие зоны, а решать
  // направление ОДНИМ распознавателем на строке и, если оно оказалось
  // "вправо", вручную доигрывать ту же публичную последовательность
  // handleDragStart/Update/End, которой обычно управляет SwipeBackDetector
  // (см. ниже). Направление фиксируется один раз в начале жеста (после
  // небольшого порога — защита от дрожания пальца) и не меняется до конца,
  // чтобы жест не дёргался между реплаем и свайпом-назад.
  String? _swipeTargetId;
  double _swipeCumulativeDx = 0;
  bool? _swipeIsBackNavigation;
  SwipeBackPageRoute<dynamic>? _swipeBackRoute;

  // Представительские id сообщений, у которых реакция появилась ТОЛЬКО ЧТО
  // (своя простановка в _handleReaction ИЛИ живой сигнал от собеседника,
  // см. MessageRouter.incomingReactions) — единственный способ для
  // _ReactionChip отличить "проиграть искры" от "реакция была тут уже
  // давно, просто чат/сообщение только что попали в дерево виджетов"
  // (initState в обоих случаях выглядит одинаково). Каждый id сам себя
  // убирает через короткое время — дальше он не нужен, а без очистки
  // копился бы на весь срок жизни экрана.
  final Set<String> _justReactedMessageIds = {};
  final Map<String, Timer> _justReactedTimers = {};

  void _markJustReacted(String messageId) {
    _justReactedMessageIds.add(messageId);
    _justReactedTimers[messageId]?.cancel();
    _justReactedTimers[messageId] = Timer(
      const Duration(milliseconds: 1200),
      () {
        _justReactedMessageIds.remove(messageId);
        _justReactedTimers.remove(messageId);
      },
    );
  }

  // Живой статус собеседника (онлайн/офлайн/печатает), см. _handlePresenceEvent
  // — null, пока сервер ещё не ответил на подписку (presence_subscribe).
  bool? _peerOnline;
  int? _peerLastSeenMs;
  bool _peerTyping = false;
  Timer? _peerTypingClearTimer;
  StreamSubscription<Map<String, dynamic>>? _presenceSub;
  StreamSubscription<ConnectionStatus>? _wsStatusSub;
  StreamSubscription<void>? _blockStatusSub;
  StreamSubscription<({String peerLogin, String messageId})>?
  _incomingReactionSub;
  StreamSubscription<({String peerLogin, List<String> targetIds})>?
  _incomingDeleteSub;
  StreamSubscription<(String messageId, double percent)>? _uploadProgressSub;
  Timer? _presenceTickTimer;
  DateTime? _lastTypingSentAt;

  // Отображаемое имя собеседника (см. ТЗ пользователя) — если задано,
  // показывается в шапке вместо peerLogin; null, пока не резолвилось (или
  // если не задано вовсе — тогда title просто продолжает падать на
  // widget.peerLogin). Живой сигнал (PeerProfileCache.changes) — на случай,
  // если собеседник сменит имя, пока чат уже открыт.
  String? _peerDisplayName;
  StreamSubscription<String>? _peerProfileSub;

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

  // Разовая подсветка на всю ширину экрана после анимированного перелёта к
  // сообщению — тап по баннеру цитаты ИЛИ по баннеру закрепа (см.
  // _jumpToMessageWithFlash/_buildPinnedBanner) — общий
  // механизм для обоих (см. _JumpFlash) — отдельно от _highlightedMessageId
  // выше: тот держится постоянно (пока не переключат совпадение поиска), а
  // это — один раз мигнуть и погаснуть. _jumpFlashToken растёт при каждом
  // тапе, даже повторном по тому же id — ValueKey на _JumpFlash с этим
  // токеном гарантирует перезапуск анимации затухания с нуля, а не "ничего
  // не происходит", если ткнуть в ещё не погасшую подсветку снова.
  String? _jumpFlashMessageId;
  int _jumpFlashToken = 0;

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
    // Диагностика "видео не появляется после успешного resolve" —
    // подозрение на несколько живых экземпляров _ChatScreenState
    // одновременно (см. разбор через VM Service). identityHashCode(this) —
    // однозначный "адрес" именно ЭТОГО объекта State, сверяем потом с тем,
    // что реально видно на экране/резолвит медиа.
    debugPrint(
      'ChatScreen[${identityHashCode(this)}] initState peerLogin=${widget.peerLogin}',
    );
    WidgetsBinding.instance.addObserver(this);
    ActiveChatTracker.currentPeerLogin = widget.peerLogin;
    ChatStore.clearUnread(widget.peerLogin);
    _currentPeerDeviceId = widget.peerDeviceId;
    _forwardingTexts = widget.forwardedTexts;
    _textFocusNode.addListener(_onFocusChange);
    _textController.addListener(_onTextChanged);
    // См. KeyboardInsets — ValueNotifier сам по себе не встроен в дерево
    // виджетов, перестройку по его изменению нужно попросить явно.
    KeyboardInsets.heightPx.addListener(_onKeyboardInsetsChanged);
    _loadKnownDeletedStatus();
    _bootstrapHistory();
    unawaited(_refreshBlockStatusFromServer());
    // Живой сигнал "кто-то поменял блокировку" (см. notifyBlockStatusChanged
    // на сервере) — пока этот чат открыт, композер-заглушка должна
    // появиться/исчезнуть сразу, а не только при повторном заходе в чат.
    _blockStatusSub = WebSocketService.instance.blockStatusEvents.listen(
      (_) => unawaited(_refreshBlockStatusFromServer()),
    );
    // Живая реакция ОТ СОБЕСЕДНИКА — помечаем "только что", чтобы
    // _ReactionChip проиграл искры, когда следующий _loadHistory() (см.
    // ChatStore.changes ниже) построит его впервые с этим emoji.
    _incomingReactionSub = MessageRouter.incomingReactions.listen((event) {
      if (event.peerLogin == widget.peerLogin) {
        _markJustReacted(event.messageId);
      }
    });
    // Собеседник удалил сообщения (и у нас тоже) — если этот чат открыт,
    // хотим тот же эффект "рассыпания", что и при удалении со своей
    // стороны, а не молчаливое исчезновение при следующей перерисовке
    // списка (см. _playIncomingDeleteEffect).
    _incomingDeleteSub = MessageRouter.incomingDeletes.listen((event) {
      if (event.peerLogin == widget.peerLogin) {
        unawaited(_playIncomingDeleteEffect(event.targetIds));
      }
    });
    // Процент загрузки для сообщений, которые PendingSendRetrier повторно
    // грузит в фоне (реконнект/ручной "Повторить отправку") — сам ретраер
    // не привязан к тому, открыт ли сейчас этот экран, поэтому только так
    // (см. UploadProgressBus) число вообще может сюда попасть.
    _uploadProgressSub = UploadProgressBus.stream.listen((event) {
      if (!mounted) return;
      setState(() => _uploadProgress[event.$1] = event.$2);
    });
    // Живые обновления от движка скачивания (MediaDownloadManager) — он
    // не привязан к жизни этого экрана (переживает уход из чата, а Stage 2
    // — и сворачивание приложения), поэтому проценты/готово/сбой приходят
    // сюда только через его стримы.
    final dl = MediaDownloadManager.instance;
    _dlProgressSub = dl.progressChanges.listen((mediaId) {
      if (!mounted) return;
      final p = dl.progressOf(mediaId);
      setState(() {
        if (p == null) {
          _downloadProgress.remove(mediaId);
        } else {
          _downloadProgress[mediaId] = p;
        }
      });
    });
    _dlDoneSub = dl.done.listen((mediaId) {
      if (!mounted) return;
      // Файл расшифрован и лежит в MediaCache — сбрасываем незавершённые
      // трекеры этого экрана, чтобы плитки перечитали кэш и показали
      // содержимое (в т.ч. видео-превью сгенерировалось заново).
      _mediaFutures.remove(mediaId);
      _videoThumbCache.remove(mediaId);
      _downloadProgress.remove(mediaId);
      setState(() {});
    });
    _dlFailedSub = dl.failed.listen((mediaId) {
      if (!mounted) return;
      _mediaFutures.remove(mediaId);
      setState(() {});
    });
    if (!_isNotes) {
      unawaited(_loadPeerDisplayName());
      _peerProfileSub = PeerProfileCache.changes.listen((accountId) {
        if (accountId == widget.peerAccountId) {
          unawaited(_loadPeerDisplayName());
        }
      });
    }
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
      // Диагностика жалобы "собеседник показан онлайн, хотя телефон не
      // трогали" — на этом устройстве (наблюдателе) фиксируем каждое живое
      // presence-событие от собеседника с временем получения; сопоставить
      // с серверным логом notifyPresenceSubscribers/ws connect по времени
      // и с "WS status -> connected" в debug_log САМОГО собеседника (если
      // будет доступен) — так можно будет отличить настоящее подключение
      // от ложного/дублирующего.
      DebugLog.log(
        'Presence event from=${event['FromDeviceId']} online=$online '
        'lastSeenMs=$lastSeenMs (peerLogin=${widget.peerLogin})',
      );
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

  // ТЗ пользователя/реальный кейс: открыли панель медиа (см.
  // media_picker_sheet.dart — showGeneralDialog поверх ЭТОГО экрана, сам
  // ChatScreen никуда не девается, просто перекрыт), сфокусировали её
  // собственное поле подписи — и чат ПОЗАДИ тоже начинал "подниматься"
  // вместе с клавиатурой. Причина — KeyboardInsets.heightPx глобальный
  // (одна и та же клавиатура на всё приложение), а слушатель здесь ничего
  // не проверял, кроме mounted: перестраивался и применял свой
  // Padding(bottom: realInset) в body даже будучи полностью перекрытым
  // чужим экраном, для чужого поля ввода. isCurrent — этот route сейчас
  // самый верхний (видимый, не перекрыт диалогом/другим экраном) — ровно
  // то условие, при котором клавиатура вообще может быть "нашей".
  void _onKeyboardInsetsChanged() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    setState(() {});
  }

  void _onFocusChange() {
    // Диагностика "пустая панель эмодзи при закрытии клавиатуры" — этот
    // колбэк дёргается НЕ на каждый кадр (в отличие от build()), а только
    // на реальные события фокуса, поэтому лог тут не захлёбывается и даёт
    // точную последовательность событий вокруг момента, когда что-то
    // пошло не так.
    DebugLog.log(
      'Chat _onFocusChange hasFocus=${_textFocusNode.hasFocus} '
      'emojiMode=$_emojiMode awaitingKeyboardOpen=$_awaitingKeyboardOpen '
      'keyboardVisibleDebounced=$_keyboardVisibleDebounced '
      'realInset=${mounted ? MediaQuery.of(context).viewInsets.bottom : 'n/a'}',
    );
    // Резерв места (reserved в build()) сам вычисляется на лету из
    // keyboardVisible/_emojiMode на каждой перестройке — здесь нужно
    // только не дать эмодзи-панели остаться включённой, если фокус
    // получило текстовое поле (например, реальная клавиатура поднялась
    // не через нашу кнопку, а как-то иначе).
    if (_textFocusNode.hasFocus && _emojiMode) {
      setState(() => _emojiMode = false);
    }
    // Системный back/свайп-назад при поднятой клавиатуре закрывает её на
    // уровне ОС ещё до того, как это событие вообще доходит до Flutter
    // (IME сама глотает back) — единственный сигнал, который у нас
    // остаётся, это потеря фокуса нашим полем. _keyboardCloseDebounceDelay
    // (250мс, см. поле выше) существует ТОЛЬКО для случая "фокус остался,
    // но realInset на кадр обнулился" (системный оверлей смены клавиатуры)
    // — если фокус реально потерян, эта неоднозначность не применима:
    // ждать тут больше нечего, а лишние 250мс задержки — ровно та
    // "пустая панель мелькнула, а потом резко пропала" жалоба пользователя
    // после теста на устройстве. Если клавиатура на самом деле остаётся
    // (просто перескочила на другое поле), rawKeyboardVisible на
    // следующем же кадре сама вернёт _keyboardVisibleDebounced в true.
    if (!_textFocusNode.hasFocus && _keyboardVisibleDebounced) {
      DebugLog.log(
        'Chat _onFocusChange: фокус потерян, немедленно keyboardVisibleDebounced=false '
        '(было true, минуя _keyboardCloseDebounceDelay)',
      );
      _keyboardCloseDebounceTimer?.cancel();
      _keyboardCloseDebounceTimer = null;
      setState(() => _keyboardVisibleDebounced = false);
    }
  }

  void _onTextChanged() {
    final text = _textController.text;
    final hasText = text.trim().isNotEmpty;
    // '\n'.allMatches — TextField сам не сообщает нам, сколько строк он
    // сейчас реально показывает (это знает только его внутренний
    // RenderEditable), а нам нужно ЗАРАНЕЕ решить высоту пилюли-контейнера
    // вокруг него (см. _composerHeight) — считаем по числу явных переносов
    // (Enter), которые единственно и добавляет наш textInputAction.newline.
    final lineCount = (('\n'.allMatches(text).length + 1)).clamp(
      1,
      1 + _composerMaxExtraLines,
    );
    if (hasText != _hasText || lineCount != _composerLineCount) {
      setState(() {
        _hasText = hasText;
        _composerLineCount = lineCount;
      });
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
    // См. комментарий у поля _autoScrollingForResize — во время
    // компенсирующей докрутки после сжатия/расширения viewport клавиатурой
    // метрики скролла меняются САМИ ПО СЕБЕ, не из-за жеста пользователя;
    // не даём этому промежуточному состоянию сбросить _userAtBottom.
    if (!_autoScrollingForResize) {
      _userAtBottom =
          _scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 40;
    }

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
      // Бывшая точка запуска "автозакачки за сегодня" — теперь этого
      // режима нет вовсе (ТЗ пользователя): авто-очередь наполняется
      // ТОЛЬКО тем, что реально показалось на экране (< 3 МБ), по факту
      // отрисовки плитки — см. _noteMediaVisible.
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
        .where(
          (m) =>
              !m.isMine &&
              !m.readReceiptSent &&
              !_readReceiptPending.contains(m.messageId),
        )
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
    // асинхронно.
    //
    // _readReceiptPending — id, для которых конверт уже стоит в
    // SendQueueStore и ждёт ack (см. объявление поля): пока он там,
    // SendQueueProcessor сам переотправит его на каждом реконнекте — новый
    // конверт создавать не нужно и НЕЛЬЗЯ (у readReceipt нет стабильного
    // id, см. InnerMessage.readReceipt, так что "просто вызвать ещё раз"
    // означало бы независимый дубликат, а не повтор той же попытки).
    // Если сама постановка в очередь не удалась (queued == false — ошибка
    // ДО SendQueueStore, не таймаут ack), снимаем id из pending, чтобы
    // следующий естественный триггер (новое сообщение, повторное открытие
    // чата) попробовал заново, как и раньше.
    _readReceiptPending.addAll(toMark);
    final queued = await _sendControlMessage(
      InnerMessage.readReceipt(targetMessageIds: toMark),
      onAcked: () async {
        await ChatStore.markReadReceiptsSent(widget.peerLogin, toMark);
        _readReceiptPending.removeAll(toMark);
      },
    );
    if (!queued) _readReceiptPending.removeAll(toMark);
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
    // ДО записи в ChatStore — flag должен быть выставлен уже к моменту,
    // когда следующий _loadHistory() (см. ниже) перестроит список и впервые
    // смонтирует _ReactionChip с этим emoji (см. justChanged в его классе).
    if (emoji != null) _markJustReacted(msg.messageId);
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
    // Снимок ДО удаления — mediaId/groupId/localPreviewPath после
    // ChatStore.deleteMessages взять будет уже неоткуда (см.
    // purgeMessageArtifacts, ТЗ пользователя: удаление — полный сброс, без
    // следов в кэше/очередях).
    final messagesToPurge = _messages
        .where((m) => ids.contains(m.messageId))
        .toList();
    // Сообщение, которое не отправилось (или ещё в процессе — 'sending'/
    // 'queued', подтверждения от сервера ещё не было), физически не могло
    // дойти до собеседника — удалять там попросту нечего, чекбокс "у
    // собеседника тоже" в этом случае не показываем (ТЗ пользователя).
    // При массовом удалении показываем, если хотя бы ОДНО из выбранных
    // реально дошло (status 'sent'/'read') — тогда сигнал имеет смысл
    // хотя бы для части сообщений.
    final anyDelivered = messagesToPurge.any(
      (m) => m.status == 'sent' || m.status == 'read',
    );

    final result = await showDeleteMessagesDialog(
      context,
      peerName: widget.peerLogin,
      peerAccountId: _isNotes ? null : widget.peerAccountId,
      showPeerCheckbox: !_isNotes && anyDelivered,
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
    await purgeAllMessageArtifacts(messagesToPurge);
    for (final m in messagesToPurge) {
      _purgeInMemoryTracking(m);
    }
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

  /// Тот же эффект "рассыпания", что в _deleteMessages, но для удаления,
  /// пришедшего ОТ СОБЕСЕДНИКА (см. MessageRouter.incomingDeletes) — сама
  /// команда ChatStore.deleteMessages тут не нужна (её уже выполняет
  /// MessageRouter), только снимок+анимация, пока пузыри ещё смонтированы.
  /// Само удаление из ChatStore и последующий _loadHistory() (см. общий
  /// ChatStore.changes listener в initState) могут прийти чуть раньше, чем
  /// долетят частицы — в этом случае строка в списке уже схлопнется сама,
  /// а искры доиграются поверх как самостоятельный оверлей; не идеально
  /// синхронно, но заметно лучше, чем полное отсутствие анимации у
  /// получателя.
  Future<void> _playIncomingDeleteEffect(List<String> ids) async {
    if (!mounted) return;
    final shatterCaptures = await _captureShatterImages(ids);
    if (shatterCaptures.isEmpty || !mounted) return;
    setState(() {
      _dissolvingMessageIds.addAll(shatterCaptures.map((c) => c.messageId));
    });
    await Future.wait(
      shatterCaptures.map(
        (c) => showShatterEffect(context, image: c.image, rect: c.rect),
      ),
    );
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

  /// Тап по баннеру цитаты (см. _buildReplyPreview) ИЛИ по баннеру закрепа
  /// (см. _buildPinnedBanner) — ТЗ пользователя (оба случая): анимационно
  /// перелетаем к целевому сообщению (см. _scrollToMessage — уже умеет и
  /// близкие, и далёкие цели), а когда долетели — разово подсвечиваем его
  /// на всю ширину экрана и гасим (см. _JumpFlash). Ничего не делаем, если
  /// целевое сообщение не нашли (удалено) — для цитаты сюда в этом случае
  /// вообще не должны попасть, см. onTap: null в _buildReplyPreview, но
  /// проверка здесь на всякий случай тоже; для закрепа само его наличие
  /// уже гарантирует, что сообщение есть (см. _pinnedMessageId).
  Future<void> _jumpToMessageWithFlash(String messageId) async {
    if (_findMessageById(messageId) == null) return;
    await _scrollToMessage(messageId);
    if (!mounted) return;
    setState(() {
      _jumpFlashMessageId = messageId;
      _jumpFlashToken++;
    });
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

    // Статус для меню считаем по ВСЕЙ группе (если это группа), а не только
    // по репрезентативному msg — та же логика агрегации, что и у
    // _buildGroupBubble's aggregateStatus: если хоть один файл в группе не
    // смог уйти, вся группа считается "failed" для целей меню (отменить/
    // повторить действует на неё целиком).
    final statusGroup = groupMessageIds == null
        ? [msg]
        : _messages.where((m) => groupMessageIds.contains(m.messageId));
    final isFailed = msg.isMine && statusGroup.any((m) => m.status == 'failed');
    final isPending =
        msg.isMine &&
        !isFailed &&
        statusGroup.any((m) => m.status == 'sending' || m.status == 'queued');

    HapticFeedback.mediumImpact();
    final selection = await showMessageContextMenu(
      context,
      tapPosition: tapPosition,
      isMine: msg.isMine,
      showCopy: showCopy,
      showEdit: showEdit,
      isPinned: isPinned,
      currentMyReaction: msg.myReaction,
      isPending: isPending,
      isFailed: isFailed,
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
      case MessageMenuAction.cancelSend:
        await _cancelSend(groupMessageIds ?? [msg.messageId], msg.groupId);
        break;
      case MessageMenuAction.retrySend:
        await _retrySend(msg.groupId ?? msg.messageId);
        break;
    }
  }

  /// "Отменить отправку" (ТЗ пользователя) — и для ещё не ушедших (часики),
  /// и для не смогших уйти (восклицательный знак) сообщений: убираем
  /// локальный пузырь и всю проделанную на клиенте работу — задание из
  /// PendingSendStore, из SendQueueStore (если уже зашифровано и ждёт
  /// подтверждения сервера), и АКТИВНУЮ ПРЯМО СЕЙЧАС загрузку файла на
  /// сервер (см. UploadCancelRegistry.cancel — реально прерывает сетевой
  /// запрос через dio.CancelToken, а не просто убирает пузырь, пока
  /// загрузка молча донашивает себя в фоне, как было раньше).
  Future<void> _cancelSend(List<String> messageIds, String? groupId) async {
    for (final id in messageIds) {
      UploadCancelRegistry.cancel(id);
    }
    final messagesToPurge = _messages
        .where((m) => messageIds.contains(m.messageId))
        .toList();
    await ChatStore.deleteMessages(widget.peerLogin, messageIds);
    await purgeAllMessageArtifacts(messagesToPurge);
    for (final m in messagesToPurge) {
      _purgeInMemoryTracking(m);
    }
    await _loadHistory();
  }

  /// "Повторить отправку" — сообщение(я) не смогли уйти (восклицательный
  /// знак): просто прямо сейчас запускаем ТОТ ЖЕ повтор, который иначе
  /// сработал бы сам при следующем реконнекте (см. PendingSendRetrier).
  Future<void> _retrySend(String jobId) async {
    final outcome = await PendingSendRetrier.instance.retryNow(jobId);
    await _loadHistory();
    if (!mounted) return;
    // Раньше при неудаче кнопка просто ничего не делала (см. разбор
    // пользовательских логов — "ощущение, что кнопка вообще не рабочая"):
    // задание к этому моменту уже мог забрать фоновый sweep и удалить как
    // окончательно неудавшееся, а UI об этом никак не сообщал.
    switch (outcome) {
      case RetryOutcome.sent:
        break;
      case RetryOutcome.notFound:
      case RetryOutcome.permanentlyFailed:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('chat.retryFailedPermanently'))),
        );
        break;
      case RetryOutcome.willRetryLater:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('chat.retryFailedTemporary'))),
        );
        break;
    }
  }

  /// "Сбросить шифрование" из меню чата (ТЗ пользователя) — ручной аналог
  /// автоматического самолечения (см. MessageRouter._onDecryptFailure: то
  /// же самое, но только после 3 подряд неудачных расшифровок). Стирает
  /// локальную сессию Double Ratchet и просит собеседника сделать то же —
  /// следующее сообщение в любую сторону само поднимет свежий X3DH.
  Future<void> _confirmAndResetSession() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          tr('chat.resetSessionTitle'),
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: Text(
          tr('chat.resetSessionBody'),
          style: TextStyle(color: AppColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              tr('common.cancel'),
              style: TextStyle(color: AppColors.primary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              tr('chat.resetSessionConfirm'),
              style: TextStyle(color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    DebugLog.log(
      'ChatScreen manual session reset requested by user for=$_currentPeerDeviceId',
    );
    await MessageRouter.resetSessionWith(
      _currentPeerDeviceId,
      reason: 'manual (chat menu)',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr('chat.resetSessionDone'))));
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
      await SendLock.run(_currentPeerDeviceId, () async {
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

        final headerFields = <String, dynamic>{
          ...next.header,
          'sender_device_id': myDeviceId,
          if (initHeader != null) ...initHeader,
        };
        final encrypted = await encryptMessage(
          next.messageKey,
          inner.encode(),
          aad: headerFields,
        );
        final envelope = <String, dynamic>{...encrypted, ...headerFields};

        await SendQueueProcessor.instance.enqueue(
          toDeviceId: _currentPeerDeviceId,
          envelope: envelope,
          deliveryId: inner.messageId,
          silent: true,
          onAcked: onAcked,
        );
      });
      return true;
    } catch (e, stackTrace) {
      DebugLog.log(
        'ChatScreen control message send FAILED type=${inner.type} '
        'to=$_currentPeerDeviceId error=$e\n$stackTrace',
      );
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
      await SendLock.run(_currentPeerDeviceId, () async {
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

        final headerFields = <String, dynamic>{
          ...next.header,
          'sender_device_id': myDeviceId,
          if (initHeader != null) ...initHeader,
        };
        final encrypted = await encryptMessage(
          next.messageKey,
          inner.encode(),
          aad: headerFields,
        );
        final envelope = <String, dynamic>{...encrypted, ...headerFields};

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
      DebugLog.log(
        'ChatScreen send OK (text messageId=$messageId) to=$_currentPeerDeviceId',
      );
    } catch (e, stackTrace) {
      DebugLog.log(
        'ChatScreen send FAILED (text messageId=$messageId) '
        'to=$_currentPeerDeviceId error=$e\n$stackTrace',
      );
      await ChatStore.updateMessageStatus(
        widget.peerLogin,
        messageId,
        'failed',
      );
      // 'failed' тут — не окончательный приговор: если это был сетевой сбой
      // (например, самая первая отправка этому собеседнику, а prekey-бандл
      // не удалось получить офлайн), PendingSendRetrier сам переотправит,
      // как только вернётся связь, и статус тогда сменится на 'sent' без
      // участия пользователя (см. ТЗ — "сообщения просто падают").
      await PendingSendStore.add({
        'id': messageId,
        'kind': 'text',
        'peer_login': widget.peerLogin,
        'peer_device_id': _currentPeerDeviceId,
        'text': text,
        'sent_at': inner.sentAt,
        if (replyToMessageId != null) 'reply_to_id': replyToMessageId,
        if (replyToPreview != null) 'reply_to_preview': replyToPreview,
      });
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
    // Кадр-превью видео-сообщения (кружка/квадрата) до отправки — тот же
    // приём, что и для обычного видео из галереи (см. _writeLocalVideoThumbnail),
    // чтобы вместо чёрного квадрата сразу было видно содержимое (ТЗ пользователя).
    final localPreviewPath = isVideo
        ? await _writeLocalVideoThumbnail(file.path)
        : null;

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
        localPreviewPath: localPreviewPath,
        // См. StoredMessage.localSourcePath — сама запись (голосовая/видео),
        // а не превью-кадр.
        localSourcePath: file.path,
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
        DebugLog.log(
          'ChatScreen send OK (${isVideo ? 'video_note' : 'voice'} '
          'messageId=$messageId, notes) size=$size',
        );
      } catch (e, stackTrace) {
        DebugLog.log(
          'ChatScreen send FAILED (${isVideo ? 'video_note' : 'voice'} '
          'messageId=$messageId, notes) size=$size error=$e\n$stackTrace',
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
        () => SendLock.run(_currentPeerDeviceId, () async {
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
          final headerFields = <String, dynamic>{
            ...next.header,
            'sender_device_id': myDeviceId,
            if (initHeader != null) ...initHeader,
          };
          final encryptedEnvelope = await encryptMessage(
            next.messageKey,
            inner.encode(),
            aad: headerFields,
          );
          final envelope = <String, dynamic>{
            ...encryptedEnvelope,
            ...headerFields,
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
      DebugLog.log(
        'ChatScreen send OK (${isVideo ? 'video_note' : 'voice'} '
        'messageId=$messageId) to=$_currentPeerDeviceId size=$size',
      );
    } catch (e, stackTrace) {
      DebugLog.log(
        'ChatScreen send FAILED (${isVideo ? 'video_note' : 'voice'} '
        'messageId=$messageId) to=$_currentPeerDeviceId size=$size '
        'error=$e\n$stackTrace',
      );
      await ChatStore.updateMessageStatus(
        widget.peerLogin,
        messageId,
        'failed',
      );
      // Устойчивая копия вместо temp-записи (см. PendingSendStore.persistFile
      // — ту ОС вправе стереть, пока приложение не запущено, что и
      // случилось у пользователя с голосовым сообщением); оригинал больше
      // не нужен, удаляем сразу.
      final persistedPath = await PendingSendStore.persistFile(file, messageId);
      try {
        await file.delete();
      } catch (_) {}
      await PendingSendStore.add({
        'id': messageId,
        'kind': isVideo ? 'video_note' : 'voice',
        'peer_login': widget.peerLogin,
        'peer_device_id': _currentPeerDeviceId,
        'peer_account_id': widget.peerAccountId,
        'file_path': persistedPath,
        'size': size,
        'duration_ms': duration.inMilliseconds,
      });
    } finally {
      await _loadHistory();
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
    final wasKeyboardVisible = _liveKeyboardInsetPx(context) > 50;
    _textFocusNode.unfocus();
    setState(() => _emojiMode = false);

    if (wasKeyboardVisible) {
      for (var i = 0; i < 30; i++) {
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        if (_liveKeyboardInsetPx(context) <= 50) break;
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
            PickedMedia(
              file: file,
              isVideo: asset.type == AssetType.video,
              isSpoiler: result.spoiler,
            ),
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
                '${tr('chat.fileTooLarge')} (${formatFileSize(size)})',
              ),
            ),
          );
        }
        continue;
      }

      final messageId = '${DateTime.now().microsecondsSinceEpoch}_$i';
      final fileName = item.file.path.split('/').last;
      // Видео (в отличие от произвольного файла) — тоже медиа: своё
      // превью (кадр из видео) и открывается во встроенном просмотрщике,
      // как фото, а не иконкой+именем (ТЗ пользователя). Генерируем кадр
      // ДО первой отрисовки пузыря — иначе первый кадр показал бы плейсхолдер
      // "нет превью", который через миг сменился бы на настоящий, заметный скачок.
      final localPreviewPath = item.isFile
          ? null
          : item.isVideo
          ? await _writeLocalVideoThumbnail(item.file.path)
          : item.file.path;
      // См. StoredMessage.localSourcePath — у видео/файла localPreviewPath
      // выше это либо превью-кадр, либо вообще null, не сам файл, поэтому
      // ссылку на исходник (тот же item.file.path, что и у фото) храним
      // отдельно, чтобы не грузить с сервера СВОЙ ЖЕ файл, который никуда
      // с телефона не делся.
      final localSourcePath = (item.isFile || item.isVideo)
          ? item.file.path
          : null;

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
          isFile: item.isFile,
          isVideo: item.isVideo,
          fileSize: size,
          chunked: size > _streamingThresholdBytes,
          fileName: fileName,
          isSpoiler: item.isSpoiler,
          status: 'sending',
          processingStep: tr('chat.queued'),
          localPreviewPath: localPreviewPath,
          localSourcePath: localSourcePath,
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

  /// Кадр-превью локально выбранного (ещё не отправленного) видео — пишется
  /// во временный файл рядом, чтобы localPreviewPath мог указывать на него
  /// точно так же, как на оригинал у обычного фото (см. _photoPreview,
  /// Image.file). null, если генерация не удалась (повреждённый файл,
  /// неподдерживаемый кодек и т.п.) — тогда просто нет превью, не ошибка.
  Future<String?> _writeLocalVideoThumbnail(String videoPath) async {
    try {
      final bytes = await generateVideoThumbnail(videoPath);
      if (bytes == null) {
        DebugLog.log(
          'ChatScreen _writeLocalVideoThumbnail: generateVideoThumbnail '
          'вернул null для videoPath=$videoPath',
        );
        return null;
      }
      // ВАЖНО: НЕ getTemporaryDirectory() — реальный кейс с устройства:
      // именно только что отправленное видео после очистки кэша (даже
      // штатной кнопкой Android в настройках приложения — она чистит ВЕСЬ
      // системный кэш, не только наш MediaCache) заново виснет/тормозит на
      // 15+ секунд, потому что этот файл (localPreviewPath, готовый кадр,
      // сгенерированный ещё при отправке) успевал пропасть вместе с
      // остальным кэшем — _resolveVideoThumbnailBytes ищет его именно
      // здесь, и, не найдя, откатывается на медленный путь "перекачать
      // видео целиком + сгенерировать кадр заново нативно". Временную
      // папку ОС вправе стереть в любой момент (тот же принцип, что уже
      // объяснён у PendingSendStore.persistFile) — постоянное хранилище
      // приложения (getApplicationSupportDirectory) этому не подвержено.
      final dir = await getApplicationSupportDirectory();
      final thumbDir = Directory('${dir.path}/video_thumbs');
      await thumbDir.create(recursive: true);
      final thumbFile = File(
        '${thumbDir.path}/vthumb_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      await thumbFile.writeAsBytes(bytes);
      DebugLog.log(
        'ChatScreen _writeLocalVideoThumbnail: OK, '
        'thumbPath=${thumbFile.path} bytes=${bytes.length}',
      );
      return thumbFile.path;
    } catch (e) {
      DebugLog.log(
        'ChatScreen _writeLocalVideoThumbnail FAILED videoPath=$videoPath error=$e',
      );
      return null;
    }
  }

  /// Шифрует и грузит один файл на сервер — тонкая обёртка над общей
  /// логикой из media_upload.dart (переиспользуется и PendingSendRetrier
  /// для автоматического повтора после сбоя сети, см. ТЗ пользователя).
  Future<Map<String, dynamic>> _uploadAndDescribeMedia(
    PickedMedia item,
    String messageId,
    int size,
    String fileName,
    String token,
    String peerAccountIdForUpload,
  ) {
    return media_upload.uploadAndDescribeMedia(
      peerLogin: widget.peerLogin,
      item: item,
      messageId: messageId,
      size: size,
      fileName: fileName,
      token: token,
      peerAccountIdForUpload: peerAccountIdForUpload,
      onProgress: _uploadProgressUpdater(messageId),
    );
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
        DebugLog.log(
          'ChatScreen send OK (media messageId=$messageId, notes) '
          'kind=${_mediaKindLabel(item)} size=$size',
        );
      } catch (e, stackTrace) {
        DebugLog.log(
          'ChatScreen send FAILED (media messageId=$messageId, notes) '
          'kind=${_mediaKindLabel(item)} size=$size error=$e\n$stackTrace',
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
        () => SendLock.run(_currentPeerDeviceId, () async {
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
            isFile: item.isFile,
            isVideo: item.isVideo,
            fileSize: size,
            chunked: desc['chunked'] as bool,
            spoiler: item.isSpoiler,
          );

          final next = await state.nextSendingKey();
          DebugLog.log(
            'ChatScreen sending key (media messageId=${inner.messageId}) '
            'to=$_currentPeerDeviceId messageNumber=${next.header['message_number']} '
            'ratchetPubkey=${next.header['ratchet_pubkey']}',
          );
          await SessionStore.saveState(_currentPeerDeviceId, state);
          final headerFields = <String, dynamic>{
            ...next.header,
            'sender_device_id': myDeviceId,
            if (initHeader != null) ...initHeader,
          };
          final encryptedEnvelope = await encryptMessage(
            next.messageKey,
            inner.encode(),
            aad: headerFields,
          );
          final envelope = <String, dynamic>{
            ...encryptedEnvelope,
            ...headerFields,
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
      DebugLog.log(
        'ChatScreen send OK (media messageId=$messageId) '
        'to=$_currentPeerDeviceId kind=${_mediaKindLabel(item)} size=$size',
      );
    } catch (e, stackTrace) {
      DebugLog.log(
        'ChatScreen send FAILED (media messageId=$messageId) '
        'to=$_currentPeerDeviceId kind=${_mediaKindLabel(item)} size=$size '
        'error=$e\n$stackTrace',
      );
      await ChatStore.updateMessageStatus(
        widget.peerLogin,
        messageId,
        'failed',
      );
      // Оригинал пользователя (галерея/пикер) не трогаем — снимаем
      // отдельную устойчивую копию для PendingSendRetrier (см. тот же
      // приём в _sendRecordedMessage выше и PendingSendStore.persistFile).
      final persistedPath = await PendingSendStore.persistFile(
        item.file,
        messageId,
      );
      await PendingSendStore.add({
        'id': messageId,
        'kind': 'media',
        'peer_login': widget.peerLogin,
        'peer_device_id': _currentPeerDeviceId,
        'peer_account_id': widget.peerAccountId,
        'file_path': persistedPath,
        'size': size,
        'file_name': fileName,
        'is_file': item.isFile,
        'is_video': item.isVideo,
        'is_spoiler': item.isSpoiler,
      });
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
          DebugLog.log(
            'ChatScreen group upload attempt (notes) groupId=$groupId '
            'messageId=${q.messageId} kind=${_mediaKindLabel(q.item)} '
            'size=${q.size}',
          );
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
        DebugLog.log(
          'ChatScreen group send OK (notes) groupId=$groupId count=${items.length}',
        );
      } catch (e, stackTrace) {
        DebugLog.log(
          'ChatScreen group send FAILED (notes) groupId=$groupId '
          'count=${items.length} error=$e\n$stackTrace',
        );
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
        () => SendLock.run(_currentPeerDeviceId, () async {
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
            DebugLog.log(
              'ChatScreen group upload attempt groupId=$groupId '
              'messageId=${q.messageId} kind=${_mediaKindLabel(q.item)} '
              'size=${q.size}',
            );
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
            messageId: groupId,
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
          final headerFields = <String, dynamic>{
            ...next.header,
            'sender_device_id': myDeviceId,
            if (initHeader != null) ...initHeader,
          };
          final encryptedEnvelope = await encryptMessage(
            next.messageKey,
            inner.encode(),
            aad: headerFields,
          );
          final envelope = <String, dynamic>{
            ...encryptedEnvelope,
            ...headerFields,
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
      DebugLog.log(
        'ChatScreen group send OK (enqueued, awaiting ack) groupId=$groupId '
        'to=$_currentPeerDeviceId count=${items.length}',
      );
    } catch (e, stackTrace) {
      DebugLog.log(
        'ChatScreen group send FAILED groupId=$groupId '
        'to=$_currentPeerDeviceId count=${items.length} error=$e\n$stackTrace',
      );
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
      // Оригиналы пользователя не трогаем — снимаем устойчивую копию
      // каждого файла группы для PendingSendRetrier (тот же приём, что и
      // для одиночного медиа/голосового выше, см. PendingSendStore.persistFile).
      final persistedItems = <Map<String, dynamic>>[];
      for (final q in items) {
        final persistedPath = await PendingSendStore.persistFile(
          q.item.file,
          q.messageId,
        );
        persistedItems.add({
          'message_id': q.messageId,
          'file_path': persistedPath,
          'size': q.size,
          'file_name': q.fileName,
          'is_file': q.item.isFile,
          'is_video': q.item.isVideo,
          'is_spoiler': q.item.isSpoiler,
        });
      }
      await PendingSendStore.add({
        'id': groupId,
        'kind': 'media_group',
        'peer_login': widget.peerLogin,
        'peer_device_id': _currentPeerDeviceId,
        'peer_account_id': widget.peerAccountId,
        'caption': caption,
        'text_message_id': textMessageId,
        'items': persistedItems,
      });
    } finally {
      await _loadHistory();
    }
  }

  /// Готовит расшифрованный файл (голосового/видео-сообщения/крупного
  /// медиа) для плеера/просмотрщика. Тап "проиграть/открыть" — явное
  /// действие пользователя, поэтому userInitiated: true (высший приоритет,
  /// вытесняет фоновую авто-закачку).
  Future<File> _resolveRecordedMediaFile(
    StoredMessage msg, {
    void Function(double percent)? onProgress,
    bool userInitiated = true,
  }) {
    return _ensureMediaFile(
      msg,
      userInitiated: userInitiated,
      onProgress: onProgress,
    );
  }

  /// Тап "открыть файл" — явное действие пользователя: качаем с высшим
  /// приоритетом (см. _ensureMediaFile / MediaDownloadManager), докачивая
  /// с места обрыва, если хвост уже есть. Повторный тап по уже
  /// скачивающемуся — MediaDownloadManager сам не заводит вторую закачку
  /// того же mediaId, просто поднимает его приоритет.
  Future<void> _openFile(StoredMessage msg) async {
    try {
      final sourceFile = await _ensureMediaFile(msg, userInitiated: true);

      final tempDir = await getTemporaryDirectory();
      final namedFile = File('${tempDir.path}/${msg.fileName ?? 'file'}');
      await sourceFile.copy(namedFile.path);

      // ТЗ пользователя: тап по файлу должен всегда предлагать выбрать
      // приложение — см. OpenWithChooser (нативный Intent.createChooser,
      // Android-only). OpenFile.open ниже — фоллбэк на остальных
      // платформах/если нативный вызов почему-то не сработал (плагин сам
      // умеет и iOS, и десктоп).
      if (await OpenWithChooser.open(namedFile.path)) return;

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

  /// "Сохранить на устройство" (ТЗ пользователя) — только для msg.isFile,
  /// только пока файл физически уже на диске (см. её вызов в
  /// _clickableFileRow — пункт меню показан лишь при _mediaExistsLocally,
  /// повторяет ЕЁ же проверку, а не свою: одна и та же логика "файл здесь"
  /// должна давать один и тот же ответ везде).
  ///
  /// Раньше здесь был системный SAF-диалог "Сохранить как"
  /// (file_picker.saveFile) — на части устройств/эмуляторов без нормального
  /// Files-провайдера он просто ничего не показывает (реальный кейс с
  /// эмулятора: тап — и тишина, никакого диалога). Вместо него — фиксированное
  /// предсказуемое место, Download/Oshinobu (см. DownloadsSaver/
  /// MainActivity.kt), с уведомлением о точном пути после сохранения — тот
  /// же принцип, что и getUserMedia-подобные приложения (Telegram и т.п.).
  Future<void> _saveFileToDevice(StoredMessage msg) async {
    try {
      // Тот же путь, что и в _openFile — _ensureMediaFile СНАЧАЛА пробует
      // локальный источник, сеть не трогает: canSave (см. _clickableFileRow)
      // уже гарантирует, что файл физически на диске.
      final sourceFile = await _ensureMediaFile(msg, userInitiated: true);
      final savedPath = await DownloadsSaver.save(
        sourceFile.path,
        msg.fileName ?? msg.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            savedPath != null
                ? '${tr('chat.savedToDevice')}: $savedPath'
                : tr('chat.saveToDeviceFailed'),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${tr('chat.saveToDeviceFailed')}: $e')),
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
      // Пузырь выглядит РОВНО так же, как уже отправленное фото — статус
      // (часики / маленький восклицательный знак) показывает только строка
      // времени под пузырём (см. _buildStatusIconFor), не сам превью. Раньше
      // 'failed' затемняло превью и рисовало поверх огромную (40px) красную
      // иконку — из-за неё отправленная разом группа фото визуально
      // переставала читаться как единый альбом (ТЗ пользователя: "все
      // сообщения в чате, вне зависимости от их статуса, всегда должны
      // отображаться одинаково").
      final uploadPhase = msg.processingStep != null
          ? _uploadPhaseFor(msg)
          : null;
      return Stack(
        children: [
          if (msg.localPreviewPath != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: size,
                height: size,
                child: _withVideoPlayBadge(
                  Image.file(File(msg.localPreviewPath!), fit: BoxFit.cover),
                  show: msg.isVideo,
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
          if (uploadPhase != null)
            MediaStatusOverlay(
              statusText: uploadPhase.text,
              percent: uploadPhase.percent,
              size: size,
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

    // Синхронно (см. _mediaExistsLocally/MediaCache.existsSync) — как и в
    // _photoPreview, никакой нужды в FutureBuilder ради вопроса, ответ на
    // который и так уже известен без похода в async.
    if (_mediaExistsLocally(msg)) {
      return msg.isFile
          ? _clickableFileRow(msg, size: size)
          : _photoPreview(msg, size: size);
    }
    // Файлы — строкой (имя+иконка+размер), у них нет своей картинки, им
    // это идёт. А вот фото/видео, которым просто требуется ручное
    // скачивание (крупный размер), ДОЛЖНЫ остаться квадратной плиткой
    // ТОГО ЖЕ размера, что и уже скачанные — иначе группа из нескольких
    // фото/видео визуально ломается: строка вместо плитки занимает не то
    // место, и сетка теряет один из своих "лотов" (жалоба пользователя,
    // видео в группе рисовалось как имя файла со стрелочкой, а не как
    // третья плитка в сетке).
    return msg.isFile ? _downloadPromptRow(msg) : _mediaDownloadTile(msg, size);
  }

  /// Квадратная плитка "нужно скачать вручную" для крупного (> 3 МБ) не
  /// своего фото/видео — см. _buildAttachmentBubble. Тап = явный запрос
  /// пользователя: MediaDownloadManager.requestUserDownload (высший
  /// приоритет, вытесняет фоновую авто-закачку), а отрисовку прогресса/
  /// картинки дальше ведёт _photoPreview.
  Widget _mediaDownloadTile(StoredMessage msg, double size) {
    if (_mediaFutures.containsKey(msg.mediaId) || _isDownloading(msg.mediaId)) {
      return _photoPreview(msg, size: size);
    }
    return GestureDetector(
      onTap: () {
        final spec = _downloadSpecOf(msg);
        if (spec == null) return;
        MediaDownloadManager.instance.requestUserDownload(spec);
        setState(() {
          _downloadProgress[msg.mediaId!] = 0;
          _mediaFutures[msg.mediaId!] = _resolvePhotoBytes(
            msg,
            userInitiated: true,
          ).then((bytes) {
            if (mounted) {
              setState(() => _resolvedMedia[msg.mediaId!] = bytes);
            }
            return bytes;
          }).catchError((Object e) {
            _mediaFutures.remove(msg.mediaId);
            if (mounted) setState(() {});
            throw e;
          });
        });
      },
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppColors.textMuted.withValues(alpha: 0.35),
          ),
        ),
        child: Center(
          child: Icon(Icons.download, color: AppColors.textPrimary, size: 32),
        ),
      ),
    );
  }

  /// Только для msg.isFile — строка "иконка + имя + размер" с тапом на
  /// скачивание. Фото/видео используют _mediaDownloadTile (квадратная
  /// плитка, см. _buildAttachmentBubble) — своей картинки у файла нет, ему
  /// строчный вид как раз идёт, а плитке-заглушке взяться неоткуда.
  ///
  /// ТЗ пользователя: у ЛЮБОГО файла (вне зависимости от типа) должен быть
  /// текстовый статус происходящего и кнопка отмены закачки. Тап =
  /// пользовательский запрос (MediaDownloadManager.requestUserDownload —
  /// высший приоритет + докачка с места обрыва); ✕ = отказ (снести хвост).
  Widget _downloadPromptRow(StoredMessage msg) {
    final downloading = _isDownloading(msg.mediaId);
    final isActive = _isDownloadActive(msg.mediaId);

    void startDownload() {
      final spec = _downloadSpecOf(msg);
      if (spec == null) return;
      MediaDownloadManager.instance.requestUserDownload(spec);
      setState(() => _downloadProgress[msg.mediaId!] = 0);
    }

    return InkWell(
      onTap: downloading ? null : startDownload,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (downloading)
            const SizedBox(
              width: 28,
              height: 28,
              child: Center(child: AppLoadingIndicator(size: 18)),
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
                downloading
                    ? (isActive
                          ? '${tr('media.downloading')} '
                                '${(_downloadProgress[msg.mediaId!] ?? 0).round()}%'
                          : tr('chat.queued'))
                    : formatFileSize(msg.fileSize),
                style: TextStyle(color: AppColors.textMuted, fontSize: 11),
              ),
            ],
          ),
          if (downloading) ...[
            const SizedBox(width: 4),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                MediaDownloadManager.instance.cancelUserDownload(msg.mediaId!);
                setState(() {});
              },
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(Icons.close, color: AppColors.textMuted, size: 18),
              ),
            ),
          ],
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

  /// ТЗ пользователя: у ЛЮБОГО файла (вне зависимости от типа — не только
  /// фото/видео) должен быть текстовый статус происходящего, а скачивание
  /// должно начинаться само, а не только по тапу. Раньше здесь ничего из
  /// этого не было: этот путь — "маленький/свой" случай (см.
  /// _buildAttachmentBubble — большой ЧУЖОЙ файл идёт через
  /// _downloadPromptRow, у него это уже есть), файл просто молча ждал тапа
  /// без единого признака, что вообще происходит.
  Widget _clickableFileRow(StoredMessage msg, {double size = 220}) {
    final sending = msg.isMine && msg.processingStep != null;
    final failed = msg.isMine && msg.status == 'failed';
    final needsDownload = !sending && !failed && !_mediaExistsLocally(msg);

    if (needsDownload) {
      // Мелкие (< 3 МБ) не свои файлы — в авто-очередь по факту показа на
      // экране (см. _noteMediaVisible / MediaDownloadManager); крупные и
      // свои (без локального источника) ждут явного тапа -> _openFile.
      _noteMediaVisible(msg);
    }

    final downloading = needsDownload && _isDownloading(msg.mediaId);
    final isActive = _isDownloadActive(msg.mediaId);
    final statusText = sending
        ? _processingStepDisplay(msg)
        : failed
        ? tr('error.uploadFailed')
        : downloading
        ? (isActive ? tr('media.downloading') : tr('chat.queued'))
        : null;
    final percent = (downloading && isActive)
        ? (_downloadProgress[msg.mediaId!] ?? 0)
        : null;
    final icon = failed ? Icons.error_outline : _iconForFileName(msg.fileName);
    final tappable = !sending && !failed && !downloading;
    final cancel = downloading
        ? () {
            MediaDownloadManager.instance.cancelUserDownload(msg.mediaId!);
            setState(() {});
          }
        : null;
    // ТЗ пользователя: "⋮ → Сохранить на устройство" — ТОЛЬКО пока файл
    // физически уже на диске (та же проверка, что и выше решает, нужно ли
    // качать) — если кэш почистили и файл не скачан заново, пункта тут
    // быть не должно. cancel и canSave никогда не бывают true одновременно
    // (canSave требует "файл уже здесь", cancel — "ещё качается"), поэтому
    // безопасно рисовать их в одном и том же месте макета.
    final canSave = tappable && !needsDownload;

    if (size < 200) {
      return InkWell(
        onTap: tappable ? () => _openFile(msg) : cancel,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (downloading)
                AppLoadingIndicator(size: 22, color: AppColors.textMuted)
              else
                Icon(
                  icon,
                  color: failed ? Colors.redAccent : AppColors.textMuted,
                  size: 32,
                ),
              if (cancel != null)
                Positioned(
                  top: 2,
                  right: 2,
                  child: GestureDetector(
                    onTap: cancel,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        color: Colors.black45,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close,
                        color: Colors.white,
                        size: 12,
                      ),
                    ),
                  ),
                ),
              if (canSave)
                Positioned(
                  top: 2,
                  right: 2,
                  child: _saveFileMenu(msg, color: Colors.white, badge: true),
                ),
            ],
          ),
        ),
      );
    }
    return InkWell(
      onTap: tappable ? () => _openFile(msg) : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (downloading)
            SizedBox(
              width: 28,
              height: 28,
              child: Center(
                child: AppLoadingIndicator(
                  size: 20,
                  color: _bubbleTextColor(msg.isMine),
                ),
              ),
            )
          else
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
              if (statusText != null)
                Text(
                  percent != null
                      ? '$statusText ${percent.round()}%'
                      : statusText,
                  style: TextStyle(
                    color: failed
                        ? Colors.redAccent
                        : _bubbleTextColor(msg.isMine).withValues(alpha: 0.7),
                    fontSize: 11,
                  ),
                ),
            ],
          ),
          if (cancel != null) ...[
            const SizedBox(width: 4),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: cancel,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(
                  Icons.close,
                  color: _bubbleTextColor(msg.isMine).withValues(alpha: 0.7),
                  size: 18,
                ),
              ),
            ),
          ],
          if (canSave) _saveFileMenu(msg, color: _bubbleTextColor(msg.isMine)),
        ],
      ),
    );
  }

  /// "⋮" → "Сохранить на устройство" (ТЗ пользователя) — единственный
  /// пункт меню. Показывается вызывающей стороной ТОЛЬКО когда файл уже
  /// физически на диске (см. canSave в _clickableFileRow) — сам этот
  /// виджет ничего не проверяет повторно, только рисует.
  ///
  /// НЕ PopupMenuButton — тот всегда навязывает свой внутренний IconButton
  /// со стандартным (минимум 48x48) тач-таргетом поверх любых constraints/
  /// padding, которые ему передашь (жалоба пользователя: "пузырь разросся
  /// в размерах"). Вместо него — тот же самый компактный приём, что уже
  /// используется рядом для кнопки отмены (cancel) — голый
  /// GestureDetector + showMenu() по месту тапа, без единого пикселя
  /// зарезервированного пространства сверх самой иконки.
  Widget _saveFileMenu(StoredMessage msg, {Color? color, bool badge = false}) {
    Offset tapPos = Offset.zero;
    final icon = Icon(
      Icons.more_vert,
      color: color ?? AppColors.textMuted,
      size: badge ? 14 : 18,
    );
    final button = Builder(
      builder: (context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) => tapPos = details.globalPosition,
        onTap: () async {
          final overlayBox =
              Overlay.of(context).context.findRenderObject() as RenderBox;
          final selected = await showMenu<bool>(
            context: context,
            position: RelativeRect.fromRect(
              tapPos & const Size(1, 1),
              Offset.zero & overlayBox.size,
            ),
            items: [
              PopupMenuItem<bool>(
                value: true,
                child: Text(tr('chat.saveToDevice')),
              ),
            ],
          );
          if (selected == true) await _saveFileToDevice(msg);
        },
        child: Padding(padding: EdgeInsets.all(badge ? 3 : 6), child: icon),
      ),
    );
    if (!badge) return button;
    return Container(
      decoration: const BoxDecoration(
        color: Colors.black45,
        shape: BoxShape.circle,
      ),
      child: button,
    );
  }

  /// Список всех фото текущего чата (то, что реально может показать
  /// просмотрщик) в порядке появления в чате — используется и для
  /// определения стартового индекса, и как набор страниц для листания.
  List<StoredMessage> _viewablePhotos() => _messages
      .where((m) => m.isMedia && !m.isFile && !m.isVoice && !m.isVideoNote)
      .toList();

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
          // Пользователь открыл просмотрщик — то, что он смотрит, качаем с
          // высшим приоритетом (userInitiated), а не в фоновой авто-очереди.
          resolveBytes: (m, {onProgress}) =>
              _resolvePhotoBytes(m, onProgress: onProgress, userInitiated: true),
          isVideo: (m) => m.isVideo,
          resolveVideoFile: (m, {onProgress}) =>
              _resolveRecordedMediaFile(m, onProgress: onProgress),
        ),
      ),
    );
  }

  /// Фото со спойлером (см. StoredMessage.isSpoiler) до раскрытия — блюр +
  /// анимированная мерцающая пыль поверх (см. SpoilerSparkleOverlay), тем
  /// же эффектом, что у Телеги: без иконки и подписи поверх самого фото —
  /// у Телеги на фото ничего не написано, есть только обычная подпись
  /// сообщения под пузырём, если она задана. Первый тап только раскрывает
  /// (см. _revealedSpoilerIds), открыть просмотрщик можно только
  /// СЛЕДУЮЩИМ, уже по раскрытому фото — как и в Телеге.
  /// Общее содержимое резерва под эмодзи-панель — вынесено отдельно, чтобы
  /// не дублировать один и тот же виджет в обеих ветках (Container вместо
  /// AnimatedContainer, см. их выбор у emojiReserved в build()).
  Widget? _buildEmojiPickerChild(bool keyboardVisible) {
    if (!_emojiMode && !keyboardVisible) return null;
    return Offstage(
      offstage: !_emojiMode,
      child: ClipRect(
        child: RepaintBoundary(
          child: FullEmojiPicker(
            onEmojiSelected: (emoji) {
              _textController.text += emoji;
            },
          ),
        ),
      ),
    );
  }

  /// Общий errorBuilder для Image.memory (см. её вызовы ниже) — без него
  /// сбой ДЕКОДИРОВАНИЯ (не скачивания — байты уже есть и уже прошли
  /// наш собственный broken_image-фоллбэк FutureBuilder'а, это отдельный,
  /// более поздний шаг) уходит во внутренний обработчик Flutter'овского
  /// _ImageState, который, будучи неотловленным исключением, под
  /// VM-дебаггером с "pause on uncaught exceptions" вешает ВЕСЬ изолят —
  /// реальный кейс с устройства: "Failed to create image decoder...
  /// unimplemented" (похоже на ограничение декодера конкретно на
  /// эмуляторе — реальные фото с Pixel иногда используют формат вроде
  /// Ultra HDR, который его софтверный декодер не умеет). В продакшене
  /// (без дебаггера) Flutter и так проглотил бы это тихо, но полагаться на
  /// внутренний путь фреймворка вместо явной обработки — не наш случай.

  Widget _photoPreview(StoredMessage msg, {double size = 220}) {
    if (msg.isVideo) {
      debugPrint(
        'ChatScreen[${identityHashCode(this)}] _photoPreview CALLED '
        'messageId=${msg.messageId} mediaId=${msg.mediaId} isVideo=true',
      );
    }
    final double side = size;
    final isHiddenSpoiler =
        msg.isSpoiler && !_revealedSpoilerIds.contains(msg.messageId);
    void handleTap() {
      if (isHiddenSpoiler) {
        setState(() => _revealedSpoilerIds.add(msg.messageId));
      } else {
        _openMediaViewer(msg);
      }
    }

    var cached = _resolvedMedia[msg.mediaId!];
    // Синхронное чтение прямо в build() для уже скачанного ФОТО (не
    // видео — там превью не читается напрямую отсюда, а отдельно
    // генерируется, синхронно недостижимо) — без этого даже при
    // синхронно-известном "файл уже здесь" (_mediaExistsLocally ниже)
    // само чтение байт всё равно шло бы через FutureBuilder и минимум
    // один кадр показывало бы спиннер-заглушку вместо самого фото (жалоба
    // пользователя: "почему нельзя сразу отображать превью фото?"). Один
    // раз успешно прочитанное сразу же попадает в _resolvedMedia — все
    // следующие построения этого же виджета используют уже его, эта
    // ветка больше не сработает повторно.
    if (cached == null && !msg.isVideo) {
      cached = MediaCache.readSync(msg.mediaId!);
      if (cached == null &&
          msg.isMine &&
          !msg.isVideoNote &&
          !msg.isFile &&
          msg.localPreviewPath != null) {
        try {
          final localFile = File(msg.localPreviewPath!);
          if (localFile.existsSync()) {
            cached = localFile.readAsBytesSync();
          }
        } catch (_) {
          // Не удалось — просто идём обычным (асинхронным) путём ниже.
        }
      }
      if (cached != null) _resolvedMedia[msg.mediaId!] = cached;
    }
    if (cached != null) {
      return GestureDetector(
        onTap: handleTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: side,
            height: side,
            child: _withVideoPlayBadge(
              msg.isSpoiler
                  ? SpoilerFadeImage(
                      bytes: cached,
                      side: side,
                      revealed: !isHiddenSpoiler,
                    )
                  : SafeMemoryImage(
                      bytes: cached,
                      fit: BoxFit.cover,
                      cacheWidth: (side * 2).round(),
                    ),
              show: msg.isVideo,
            ),
          ),
        ),
      );
    }

    // Локальное чтение (свой файл ещё на диске / уже в кэше) идёт в обход
    // сети и очередей внутри _ensureMediaFile. Для не своих мелких (< 3 МБ)
    // — фиксируем "показалось на экране" (авто-очередь,
    // MediaDownloadManager); крупные не свои сюда не попадают (см.
    // _buildAttachmentBubble -> _mediaDownloadTile).
    final localOnly = _mediaExistsLocally(msg);
    if (!localOnly) _noteMediaVisible(msg);
    final future = _mediaFutures.putIfAbsent(
      msg.mediaId!,
      () => _resolvePhotoBytes(msg)
              .then((bytes) {
                // Проставляем результат ЗДЕСЬ, на уровне всего экрана чата, а не
                // только полагаемся на builder этого FutureBuilder ниже — жалоба
                // пользователя: "фото докачалось до 100%, но превью не появилось,
                // помогает только выход и повторный вход в чат". Если конкретный
                // виджет этого пузыря к моменту завершения загрузки был
                // утилизирован ListView.builder (проскроллили мимо) или экран
                // перестроился — Flutter сам гасит подписку своего FutureBuilder
                // при dispose, и её собственный "готово"-колбэк просто никогда не
                // срабатывает, хотя байты уже реально на диске (см. debug_log —
                // одни и те же mediaId докачивались повторно спустя МИНУТЫ, потому
                // что _resolvedMedia так и не обновился с первого раза). setState
                // здесь не привязан к жизни конкретного виджета пузыря — сработает
                // в любом случае.
                debugPrint(
                  'ChatScreen[${identityHashCode(this)}] _photoPreview '
                  'putIfAbsent.then FIRED messageId=${msg.messageId} '
                  'mediaId=${msg.mediaId} bytes=${bytes.length} mounted=$mounted',
                );
                if (mounted)
                  setState(() => _resolvedMedia[msg.mediaId!] = bytes);
                return bytes;
              })
              .catchError((Object e) {
                // Ошибка/отмена/кулдаун — убираем задачу из карты, чтобы
                // следующая ЕСТЕСТВЕННАЯ перестройка (скролл, новое
                // сообщение, событие от MediaDownloadManager) попробовала
                // заново. Никакого setState здесь — иначе на постоянно
                // висящей на экране плитке (см. _noteMediaVisible) при
                // недоступном сервере получался бы busy-loop перерисовок;
                // реальные сбои и так дают перерисовку через _dlFailedSub.
                debugPrint(
                  'ChatScreen[${identityHashCode(this)}] _photoPreview '
                  'putIfAbsent.catchError messageId=${msg.messageId} '
                  'mediaId=${msg.mediaId} error=$e',
                );
                _mediaFutures.remove(msg.mediaId);
                throw e;
              }),
    );

    // Синхронный, всегда-актуальный флаг "файл уже физически на
    // устройстве" (см. _mediaExistsLocally и MediaCache.existsSync) —
    // считаем его ДО FutureBuilder, а не внутри его "не готово"-ветки:
    // сама асинхронность проверки (а не факт реального отсутствия файла)
    // и была причиной вспышки текста "Скачивание/В очереди" на уже
    // скачанных фото (жалоба пользователя) — FutureBuilder гарантированно
    // проходит через "не готово" минимум один кадр, даже когда файл давно
    // на диске и чтение займёт микросекунды. Раз мы и так уже знаем ответ
    // синхронно, этот кадр вообще не должен показывать никакого текста.
    final existsLocally = _mediaExistsLocally(msg);

    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snapshot) {
        // Диагностика "видео/фото не появляется, хотя данные уже
        // разрешены" — видно ли этот builder ВООБЩЕ, из какого State
        // (identityHashCode) он вызван, и что snapshot думает о состоянии
        // future в этот самый момент.
        debugPrint(
          'ChatScreen[${identityHashCode(this)}] _photoPreview builder '
          'messageId=${msg.messageId} mediaId=${msg.mediaId} '
          'connectionState=${snapshot.connectionState} '
          'hasData=${snapshot.hasData} hasError=${snapshot.hasError} '
          'resolvedMediaHas=${_resolvedMedia.containsKey(msg.mediaId)}',
        );
        if (snapshot.connectionState != ConnectionState.done) {
          final isActive = _isDownloadActive(msg.mediaId);
          // GestureDetector с пустым onTap — гасит тап здесь же, не давая
          // ему "утечь" в родительский обработчик строки (см.
          // _wrapInteractive): у этой заглушки самой по себе нет
          // содержательного действия на тап (нечего открывать, пока файл
          // не готов), но БЕЗ поглощения тап проваливался в общий тап по
          // сообщению — реальный баг: пока превью видео зависало (см.
          // _resolveVideoThumbnailBytes), тап по нему открывал контекстное
          // меню сообщения, а не бездействовал.
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: Container(
              width: side,
              height: side,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: AppColors.textMuted.withValues(alpha: 0.35),
                ),
              ),
              child: existsLocally
                  ? const Center(child: AppLoadingIndicator(size: 22))
                  : Stack(
                      children: [
                        MediaStatusOverlay(
                          statusText: isActive
                              ? tr('media.downloading')
                              : tr('chat.queued'),
                          percent: isActive
                              ? (_downloadProgress[msg.mediaId!] ?? 0)
                              : null,
                          size: side,
                          borderRadius: BorderRadius.circular(13),
                          onCancel: () {
                            MediaDownloadManager.instance.cancelUserDownload(
                              msg.mediaId!,
                            );
                            _mediaFutures.remove(msg.mediaId);
                            setState(() {});
                          },
                        ),
                      ],
                    ),
            ),
          );
        }
        if (snapshot.hasError || snapshot.data == null) {
          // Тап — явная повторная попытка пользователя: высший приоритет и
          // мимо кулдауна (см. MediaDownloadManager.requestUserDownload).
          return GestureDetector(
            onTap: () {
              final spec = _downloadSpecOf(msg);
              if (spec != null) {
                MediaDownloadManager.instance.requestUserDownload(spec);
              }
              _mediaFutures.remove(msg.mediaId);
              setState(() {});
            },
            child: SizedBox(
              width: side,
              height: side,
              child: const Center(
                child: Icon(Icons.refresh, color: Colors.red),
              ),
            ),
          );
        }

        _resolvedMedia[msg.mediaId!] = snapshot.data!;

        return GestureDetector(
          onTap: handleTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: side,
              height: side,
              child: _withVideoPlayBadge(
                msg.isSpoiler
                    ? SpoilerFadeImage(
                        bytes: snapshot.data!,
                        side: side,
                        revealed: !isHiddenSpoiler,
                      )
                    : SafeMemoryImage(
                        bytes: snapshot.data!,
                        fit: BoxFit.cover,
                        cacheWidth: (side * 2).round(),
                      ),
                show: msg.isVideo,
              ),
            ),
          ),
        );
      },
    );
  }

  /// Полупрозрачный треугольник play поверх кадра-превью — единственный
  /// способ отличить видео от фото в сетке/пузыре, пока не тапнули (сам
  /// _photoPreview показывает и то, и другое одинаково, см. ТЗ пользователя
  /// — оба типа получили общее превью).
  Widget _withVideoPlayBadge(Widget child, {required bool show}) {
    if (!show) return child;
    return Stack(
      fit: StackFit.expand,
      alignment: Alignment.center,
      children: [
        child,
        Container(
          decoration: const BoxDecoration(
            color: Colors.black38,
            shape: BoxShape.circle,
          ),
          padding: const EdgeInsets.all(8),
          child: const Icon(Icons.play_arrow, color: Colors.white, size: 22),
        ),
      ],
    );
  }

  Future<Uint8List> _resolvePhotoBytes(
    StoredMessage msg, {
    void Function(double percent)? onProgress,
    bool userInitiated = false,
  }) async {
    if (msg.isVideo) {
      return _resolveVideoThumbnailBytes(
        msg,
        onProgress: onProgress,
        userInitiated: userInitiated,
      );
    }
    final file = await _ensureMediaFile(
      msg,
      userInitiated: userInitiated,
      onProgress: onProgress,
    );
    return file.readAsBytes();
  }

  // Кадр-превью видео (для пузыря в чате и как fallback-картинка при
  // "Сохранить в галерею", если полноценный файл почему-то недоступен) —
  // отдельный кэш от _resolvedMedia, потому что там лежит РЕАЛЬНЫЙ файл
  // видео (нужен просмотрщику для проигрывания), а тут — маленький JPEG.
  final Map<String, Uint8List> _videoThumbCache = {};

  Future<Uint8List> _resolveVideoThumbnailBytes(
    StoredMessage msg, {
    void Function(double percent)? onProgress,
    bool userInitiated = false,
  }) async {
    final cachedThumb = _videoThumbCache[msg.mediaId!];
    debugPrint(
      'ChatScreen[${identityHashCode(this)}] _resolveVideoThumbnailBytes '
      'ENTER messageId=${msg.messageId} mediaId=${msg.mediaId} '
      'cachedThumb=${cachedThumb != null}',
    );
    if (cachedThumb != null) return cachedThumb;

    // РЕАЛЬНЫЙ баг (жалоба пользователя): своё же видео после очистки
    // MediaCache вечно висело в статусе загрузки — тап по нему уходил
    // "мимо" (никакого onTap на этой заглушке нет) прямо в контекстное
    // меню сообщения родителем. Причина — этот метод ВСЕГДА требовал
    // сначала полноценно скачать/схидрировать ВЕСЬ видеофайл (см. ниже) и
    // только потом сгенерировать превью через нативный
    // generateVideoThumbnail — а тот на эмуляторе, как уже задокументировано
    // (см. _raceStall), может просто зависнуть намертво без единой ошибки.
    // При этом у СВОЕГО видео готовый кадр-превью уже давно существует —
    // тот самый localPreviewPath, записанный ЕЩЁ в момент отправки (см.
    // _writeLocalVideoThumbnail в _sendPickedMedia) — ничего заново
    // генерировать не нужно, только прочитать уже готовый файл.
    DebugLog.log(
      'ChatScreen _resolveVideoThumbnailBytes: messageId=${msg.messageId} '
      'isMine=${msg.isMine} localPreviewPath=${msg.localPreviewPath}',
    );
    if (msg.isMine && msg.localPreviewPath != null) {
      final previewFile = File(msg.localPreviewPath!);
      final exists = await previewFile.exists();
      DebugLog.log(
        'ChatScreen _resolveVideoThumbnailBytes: localPreviewPath exists=$exists',
      );
      debugPrint(
        'ChatScreen[${identityHashCode(this)}] _resolveVideoThumbnailBytes '
        'localPreviewPath=${msg.localPreviewPath} exists=$exists',
      );
      if (exists) {
        final bytes = await previewFile.readAsBytes();
        _videoThumbCache[msg.mediaId!] = bytes;
        debugPrint(
          'ChatScreen[${identityHashCode(this)}] _resolveVideoThumbnailBytes '
          'RETURN from localPreviewPath, bytes=${bytes.length}',
        );
        return bytes;
      }
    }

    final file = await _ensureMediaFile(
      msg,
      userInitiated: userInitiated,
      onProgress: onProgress,
    );
    final thumbBytes = await generateVideoThumbnail(file.path);
    if (thumbBytes == null) {
      throw Exception('Не удалось сгенерировать превью видео');
    }
    _videoThumbCache[msg.mediaId!] = thumbBytes;
    return thumbBytes;
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

  /// Время+статус — снова "умная" вставка в конец последней строки текста
  /// (см. _buildLinkifiedText: trailingMeta там становится завершающим
  /// WidgetSpan), как когда-то и было ДО единого поведения для всех типов
  /// сообщений. Вернули по прямому ТЗ пользователя — у коротких текстовых
  /// сообщений, где текст не дотягивает до правого края пузыря, время и
  /// галочки отдельной строкой снизу оставляли целую пустую строку
  /// пустого места (текст не занимает всю ширину сверху, время не
  /// занимает всю ширину снизу — оба зазора складываются в одну лишнюю
  /// строку). WidgetSpan в конце абзаца сам решает: есть место на
  /// последней строке текста — встаёт туда; нет — переносится на новую
  /// строку целиком, как единое целое, ровно то же поведение, что и в
  /// Телеграме/WhatsApp. Голосовые/видео/фото НЕ трогаем — там своя
  /// раскладка (_buildMetaRow отдельной строкой под медиа), это
  /// сознательно другой случай: там нет "текста", в который можно было бы
  /// вписать метаданные.
  Widget _buildTextWithMeta(StoredMessage msg, double maxTextWidth) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxTextWidth),
      child: _buildLinkifiedText(
        msg.text,
        _bubbleTextColor(msg.isMine),
        isMine: msg.isMine,
        trailingMeta: _buildMetaRow(msg),
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
  ///
  /// trailingMeta (см. _buildTextWithMeta) — необязательный виджет
  /// (время+галочки), который завершающим WidgetSpan встраивается прямо в
  /// конец текста: если на последней строке есть место — окажется там же,
  /// иначе перенесётся на новую строку целиком, как единое целое (тот же
  /// приём, что у Телеграма/WhatsApp). caption в _buildGroupBubble этот
  /// параметр не передаёт — там время+статус относятся ко всей группе
  /// целиком, а не к одной подписи, и остаются отдельной строкой ниже.
  Widget _buildLinkifiedText(
    String text,
    Color baseColor, {
    required bool isMine,
    double fontSize = 16,
    Widget? trailingMeta,
  }) {
    final matches = _urlRegex.allMatches(text).toList();
    if (matches.isEmpty && trailingMeta == null) {
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
    if (trailingMeta != null) {
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(left: 6, top: 2),
            child: trailingMeta,
          ),
        ),
      );
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
    String messageId,
    String? myReaction,
    String? peerReaction,
    bool isMine,
  ) {
    // ВАЖНО: раньше тут было "if (myReaction == null && peerReaction ==
    // null) return SizedBox.shrink()" — короткий путь для самого частого
    // случая "реакций тут вообще нет". Но из-за этого при ПЕРВОЙ на
    // сообщение реакции виджет в этом месте дерева менял ТИП (SizedBox →
    // Positioned) — Flutter не может обновить widget другого типа на
    // месте, только пересоздать заново, а значит для самого частого
    // сценария ("реакции тут не было, только что поставили") ни
    // AnimatedSwitcher внутри _ReactionChip (у него встроенное правило —
    // самый первый child при монтировании НЕ анимируется), ни
    // didUpdateWidget там же попросту не успевали сработать: виджет
    // монтировался уже готовым, без единого кадра перехода. Теперь чипы
    // существуют всегда (просто пустые — SizedBox.shrink ВНУТРИ
    // _ReactionChip, а не вместо него), поэтому именно ЭТОТ, самый частый
    // случай тоже проигрывает анимацию, а не только смена уже существующей
    // реакции на другую.
    final justChanged = _justReactedMessageIds.contains(messageId);
    return Positioned(
      bottom: -8,
      left: isMine ? 8 : null,
      right: isMine ? null : 8,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ReactionChip(
            emoji: myReaction,
            mine: true,
            justChanged: justChanged,
          ),
          if (myReaction != null && peerReaction != null)
            const SizedBox(width: 4),
          _ReactionChip(
            emoji: peerReaction,
            mine: false,
            justChanged: justChanged,
          ),
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
              _reactionBadges(
                targetMsg.messageId,
                myReaction,
                peerReaction,
                isMine,
              ),
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

    // Свайп-реплай — см. _swipeReplyTargetId/_swipeReplyDx у State. Не
    // мешает тапу/долгому тапу/скроллу списка: GestureDetector сам
    // разруливает конкурирующие распознаватели (тап требует отсутствия
    // движения, вертикальный скролл списка — вертикального движения,
    // этот — горизонтального), это штатная композиция для Flutter.
    // Недоступен в режиме выбора и когда переписка заблокирована (реплай
    // всё равно нечем отправить).
    //
    // Направление свайпа решается ОДИН раз в начале жеста (см. поля
    // _swipeIsBackNavigation/_swipeCumulativeDx у State) и не меняется до
    // конца: влево — реплай, вправо — свайп-назад, доигрываемый вручную
    // теми же публичными методами SwipeBackPageRoute, которыми обычно
    // управляет SwipeBackDetector (см. swipe_back_page_route.dart). Это
    // нужно, потому что строка сообщения — более глубоко вложенный
    // GestureDetector, чем SwipeBackDetector, и всегда выигрывает у него
    // арену жестов, если жест стартует прямо на сообщении — без этой
    // доигровки свайп-назад внутри чата вообще переставал работать.
    void handleSwipeStart(DragStartDetails details) {
      _swipeTargetId = targetMsg.messageId;
      _swipeCumulativeDx = 0;
      _swipeIsBackNavigation = null;
      _swipeBackRoute = null;
      _swipeReplyFired = false;
    }

    void handleSwipeUpdate(DragUpdateDetails details) {
      if (_swipeTargetId != targetMsg.messageId) return;
      _swipeCumulativeDx += details.delta.dx;

      if (_swipeIsBackNavigation == null) {
        if (_swipeCumulativeDx.abs() < 4) return;
        _swipeIsBackNavigation = _swipeCumulativeDx > 0;
      }

      if (_swipeIsBackNavigation!) {
        final backSwipeEnabled = !_emojiMode && !_selectionMode && !_searchMode;
        if (!backSwipeEnabled) return;
        var route = _swipeBackRoute;
        if (route == null) {
          final modalRoute = ModalRoute.of(context);
          final navigator = Navigator.of(context);
          if (modalRoute is SwipeBackPageRoute && navigator.canPop()) {
            route = modalRoute;
            _swipeBackRoute = route;
            route.handleDragStart();
          } else {
            return;
          }
        }
        final width = MediaQuery.of(context).size.width;
        if (width <= 0) return;
        route.handleDragUpdate(details.delta.dx / width);
        return;
      }

      if (_selectionMode || _composerBlocked) return;
      final width = MediaQuery.of(context).size.width;
      final maxOffset = -width * 0.10;
      final next = _swipeCumulativeDx.clamp(maxOffset, 0.0);
      if (_swipeReplyTargetId != targetMsg.messageId || next != _swipeReplyDx) {
        setState(() {
          _swipeReplyTargetId = targetMsg.messageId;
          _swipeReplyDx = next;
        });
      }
      // Порог и визуальный максимум — одно и то же значение (см. ТЗ
      // пользователя): сообщение просто не может сдвинуться ДАЛЬШЕ точки,
      // в которой уже сработал реплай.
      if (!_swipeReplyFired && _swipeReplyDx <= maxOffset) {
        _swipeReplyFired = true;
        HapticFeedback.vibrate();
        _setReplyTarget(targetMsg);
      }
    }

    void handleSwipeEnd(DragEndDetails details) {
      if (_swipeTargetId != targetMsg.messageId) return;
      final route = _swipeBackRoute;
      _swipeBackRoute = null;
      _swipeTargetId = null;
      final wasBackNav = _swipeIsBackNavigation;
      _swipeIsBackNavigation = null;
      if (_swipeReplyTargetId == targetMsg.messageId) {
        setState(() {
          _swipeReplyDx = 0;
          _swipeReplyTargetId = null;
        });
      }
      if (route != null) {
        final width = MediaQuery.of(context).size.width;
        final velocityFraction = width > 0
            ? details.velocity.pixelsPerSecond.dx / width
            : 0.0;
        route.handleDragEnd(velocityFraction);
        return;
      }
      // Свайп-назад был заблокирован (режим выбора/поиска/эмодзи), но
      // достаточно длинный — тот же "мягкий" выход, что и у обычного
      // SwipeBackDetector (см. onBlockedSwipe в build()).
      if (wasBackNav == true && _swipeCumulativeDx > 80) {
        _handleBackAction(emojiOnlyVisible: _emojiMode);
      }
    }

    void handleSwipeCancel() {
      if (_swipeTargetId != targetMsg.messageId) return;
      final route = _swipeBackRoute;
      _swipeBackRoute = null;
      _swipeTargetId = null;
      _swipeIsBackNavigation = null;
      if (_swipeReplyTargetId == targetMsg.messageId) {
        setState(() {
          _swipeReplyDx = 0;
          _swipeReplyTargetId = null;
        });
      }
      route?.handleDragEnd(0);
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

    // Визуальный сдвиг во время свайп-реплая — только у ТОЙ строки, где он
    // сейчас реально идёт (см. handleSwipeReplyUpdate); у всех остальных —
    // 0, никакого лишнего Transform не появляется. И свои, и чужие
    // сообщения одинаково двигаются влево (навстречу направлению свайпа).
    final isSwipingThis = _swipeReplyTargetId == targetMsg.messageId;
    final swipedContent = Transform.translate(
      offset: Offset(isSwipingThis ? _swipeReplyDx : 0, 0),
      child: content,
    );

    final row = Row(
      // .center — не .end: галочка выбора должна стоять по вертикальному
      // центру сообщения, а не липнуть к его нижнему краю (у content
      // единственного child'а с реальной высотой это никак не смещает сам
      // пузырь, потому что высота строки и так равна его высоте).
      crossAxisAlignment: CrossAxisAlignment.center,
      children: isMine
          ? [filler, swipedContent, selectionSlot]
          : [selectionSlot, swipedContent, filler],
    );

    // Разовая подсветка на всю ширину строки после тапа по баннеру цитаты
    // ИЛИ по баннеру закрепа (см. _jumpToMessageWithFlash) — оборачивает
    // row ЦЕЛИКОМ (не только пузырь), поэтому фон заливки покрывает весь
    // экран по горизонтали, как просил пользователь. ValueKey на токене —
    // чтобы повторный тап по той же цели, пока предыдущая вспышка ещё не
    // погасла, пересоздавал виджет и честно перезапускал анимацию с нуля,
    // а не "ничего не происходило".
    final rowWithFlash = _jumpFlashMessageId == targetMsg.messageId
        ? _JumpFlash(key: ValueKey('jump_flash_$_jumpFlashToken'), child: row)
        : row;

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
        onHorizontalDragStart: handleSwipeStart,
        onHorizontalDragUpdate: handleSwipeUpdate,
        onHorizontalDragEnd: handleSwipeEnd,
        onHorizontalDragCancel: handleSwipeCancel,
        child: rowWithFlash,
      ),
    );
  }

  /// Ищет сообщение (в т.ч. ПРОЦИТИРОВАННОЕ, не текущее) по id среди уже
  /// загруженной истории чата (грузится вся целиком, см. _loadHistory —
  /// не постранично, так что "не нашли" здесь однозначно значит "удалено",
  /// а не "ещё не подгружено"). null — сообщения больше нет.
  StoredMessage? _findMessageById(String? messageId) {
    if (messageId == null) return null;
    for (final m in _messages) {
      if (m.messageId == messageId) return m;
    }
    return null;
  }

  /// Баннер реплая внутри пузыря — 1 в 1 стиль Telegram (ТЗ пользователя,
  /// сравнивал скриншот-к-скриншоту с одинаковым тестовым текстом): это
  /// отдельная СКРУГЛЁННАЯ КАРТОЧКА СО СВОИМ ФОНОМ, заметно отличающимся
  /// от фона самого пузыря — раньше здесь был только левый бордюр без
  /// заливки, и цитата визуально сливалась с пузырём (жалоба "хрень",
  /// сравнение один-в-один со скриншотом Telegram). Полупрозрачный чёрный
  /// поверх фона пузыря — работает одинаково что на синем своём пузыре,
  /// что на тёмном чужом, без отдельных веток на isMine. Полоска и текст
  /// всегда слева (Telegram не зеркалит их на своих сообщениях). Сверху —
  /// имя отправителя процитированного сообщения ("Вы" для собственного)
  /// акцентным цветом, снизу — сама цитата приглушённым.
  /// [maxWidth] — ОБЯЗАТЕЛЬНО та же ширина, что и у текста сообщения под
  /// этой цитатой (см. вызов ниже — тот же maxTextWidth, что уходит в
  /// _buildTextWithMeta): без этого у баннера реплая не было верхнего
  /// предела по ширине вообще, и при длинной цитате он мог стать ШИРЕ
  /// самого пузыря сообщения — в Telegram цитата всегда вписана в ту же
  /// ширину, что и пузырь, а не растягивается отдельно от него.
  ///
  /// Тап по баннеру — ТЗ пользователя: анимационно перелетаем к
  /// процитированному сообщению и один раз подсвечиваем его на всю
  /// ширину экрана (см. _jumpToMessageWithFlash/_JumpFlash). Если
  /// оригинал не найден в истории (удалён) — вместо цитаты фиксированная
  /// надпись, тап ничего не делает (originalMsg остаётся null).
  Widget _buildReplyPreview(StoredMessage msg, double maxWidth) {
    if (msg.replyToPreview == null) return const SizedBox.shrink();
    final originalMsg = _findMessageById(msg.replyToMessageId);
    final senderLabel = originalMsg == null
        ? null
        : (originalMsg.isMine
              ? tr('chat.replyYou')
              : (_peerDisplayName ?? widget.peerLogin));
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: originalMsg == null
            ? null
            : () => _jumpToMessageWithFlash(originalMsg.messageId),
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(6),
            border: Border(
              left: BorderSide(color: _bubbleMutedColor(msg.isMine), width: 3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (senderLabel != null)
                Text(
                  senderLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFFFC04D),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              Text(
                originalMsg == null
                    ? tr('chat.replyDeleted')
                    : msg.replyToPreview!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _bubbleMutedColor(msg.isMine),
                  fontSize: 12,
                  fontStyle: originalMsg == null
                      ? FontStyle.italic
                      : FontStyle.normal,
                ),
              ),
            ],
          ),
        ),
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
    final uploadPhase = msg.processingStep != null
        ? _uploadPhaseFor(msg)
        : null;
    return Column(
      crossAxisAlignment: msg.isMine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        VideoNotePlayer(
          resolveFile: ({onProgress}) =>
              _resolveRecordedMediaFile(msg, onProgress: onProgress),
          isCached: () => MediaCache.exists(msg.mediaId!),
          resolveThumbnail: ({onProgress}) =>
              _resolveVideoThumbnailBytes(msg, onProgress: onProgress),
          localPreviewPath: msg.localPreviewPath,
          durationMs: msg.durationMs,
          expandedSize: expandedSize,
          processingStep: uploadPhase?.text,
          uploadPercent: uploadPhase?.percent,
          coordinator: _mediaCoordinator,
          messageId: msg.messageId,
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

    final content = IntrinsicWidth(
      // IntrinsicWidth — БЕЗ него .stretch ниже раздувал пузырь на всю
      // доступную (рыхлую/неограниченную) ширину строки списка сообщений
      // целиком, а не на ширину контента (жалоба пользователя "стало ещё
      // хуже" — раздувался вообще любой пузырь, даже без реплая).
      // IntrinsicWidth сперва считает "естественную" ширину по самому
      // широкому ребёнку колонки ниже, и уже ВНУТРИ этой (обычной,
      // содержимым определённой) ширины работает .stretch — тогда пузырь
      // по-прежнему схлопывается по контенту, а баннер цитаты и текст
      // сообщения просто делят одну и ту же (естественную) ширину между
      // собой.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildReplyPreview(msg, maxTextWidth),
          msg.isVoice
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    VoiceMessagePlayer(
                      isMine: msg.isMine,
                      durationMs: msg.durationMs,
                      processingStep: _processingStepDisplay(msg),
                      resolveFile: ({onProgress}) => _resolveRecordedMediaFile(
                        msg,
                        onProgress: onProgress,
                      ),
                      isCached: () => MediaCache.exists(msg.mediaId!),
                      coordinator: _mediaCoordinator,
                      messageId: msg.messageId,
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
      ),
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

  // Android гасит системную клавиатуру сам при уходе приложения в фон, но
  // НЕ трогает наш _textFocusNode — Flutter-level фокус остаётся висеть
  // "включённым", хотя реальной клавиатуры уже нет. На части устройств
  // после возврата в приложение первый же кадр(-ы) при этом ещё отдают
  // старое (докадровое) значение viewInsets.bottom, из-за системной
  // resize-анимации самого перехода — из-за этого `reserved` в build()
  // на миг-другой продолжает резервировать место под клавиатуру, которой
  // уже нет (пустой зазор), а после ухода с этого экрана то же самое
  // "залипшее" значение отступа успевает просочиться в соседний экран
  // (список чатов), где резервируемое место не привязано к фокусу вообще
  // и потому не сбрасывается само. Снимая фокус ЗАРАНЕЕ, в момент ухода в
  // фон (а не постфактум, после возврата), просим у Flutter официально
  // закрыть клавиатуру ЕГО собственным путём — тогда его внутренний учёт
  // инсетов не расходится с реальностью, и `reserved`/`hasFocus` уже к
  // моменту возврата в приложение корректно равны нулю.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // ВАЖНО: реагируем только на paused, не на inactive. inactive
    // наступает не только при реальном уходе в фон, но и при ЛЮБОМ
    // системном оверлее поверх ещё видимого приложения — например, при
    // долгом нажатии на пробел на клавиатуре всплывает системное окошко
    // "сменить клавиатуру ввода", и Android на это время тоже переводит
    // приложение в inactive (ТЗ пользователя: окошко появлялось на долю
    // секунды и сразу пропадало вместе с клавиатурой). Снимая фокус уже
    // здесь, мы просили Flutter закрыть клавиатуру — а вместе с ней
    // закрывалось и системное окошко, которое от неё зависит. Настоящий
    // уход в фон всё равно проходит через inactive → paused по цепочке,
    // так что реагировать только на paused по-прежнему ловит его вовремя.
    if (state == AppLifecycleState.paused) {
      if (_textFocusNode.hasFocus) {
        _textFocusNode.unfocus();
      }
      return;
    }
    // Подстраховка на случай, если поле всё же ушло в фон уже без фокуса
    // (например, фокус сняли ДО сворачивания каким-то другим путём), а
    // системная клавиатура при этом оставалась открытой — явно просим ОС
    // скрыть её при возврате, не дожидаясь, пока viewInsets сам когда-
    // нибудь досчитается до правильного значения.
    if (state == AppLifecycleState.resumed && !_textFocusNode.hasFocus) {
      unawaited(SystemChannels.textInput.invokeMethod('TextInput.hide'));
    }
  }

  @override
  void dispose() {
    debugPrint(
      'ChatScreen[${identityHashCode(this)}] dispose peerLogin=${widget.peerLogin}',
    );
    WidgetsBinding.instance.removeObserver(this);
    _mediaCoordinator.dispose();
    _pendingTapTimer?.cancel();
    _scrollSaveDebounce?.cancel();
    _keyboardCloseDebounceTimer?.cancel();
    _keyboardHeightSettleTimer?.cancel();
    KeyboardInsets.heightPx.removeListener(_onKeyboardInsetsChanged);
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
    _incomingReactionSub?.cancel();
    _incomingDeleteSub?.cancel();
    _uploadProgressSub?.cancel();
    _peerProfileSub?.cancel();
    _dlProgressSub?.cancel();
    _dlDoneSub?.cancel();
    _dlFailedSub?.cancel();
    _visibleFlushTimer?.cancel();
    for (final timer in _justReactedTimers.values) {
      timer.cancel();
    }
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
                      if (value == 'reset_session') {
                        unawaited(_confirmAndResetSession());
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'search',
                        child: Row(
                          children: [
                            Icon(Icons.search, color: AppColors.textMuted),
                            const SizedBox(width: 10),
                            Text(
                              tr('chat.searchAction'),
                              style: TextStyle(color: AppColors.textPrimary),
                            ),
                          ],
                        ),
                      ),
                      if (!_isNotes)
                        PopupMenuItem(
                          value: 'reset_session',
                          child: Row(
                            children: [
                              Icon(
                                Icons.lock_reset,
                                color: AppColors.textMuted,
                              ),
                              const SizedBox(width: 10),
                              Text(
                                tr('chat.resetSessionAction'),
                                style: TextStyle(color: AppColors.textPrimary),
                              ),
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
                  // filled:false — глобальная тема (см. app_theme.dart)
                  // по умолчанию заливает ЛЮБОЕ текстовое поле сплошным
                  // AppColors.surface (это нужно для форм логина/
                  // регистрации), без явного отключения тут это давало
                  // непрозрачный прямоугольник ровно по границам текстового
                  // поля ПОВЕРХ блюра овальной таблетки — заметно на
                  // контрастном фоне (сообщении) позади, почти незаметно на
                  // однородном фоне чата (см. жалобу пользователя).
                  filled: false,
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
  Future<void> _loadPeerDisplayName() async {
    final profile = await PeerProfileCache.get(
      widget.peerAccountId,
      widget.peerLogin,
    );
    if (!mounted || profile == null) return;
    if (profile.displayName != _peerDisplayName) {
      setState(() => _peerDisplayName = profile.displayName);
    }
  }

  Widget _buildAppBarTitle() {
    final title = Text(
      _isNotes
          ? tr('home.notes')
          : (_isPeerDeleted
                ? tr('home.deletedAccount')
                : (_peerDisplayName ?? widget.peerLogin)),
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
      // ТЗ пользователя: тап по баннеру закрепа должен так же анимационно
      // перелетать к сообщению и один раз подсветить его на всю ширину,
      // как уже сделано для тапа по баннеру цитаты (см.
      // _jumpToMessageWithFlash/_JumpFlash) — тот же самый механизм,
      // никакого отдельного не заводим.
      onTap: () => _jumpToMessageWithFlash(pinnedId),
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
    // Была высокая (vertical: 8 паддинга + дефолтный тап-квадрат IconButton)
    // — по ТЗ пользователя сделал заметно компактнее: меньше паддинг,
    // фиксированная невысокая строка, у крестика visualDensity.compact
    // (constraints/padding у него и так уже были обнулены, но сам
    // IconButton по умолчанию всё равно резервирует место под стандартный
    // 48×48 тач-таргет темы — compact снимает именно это).
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SizedBox(
        height: 26,
        child: Row(
          children: [
            Icon(icon, size: 15, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppColors.textPrimary, fontSize: 12.5),
              ),
            ),
            IconButton(
              icon: Icon(Icons.close, size: 16, color: AppColors.textMuted),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }

  /// Панель управления голосовым/видео-сообщением — см. ТЗ пользователя:
  /// появляется ПОД обычной шапкой чата (не должна перекрывать кнопку
  /// "назад", логин/статус/фото собеседника и кнопку звонка), пока играет
  /// (или на паузе) одно из голосовых/видео-сообщений; play/pause слева
  /// переключает состояние
  /// БЕЗ схлопывания панели, крестик справа — полная остановка со
  /// схлопыванием (и панели, и самого видео-кружка обратно до compactSize
  /// — см. MediaPlaybackCoordinator.close()).
  ///
  /// AnimatedAlign(heightFactor)+ClipRect вместо AnimatedSize — раньше
  /// содержимое (иконки/текст) собиралось только при active==true через
  /// тернарник, и при active==false целиком выкидывалось из дерева на
  /// первом же кадре, ДО того как AnimatedSize вообще успевал доиграть
  /// схлопывание высоты — в результате контент пропадал рывком, а потом
  /// уже пустая коробка почти незаметно доезжала до нуля (жалоба
  /// пользователя: "появляется анимационно, а исчезает — нет"). Теперь
  /// содержимое собирается ВСЕГДА одним и тем же виджетом, а
  /// heightFactor только визуально обрезает (ClipRect) уже готовый,
  /// никуда не девающийся контент — ровно тот же приём, что и у появления,
  /// просто в обратную сторону, поэтому оба направления выглядят
  /// одинаково плавными.
  Widget _buildMediaControlBar() {
    return AnimatedBuilder(
      animation: _mediaCoordinator,
      builder: (context, _) {
        final active = _mediaCoordinator.activeMessageId != null;
        return ClipRect(
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            heightFactor: active ? 1.0 : 0.0,
            child: SafeArea(
              // top тоже false — панель теперь стоит ПОД шапкой чата
              // (см. ТЗ пользователя), а не у самого верха экрана, шапка
              // уже сама учла отступ под статус-бар — второй раз его
              // резервировать не нужно, иначе между шапкой и панелью
              // появился бы лишний зазор высотой со статус-бар.
              top: false,
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          _mediaCoordinator.isPlaying
                              ? Icons.pause
                              : Icons.play_arrow,
                          color: AppColors.primary,
                        ),
                        onPressed: _mediaCoordinator.togglePlayPause,
                      ),
                      Expanded(
                        child: Text(
                          tr('chat.mediaBarPlaying'),
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 13,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.close, color: AppColors.textMuted),
                        onPressed: _mediaCoordinator.close,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
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

  // См. lib/services/keyboard_insets.dart — MediaQuery.viewInsets.bottom
  // ненадёжен конкретно в сценарии edge-to-edge + системный back-жест
  // (подтверждённый баг движка Flutter, не наш собственный). Пока нативный
  // канал ещё не отчитался ни разу (isActive==false — платформа без
  // реализации, например iOS, либо канал ещё не успел подписаться) —
  // честно откатываемся на обычный MediaQuery, как было всегда.
  double _liveKeyboardInsetPx(BuildContext context) =>
      KeyboardInsets.resolveInsetPx(context);

  Widget _build(BuildContext context) {
    final realInset = _liveKeyboardInsetPx(context);
    final rawKeyboardVisible = realInset > 50;
    // Открытие — сразу; закрытие — только если провал держится дольше
    // _keyboardCloseDebounceDelay (см. поле выше про "Change keyboard").
    if (rawKeyboardVisible) {
      _keyboardCloseDebounceTimer?.cancel();
      _keyboardCloseDebounceTimer = null;
      _keyboardVisibleDebounced = true;
    } else if (_keyboardVisibleDebounced &&
        _keyboardCloseDebounceTimer == null) {
      _keyboardCloseDebounceTimer = Timer(_keyboardCloseDebounceDelay, () {
        if (!mounted) return;
        _keyboardCloseDebounceTimer = null;
        final stillClosed = _liveKeyboardInsetPx(context) <= 50;
        DebugLog.log(
          'Chat _keyboardCloseDebounceTimer fired stillClosed=$stillClosed '
          'emojiMode=$_emojiMode awaitingKeyboardOpen=$_awaitingKeyboardOpen',
        );
        if (stillClosed) {
          setState(() => _keyboardVisibleDebounced = false);
        }
      });
    }
    final keyboardVisible = _keyboardVisibleDebounced;
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
        final settled = _liveKeyboardInsetPx(context);
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
    // _awaitingKeyboardOpen — see handler below: держит резерв места,
    // пока настоящая клавиатура не ДОГОНИТ его сама (realInset >=
    // _keyboardHeight), а не просто "стала видна" (realInset > 50) — см.
    // подробное обоснование у emojiReserved ниже: формула там устроена
    // так, что снимать флаг раньше, чем realInset реально долез до
    // _keyboardHeight, означало бы читать emojiReserved как 0 ДО того, как
    // сама клавиатура успела дозанять оставшееся место — та же "прыгающая"
    // панель, только в обратную сторону.
    if (_awaitingKeyboardOpen && realInset >= _keyboardHeight) {
      _awaitingKeyboardOpen = false;
    }
    // ТЗ пользователя — "клавиатура как лифт": всё, что находится над ней
    // (список сообщений И панель ввода), должно двигаться ОДНИМ жёстким
    // блоком, а не отдельно анимируемой панелью, которая "досгоняет".
    // Раньше это пытались воспроизвести вручную (свой Container, живое
    // отслеживание realInset) — и всё равно оставалось ощущение погони за
    // клавиатурой, потому что ручное отслеживание в принципе не может быть
    // точно тем же самым кадром, что и сама системная анимация клавиатуры.
    // Настоящее решение — штатный resizeToAvoidBottomInset (см. Scaffold
    // ниже): Flutter сам физически сжимает ВСЁ тело экрана вместе с
    // клавиатурой за один проход layout'а, и наша панель ввода (Positioned
    // bottom: 0, см. ниже) сама, естественно, следует за нижним краем уже
    // сжавшегося тела — без какой-либо СВОЕЙ анимации/Container поверх.
    //
    // Наш собственный резерв места (emojiReserved) остаётся только для
    // эмодзи-панели — это наш собственный UI, не системный оверлей,
    // никакого сигнала от ОС для него нет и не может быть.
    //
    // "_keyboardHeight - realInset" (а не просто _keyboardHeight) — ТЗ
    // пользователя: переключение клавиатура<->эмодзи (в обе стороны) не
    // должно двигать панель ввода ВООБЩЕ, а не просто "быстро" или "без
    // рывков" — обе панели занимают ОДНО и то же место, значит сумма
    // "сколько тело экрана уже сжато настоящей клавиатурой" (realInset,
    // двигает Scaffold.resizeToAvoidBottomInset САМ) и "сколько сверху
    // добавляет наш резерв" (emojiReserved) обязана быть равна
    // _keyboardHeight В КАЖДЫЙ момент перехода, а не только в его начале
    // и конце. Раньше emojiReserved прыгал на всю _keyboardHeight СРАЗУ
    // (в тот же кадр, что setState), а realInset ещё несколько кадров
    // донашивал свою настоящую (системную, ~250мс) анимацию — на это время
    // сумма превышала _keyboardHeight (при закрытии клавиатуры) или была
    // меньше него (при открытии), и панель ввода заметно дёргалась —
    // реальная жалоба пользователя. clamp(0, _keyboardHeight) — только
    // подстраховка от отрицательных/завышенных значений на стыке, когда
    // realInset на долю кадра обгоняет _keyboardHeight (см. её же
    // settle-логику выше).
    final emojiReserved = (_emojiMode || _awaitingKeyboardOpen)
        ? (_keyboardHeight - realInset).clamp(0.0, _keyboardHeight)
        : 0.0;
    // Диагностика "пустая панель эмодзи на миг видна при закрытии
    // клавиатуры" — тут все значения, от которых зависит, покажется ли
    // на экране пустой (Offstage-содержимым) прямоугольник ненулевой
    // высоты (см. Container(height: emojiReserved, ...) ниже). Логируем
    // только при изменении состояния (round — чтобы не плодить строку на
    // каждый дробный кадр анимации realInset), иначе build() (кадр в
    // кадр во время анимации клавиатуры) забьёт лог за секунды.
    final emojiKeyboardState =
        'keyboardVisible=$keyboardVisible emojiMode=$_emojiMode '
        'awaitingKeyboardOpen=$_awaitingKeyboardOpen '
        'realInset=${realInset.round()} '
        'emojiReserved=${emojiReserved.round()}';
    if (_lastLoggedEmojiKeyboardState != emojiKeyboardState) {
      _lastLoggedEmojiKeyboardState = emojiKeyboardState;
      DebugLog.log('Chat emoji/keyboard state: $emojiKeyboardState');
    }
    // restGap — зазор до низа экрана в состоянии покоя (клавиатура и
    // эмодзи-панель обе закрыты). gapHeight — то же самое, но выведенное
    // ПЛАВНОЙ функцией живого realInset, а не отдельной анимацией ПОСЛЕ
    // того, как клавиатура/эмодзи-панель уже стали неактивны. Раньше зазор
    // был либо 0, либо restGap (по дискретному условию realInset > 0 ||
    // emojiReserved > 0), и переключался отдельным 220мс
    // AnimatedContainer'ом ровно в момент, когда realInset УЖЕ достигал
    // нуля (клавиатура физически уже полностью закрылась, тело экрана уже
    // полностью развернулось обратно, панель ввода уже физически стояла
    // впритык к самому низу) — и только ПОТОМ, вдогонку, панель
    // поднималась на restGap отдельным движением. Жалоба пользователя:
    // "панель сообщения доходит до самого низа экрана... а затем
    // чуть-чуть поднимается вверх, перекрывая тот самый отступ" — то есть
    // ей не нужно было опускаться до конца, чтобы потом подниматься
    // обратно. Формула ниже: пока realInset ещё не меньше restGap, зазор
    // не нужен (0, как раньше) — а когда клавиатура в САМОМ ХВОСТЕ своей
    // закрывающей анимации становится тоньше restGap, зазор линейно
    // "дозаполняет" ровно то же расстояние, что клавиатура успела
    // освободить, — в ТОМ ЖЕ кадре и от ТОЙ ЖЕ переменной realInset, что и
    // сама системная анимация, поэтому панель просто перестаёт опускаться
    // ниже своей итоговой точки покоя вместо того, чтобы её потом
    // отыгрывать назад. Для эмодзи-панели (не системная, ей нечего
    // синхронизировать с realInset) сохраняем прежнее мгновенное
    // поведение — она никогда не показывается одновременно с настоящей
    // клавиатурой, скачка между ними не бывает.
    final restGap = 5 + systemBottomInset;
    final gapHeight = (_emojiMode || _awaitingKeyboardOpen)
        ? 0.0
        : (restGap - realInset).clamp(0.0, restGap);

    // Список сообщений теперь ужимается по высоте АВТОМАТИЧЕСКИ вместе с
    // телом экрана (см. Scaffold.resizeToAvoidBottomInset выше) — ScrollView
    // сам остаётся "приклеенным" к своему текущему смещению, а не к низу,
    // так что если пользователь и так был внизу чата, после того как
    // viewport стал короче, нужно один раз прокрутить обратно к настоящему
    // концу, иначе последние сообщения окажутся чуть выше видимой области.
    final scrollTriggerReserved = realInset + emojiReserved;
    if (_initialLoadComplete &&
        scrollTriggerReserved > _lastReserved + 4 &&
        _userAtBottom) {
      _autoScrollingForResize = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _scrollToBottom();
        _autoScrollingForResize = false;
      });
    }
    _lastReserved = scrollTriggerReserved;

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
          // false (было true) — см. lib/services/keyboard_insets.dart.
          // Штатный resizeToAvoidBottomInset физически сжимает body следом
          // за MediaQuery.viewInsets.bottom — ровно тем же значением,
          // которое в сценарии edge-to-edge + системный back-жест
          // подтверждённо ненадёжно (баг движка Flutter, см. комментарий у
          // _liveKeyboardInsetPx). Раз мы больше не доверяем этому
          // значению для realInset ниже, доверять ему для сжатия ВСЕГО
          // тела экрана — та же самая дыра, просто в другом месте: список
          // и панель ввода снова разъехались бы, только теперь потому что
          // тело сжалось по одному (буферному) значению, а панель
          // позиционируется по другому (нативному). Вместо этого сжимаем
          // body сами, вручную, ниже — ОДНИМ И ТЕМ ЖЕ realInset, что и всё
          // остальное на этом экране.
          resizeToAvoidBottomInset: false,
          // Шапки больше нет как Scaffold.appBar — весь заголовок стал
          // плавающим оверлеем ПОВЕРХ списка сообщений (см. Positioned в
          // body ниже), тем же способом и по тем же причинам, что и панель
          // ввода снизу (см. ТЗ пользователя про единый стиль: только сами
          // "таблетки" непрозрачны, всё остальное — просвечивает чат).
          appBar: null,
          body: Padding(
            padding: EdgeInsets.only(bottom: realInset),
            child: Stack(
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
                                    16 +
                                        MediaQuery.of(context).padding.top +
                                        60,
                                    16,
                                    // 64 — высота самой таблетки, но последнее
                                    // сообщение вплотную к ней смотрелось так,
                                    // будто панель его слегка перекрывает (см.
                                    // жалобу пользователя) — 28, а не 16,
                                    // добавляют настоящий видимый зазор.
                                    //
                                    // "+ gapHeight" (а не вычитание фиксированной
                                    // константы, как было раньше) — реальный
                                    // баг с устройства: на 3-кнопочной системной
                                    // навигации (в отличие от жестовой)
                                    // systemBottomInset заметно больше (48 vs
                                    // 24), поэтому и сам зазор-спейсер (см.
                                    // gapHeight/restGap выше) вырастает почти
                                    // вдвое — а старая формула резервировала
                                    // под него ФИКСИРОВАННЫЕ 28, никак не
                                    // связанные с реальным systemBottomInset.
                                    // Итог — непрозрачная "таблетка" (её
                                    // верхний край стоит на gapHeight выше низа
                                    // экрана) физически перекрывала последнее
                                    // сообщение на устройствах с крупной
                                    // 3-кнопочной панелью (жалоба пользователя
                                    // со скриншотом). gapHeight — та же самая
                                    // плавная (не дискретная) величина, что и у
                                    // самого зазора-спейсера, так что паддинг
                                    // списка и высота спейсера всегда меняются
                                    // синхронно, кадр в кадр, и корректно растут
                                    // вместе с systemBottomInset вместо
                                    // константы. "12 +" — небольшой
                                    // фиксированный запас поверх реальной
                                    // высоты таблетки, чтобы последнее
                                    // сообщение не липло к ней вплотную даже
                                    // после этого исправления.
                                    //
                                    // "+ (_composerBannerVisible ? ... : 0)" —
                                    // баннер реплая/редактирования/пересылки
                                    // стоит НАД пилюлей, а не вместо неё (см.
                                    // _composerBannerHeight) — без этого
                                    // добавления резерв учитывал только саму
                                    // пилюлю, и баннер перекрывал последнее
                                    // сообщение (жалоба пользователя).
                                    //
                                    // "+ emojiReserved" — только эмодзи-панель:
                                    // саму настоящую клавиатуру ВТОРОЙ раз
                                    // сюда добавлять не нужно, тело экрана уже
                                    // физически короче на её высоту (см.
                                    // resizeToAvoidBottomInset у Scaffold) —
                                    // Expanded-список и так получает меньше
                                    // места безо всякого паддинга.
                                    12 +
                                        64 +
                                        emojiReserved +
                                        gapHeight +
                                        (_composerBannerVisible
                                            ? _composerBannerHeight
                                            : 0),
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
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedSwitcher(
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
                          return FadeTransition(
                            opacity: animation,
                            child: child,
                          );
                        },
                        child: _selectionMode
                            ? _buildSelectionHeader()
                            : _searchMode
                            ? _buildSearchHeader()
                            : _buildFloatingChatHeader(),
                      ),
                      // Панель управления голосовым/видео-сообщением — ПОД
                      // обычной шапкой чата (см. ТЗ пользователя: не должна
                      // перекрывать кнопку "назад", логин/статус/фото
                      // собеседника и кнопку звонка) — растёт/схлопывается
                      // здесь, шапка при этом остаётся на своём обычном месте.
                      _buildMediaControlBar(),
                    ],
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
                                  // Высота считается явно (см. _composerHeight)
                                  // и анимируется через AnimatedContainer — без
                                  // явного числа пилюля-контейнер просто
                                  // shrink-wrap'ился бы под текущий Row, а
                                  // строка "в покое"/записи/блокировки имели бы
                                  // РАЗНУЮ натуральную высоту и переключение
                                  // между ними давало бы мгновенный скачок без
                                  // анимации. AnimatedContainer нужен ИМЕННО
                                  // для роста/сжатия при печати многострочного
                                  // текста (см. ТЗ пользователя "Enter — перенос
                                  // строки") — переключение blocked/recording
                                  // само по себе всё так же держит одну и ту же
                                  // _composerBaseHeight, 3D-переворот
                                  // (_FlipSwitcher) для НИХ по-прежнему видит
                                  // константную высоту с обеих сторон.
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 140),
                                    curve: Curves.easeOut,
                                    height: _composerHeight,
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
                                                  overflow:
                                                      TextOverflow.ellipsis,
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
                                                            stateKey:
                                                                _emojiMode,
                                                            icon: Icon(
                                                              _emojiMode
                                                                  ? Icons
                                                                        .keyboard
                                                                  : Icons
                                                                        .emoji_emotions_outlined,
                                                              color: AppColors
                                                                  .textMuted,
                                                            ),
                                                          ),
                                                          onPressed: () {
                                                            DebugLog.log(
                                                              'Chat emoji-icon tap, emojiMode was $_emojiMode',
                                                            );
                                                            if (_emojiMode) {
                                                              // Настоящая клавиатура ещё не
                                                              // поднялась — держим reserved на
                                                              // месте (_awaitingKeyboardOpen, см.
                                                              // build()), пока realInset
                                                              // органически не догонит.
                                                              _awaitingKeyboardOpen =
                                                                  true;
                                                              setState(
                                                                () =>
                                                                    _emojiMode =
                                                                        false,
                                                              );
                                                              _textFocusNode
                                                                  .requestFocus();
                                                            } else {
                                                              _textFocusNode
                                                                  .unfocus();
                                                              setState(
                                                                () =>
                                                                    _emojiMode =
                                                                        true,
                                                              );
                                                            }
                                                          },
                                                        ),
                                                        const SizedBox(
                                                          width: 2,
                                                        ),
                                                        Expanded(
                                                          // Растущее поле —
                                                          // высота ВСЕЙ пилюли
                                                          // (см. AnimatedContainer
                                                          // вместо прежнего
                                                          // фиксированного
                                                          // SizedBox(height: 56)
                                                          // выше) теперь считается
                                                          // из _composerHeight и
                                                          // растёт вместе с
                                                          // количеством строк —
                                                          // без этого TextField
                                                          // с minLines/maxLines
                                                          // просто обрезался бы
                                                          // родительским фиксом
                                                          // высоты, как уже было
                                                          // с прошлым заходом
                                                          // (expands внутри
                                                          // фиксированного бокса
                                                          // на самом деле не мог
                                                          // расти и визуально
                                                          // ломался при переносе
                                                          // строки).
                                                          child: TextField(
                                                            controller:
                                                                _textController,
                                                            focusNode:
                                                                _textFocusNode,
                                                            textCapitalization:
                                                                TextCapitalization
                                                                    .sentences,
                                                            keyboardType:
                                                                TextInputType
                                                                    .multiline,
                                                            textInputAction:
                                                                TextInputAction
                                                                    .newline,
                                                            minLines: 1,
                                                            maxLines:
                                                                1 +
                                                                _composerMaxExtraLines,
                                                            textAlignVertical:
                                                                TextAlignVertical
                                                                    .center,
                                                            onTap: () {
                                                              if (_emojiMode) {
                                                                // Диагностика "пустая панель эмодзи" —
                                                                // ЭТА ветка, в отличие от кнопки-иконки
                                                                // выше, НЕ выставляет
                                                                // _awaitingKeyboardOpen: реальный фокус
                                                                // на поле придёт сам собой (тап уже
                                                                // произошёл по нему), но если он
                                                                // почему-то задержится — emojiReserved
                                                                // в build() успеет схлопнуться в 0 ещё
                                                                // до появления настоящей клавиатуры.
                                                                DebugLog.log(
                                                                  'Chat TextField onTap: emojiMode true->false '
                                                                  '(без _awaitingKeyboardOpen)',
                                                                );
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
                                                              border:
                                                                  InputBorder
                                                                      .none,
                                                              isDense: true,
                                                              contentPadding:
                                                                  const EdgeInsets.symmetric(
                                                                    vertical:
                                                                        10,
                                                                  ),
                                                              hintStyle: TextStyle(
                                                                color: AppColors
                                                                    .textMuted,
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          width: 2,
                                                        ),
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
                                                            key:
                                                                _attachButtonKey,
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
                      // Нужен только когда СНИЗУ больше ничего нет — см.
                      // gapHeight выше: плавно схлопывается в 0, пока клавиатура
                      // или эмодзи-панель занимают низ экрана. Обычный (не Animated)
                      // SizedBox — gapHeight уже сама плавная функция живого
                      // realInset, кадр в кадр с системной анимацией клавиатуры;
                      // отдельная анимация поверх нужна не была бы даже раньше,
                      // а теперь ещё и создавала бы ту самую рассинхронизацию
                      // (см. её разбор у объявления restGap/gapHeight выше).
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
                      SizedBox(height: gapHeight),
                      // Резерв места ТОЛЬКО под эмодзи-панель (см. emojiReserved
                      // выше) — настоящую клавиатуру больше не нужно ни
                      // отслеживать, ни резервировать здесь вообще: body уже
                      // физически сжался вместе с ней (resizeToAvoidBottomInset),
                      // и вся эта Positioned(bottom: 0) панель ввода сама
                      // естественно оказывается прямо над клавиатурой, без
                      // какого-либо отдельного Container/анимации поверх —
                      // именно та "жёсткая сцепка", которую попросил
                      // пользователь.
                      //
                      // Пока настоящая клавиатура поднята (keyboardVisible),
                      // держим FullEmojiPicker уже смонтированным, просто
                      // невидимым (Offstage) — он успевает построить свою
                      // разметку заранее, пока пользователь печатает, и тап
                      // по иконке эмодзи просто переключает видимость вместо
                      // того чтобы строить панель с нуля в этот момент
                      // (жалоба пользователя на заметную задержку первого
                      // показа). Не монтируем его вообще, когда клавиатуры
                      // тоже нет — незачем тратить на это первый кадр
                      // самого экрана чата.
                      // Обычный (не Animated) Container, пока в игре
                      // настоящая клавиатура (realInset>0 ИЛИ
                      // _awaitingKeyboardOpen — см. её объяснение выше) —
                      // emojiReserved в этом режиме уже сам по себе плавная,
                      // покадровая функция realInset, синхронная с системной
                      // анимацией клавиатуры один в один. Обернуть её ЕЩЁ и
                      // в AnimatedContainer означало бы заново наступить на
                      // грабли этой же сессии (см. gapHeight/restGap выше):
                      // AnimatedContainer сам плавно едет к КАЖДОМУ новому
                      // целевому значению отдельные 220мс, то есть гнался бы
                      // за уже плавной кривой — родная жалоба пользователя
                      // "панель сообщения куда-то прыгает при нажатии на
                      // эмодзи". А вот для перехода эмодзи-панель <-> состояние
                      // покоя (настоящая клавиатура вообще не участвует,
                      // realInset весь переход равен 0 — синхронизировать
                      // не с чем) собственная 220мс анимация — единственный
                      // способ показать это плавно, не рывком.
                      (_awaitingKeyboardOpen || realInset > 0)
                          ? Container(
                              height: emojiReserved,
                              color: AppColors.surface,
                              child: _buildEmojiPickerChild(keyboardVisible),
                            )
                          : AnimatedContainer(
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOut,
                              height: emojiReserved,
                              color: AppColors.surface,
                              child: _buildEmojiPickerChild(keyboardVisible),
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
/// смене эмодзи (см. AnimatedSwitcher внутри), а не появляется рывком, и при
/// НОВОЙ простановке (не при первой отрисовке уже существующей — см.
/// didUpdateWidget) обрастает коротким разлётом искр вокруг себя, как
/// "хлопок" в Telegram, а не просто всплывает молча. mine=true — своя
/// реакция (акцентная обводка), false — реакция собеседника (приглушённая).
class _ReactionChip extends StatefulWidget {
  final String? emoji;
  final bool mine;
  // true — этот чип получил свой эмодзи ПРЯМО СЕЙЧАС (см.
  // _justReactedMessageIds/_markJustReacted в _ChatScreenState), а не
  // просто первый раз строится с уже давно стоящей реакцией (открыли чат,
  // проскроллили историю). didUpdateWidget один этот случай не ловит —
  // самая частая ситуация "реакции тут вообще не было" меняет тип виджета
  // в дереве (SizedBox.shrink → Positioned/_ReactionChip, см.
  // _reactionBadges), так что для чипа это в любом случае ПЕРВОЕ
  // построение, initState, а не апдейт уже существующего.
  final bool justChanged;

  const _ReactionChip({
    required this.emoji,
    required this.mine,
    this.justChanged = false,
  });

  @override
  State<_ReactionChip> createState() => _ReactionChipState();
}

class _ReactionChipState extends State<_ReactionChip>
    with SingleTickerProviderStateMixin {
  // 650ms и заметный овершут — первая версия (2.2px искры в радиусе 14px,
  // почти незаметный easeOutBack) оказалась настолько субтильной, что
  // пользователь на реальном устройстве её попросту не замечал. Тут явная,
  // безошибочно видимая "поп"-анимация — крупные искры ДАЛЕКО от чипа и
  // сам чип ощутимо раздувается (до 1.55×) перед тем, как осесть на
  // место — не полагаемся на то, что AnimatedSwitcher САМ создаст
  // впечатление "хлопка".
  late final AnimationController _burstController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );

  static final Animatable<double> _popTween = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 1.0,
        end: 1.55,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 30,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.55,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.elasticOut)),
      weight: 70,
    ),
  ]);

  void _playPop() {
    if (mounted) _burstController.forward(from: 0);
  }

  @override
  void initState() {
    super.initState();
    if (widget.emoji != null && widget.justChanged) {
      // Не сразу в этом же кадре — на initState дерево ещё не факт что
      // полностью подготовлено (первый build ещё не случился), запуск в
      // addPostFrameCallback гарантированно ловит уже готовый, отрисованный
      // виджет.
      WidgetsBinding.instance.addPostFrameCallback((_) => _playPop());
    }
  }

  @override
  void didUpdateWidget(covariant _ReactionChip old) {
    super.didUpdateWidget(old);
    // Реальная простановка/смена (в т.ч. с null на что-то) — основной путь
    // теперь именно этот: _reactionBadges больше не подменяет тип виджета
    // на "нет реакций" (см. комментарий там), так что даже самая первая
    // реакция на сообщение — это ОБНОВЛЕНИЕ уже существующего чипа, а не
    // его пересоздание с нуля.
    if (widget.emoji != null && widget.emoji != old.emoji) {
      _playPop();
    }
  }

  @override
  void dispose() {
    _burstController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.mine ? AppColors.primary : AppColors.textMuted;
    return AnimatedBuilder(
      animation: _burstController,
      builder: (context, child) {
        final popScale = _popTween.evaluate(_burstController);
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Positioned(
              left: -26,
              right: -26,
              top: -26,
              bottom: -26,
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _ReactionBurstPainter(
                    progress: _burstController.value,
                    color: accent,
                  ),
                ),
              ),
            ),
            Transform.scale(scale: popScale, child: child),
          ],
        );
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        transitionBuilder: (child, anim) => ScaleTransition(
          scale: CurvedAnimation(parent: anim, curve: Curves.easeOutBack),
          child: FadeTransition(opacity: anim, child: child),
        ),
        child: widget.emoji == null
            ? const SizedBox.shrink(key: ValueKey('_empty'))
            : Container(
                key: ValueKey('${widget.mine}_${widget.emoji}'),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: accent, width: 1.4),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Text(
                  widget.emoji!,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
      ),
    );
  }
}

/// Кольцо искр, разлетающихся от центра чипа и гаснущих по пути — progress
/// 0 → только что появились, вплотную к центру; 1 → долетели до
/// максимального радиуса и полностью прозрачны. Крупные и далеко летящие
/// специально — версия с искрами 2px в радиусе 14px оказалась незаметна на
/// реальном устройстве (см. ТЗ пользователя).
class _ReactionBurstPainter extends CustomPainter {
  final double progress;
  final Color color;

  _ReactionBurstPainter({required this.progress, required this.color});

  static const _sparkCount = 10;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || progress >= 1) return;
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.shortestSide / 2;
    final eased = Curves.easeOut.transform(progress);
    final distance = eased * maxRadius;
    // Быстрая вспышка в первой трети, растянутое угасание — иначе искры
    // гаснут раньше, чем успевают долететь до заметного расстояния от чипа.
    final opacity = (1 - progress * progress).clamp(0.0, 1.0);
    final paint = Paint()..color = color.withValues(alpha: opacity);
    for (var i = 0; i < _sparkCount; i++) {
      final angle = (i / _sparkCount) * 2 * math.pi;
      final sparkCenter =
          center + Offset(math.cos(angle), math.sin(angle)) * distance;
      final radius = (1 - progress) * 4.5;
      canvas.drawCircle(sparkCenter, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ReactionBurstPainter old) =>
      old.progress != progress || old.color != color;
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

/// Разовая подсветка светло-голубым на всю ширину строки — вспыхивает
/// сразу на полную яркость и плавно гаснет сама, один раз (не пульсирует
/// бесконечно, в отличие от _PulsingHighlight ниже, который сделан для
/// другого случая — навигации по совпадениям поиска). См.
/// _jumpToMessageWithFlash — тап по баннеру цитаты ИЛИ по баннеру закрепа.
class _JumpFlash extends StatefulWidget {
  final Widget child;
  const _JumpFlash({super.key, required this.child});

  @override
  State<_JumpFlash> createState() => _JumpFlashState();
}

class _JumpFlashState extends State<_JumpFlash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // Было 1000мс, пользователь попросил снизить скорость в 1.75 раза —
    // 1000 * 1.75 = 1750мс. Регулируется одной цифрой, если понадобится
    // ещё раз.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1750),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Curves.linear — было easeOut: та кривая гасит быстро в начале и
    // долго "дотягивает" почти незаметный хвост в конце, что и читалось
    // как неравномерно (жалоба пользователя). Linear — постоянная
    // скорость затухания на всём протяжении, без рывков.
    final fade = CurvedAnimation(parent: _controller, curve: Curves.linear);
    return AnimatedBuilder(
      animation: fade,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.lightBlueAccent.withValues(
              alpha: 0.32 * (1 - fade.value),
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: child,
        );
      },
      child: widget.child,
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
