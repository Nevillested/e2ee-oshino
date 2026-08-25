import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../l10n/app_strings.dart';

/// "Заметки" — переписка с самим собой: полноправный чат в ChatStore под
/// этим фиксированным peerLogin (не настоящий логин — такой строка не
/// может быть выдана при регистрации, см. валидацию логина на сервере),
/// просто без сетевой отправки — см. ChatScreen._isNotes.
const notesPeerLogin = '__notes__';

class StoredMessage {
  final String messageId;
  final String text;
  final bool isMine;
  final int timestamp;
  final bool isMedia;
  final bool isFile;
  // Видео, выбранное через плитку медиа (галерея), а не через плитку
  // "файл" — в отличие от isFile, у него ЕСТЬ превью (кадр из видео, см.
  // generateVideoThumbnail) и оно открывается во встроенном просмотрщике,
  // как фото, а не иконкой+именем (ТЗ пользователя).
  final bool isVideo;
  final int fileSize;
  final bool chunked;
  final String? mediaId;
  final String? mediaKeyBase64;
  final String? mediaNonceBase64;
  final String? mediaMacBase64;
  final String? fileName;

  /// Фото/видео со спойлером (см. media_picker_sheet.dart — "Hide with
  /// spoiler" на весь выбор разом) — до тапа показывается заблюренным (см.
  /// _photoPreview в chat_screen.dart), тап открывает как обычно.
  /// Раскрытие ЭФЕМЕРНОЕ (не сохраняется) — при повторном входе в чат
  /// снова показывается скрытым, см. ТЗ пользователя.
  final bool isSpoiler;

  /// Голосовое/видео-кружок (у нас — квадрат) сообщение — используют те же
  /// media*-поля выше для загрузки/шифрования, просто рендерятся и
  /// проигрываются иначе, чем обычное фото/файл.
  final bool isVoice;
  final bool isVideoNote;
  final int? durationMs;
  final String status;
  final String? processingStep;
  final String? localPreviewPath;
  final String? groupId;

  /// Запись о звонке — каждое устройство по-прежнему пишет её на основе
  /// того, что само наблюдало во время звонка (звонки не идут через
  /// серверную доставку сообщений, кроме офлайн-подстраховки missedCall),
  /// но во всём остальном звонок — такое же сообщение, как текст: тот же
  /// id (см. addCallLog(callId:)), то же участие в "удалить у обоих" и в
  /// read-receipt (см. status/readReceiptSent выше) — просто с
  /// исключением "собеседник ответил → сразу считается прочитанным", это
  /// решается в addCallLog.
  final bool isCallLog;
  final String? callDirection; // 'outgoing' | 'incoming'
  final String? callOutcome; // 'answered' | 'no_answer' | 'missed'
  final int? callDurationSeconds;

  /// Ответ на другое сообщение — превью снимается в момент отправки (см.
  /// InnerMessage.text/.media), поэтому переживает последующее
  /// редактирование/удаление оригинала.
  final String? replyToMessageId;
  final String? replyToPreview;

  final bool edited;

  /// До 2 реакций на сообщение — это 1:1 переписка, реагировать может
  /// только каждая из двух сторон, по одной реакции на человека.
  final String? myReaction;
  final String? peerReaction;

  /// Только для ЧУЖИХ сообщений (isMine == false) — отправили ли мы уже
  /// собеседнику подтверждение прочтения этого конкретного сообщения (см.
  /// InnerMessage.readReceipt). Без этого флага пришлось бы либо слать
  /// подтверждение по всей истории чата заново при каждом открытии, либо
  /// вообще не знать, что уже подтверждено.
  final bool readReceiptSent;

  StoredMessage(
    this.messageId,
    this.text,
    this.isMine,
    this.timestamp, {
    this.isMedia = false,
    this.isFile = false,
    this.isVideo = false,
    this.fileSize = 0,
    this.chunked = false,
    this.mediaId,
    this.mediaKeyBase64,
    this.mediaNonceBase64,
    this.mediaMacBase64,
    this.fileName,
    this.isSpoiler = false,
    this.isVoice = false,
    this.isVideoNote = false,
    this.durationMs,
    this.status = 'sent',
    this.processingStep,
    this.localPreviewPath,
    this.groupId,
    this.isCallLog = false,
    this.callDirection,
    this.callOutcome,
    this.callDurationSeconds,
    this.replyToMessageId,
    this.replyToPreview,
    this.edited = false,
    this.myReaction,
    this.peerReaction,
    this.readReceiptSent = false,
  });

  /// Единая точка "поменять несколько полей, остальное скопировать как
  /// есть" — раньше каждое обновление (updateMessageStatus и т.п.) вручную
  /// пересобирало StoredMessage, перечисляя ВСЕ поля по отдельности; любое
  /// новое поле, забытое хоть в одном таком месте, тихо обнулялось бы при
  /// первом же вызове этой функции. copyWith исключает этот класс ошибок.
  ///
  /// Поля со значением null-по-умолчанию, которые нужно уметь явно
  /// СБРОСИТЬ в null (реакции, превью ответа), принимают отдельный
  /// clearX-флаг — просто передать null в обычный параметр означало бы
  /// "не меняй", а не "сотри".
  StoredMessage copyWith({
    String? text,
    String? status,
    String? processingStep,
    bool clearProcessingStep = false,
    String? mediaId,
    String? mediaKeyBase64,
    String? mediaNonceBase64,
    String? mediaMacBase64,
    bool? edited,
    String? myReaction,
    bool clearMyReaction = false,
    String? peerReaction,
    bool clearPeerReaction = false,
    bool? readReceiptSent,
  }) {
    return StoredMessage(
      messageId,
      text ?? this.text,
      isMine,
      timestamp,
      isMedia: isMedia,
      isFile: isFile,
      isVideo: isVideo,
      fileSize: fileSize,
      chunked: chunked,
      mediaId: mediaId ?? this.mediaId,
      mediaKeyBase64: mediaKeyBase64 ?? this.mediaKeyBase64,
      mediaNonceBase64: mediaNonceBase64 ?? this.mediaNonceBase64,
      mediaMacBase64: mediaMacBase64 ?? this.mediaMacBase64,
      fileName: fileName,
      isSpoiler: isSpoiler,
      isVoice: isVoice,
      isVideoNote: isVideoNote,
      durationMs: durationMs,
      status: status ?? this.status,
      processingStep: clearProcessingStep
          ? null
          : (processingStep ?? this.processingStep),
      localPreviewPath: localPreviewPath,
      groupId: groupId,
      isCallLog: isCallLog,
      callDirection: callDirection,
      callOutcome: callOutcome,
      callDurationSeconds: callDurationSeconds,
      replyToMessageId: replyToMessageId,
      replyToPreview: replyToPreview,
      edited: edited ?? this.edited,
      myReaction: clearMyReaction ? null : (myReaction ?? this.myReaction),
      peerReaction: clearPeerReaction
          ? null
          : (peerReaction ?? this.peerReaction),
      readReceiptSent: readReceiptSent ?? this.readReceiptSent,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': messageId,
    'text': text,
    'is_mine': isMine,
    'ts': timestamp,
    'is_media': isMedia,
    'is_file': isFile,
    'is_video': isVideo,
    'file_size': fileSize,
    'chunked': chunked,
    'media_id': mediaId,
    'media_key': mediaKeyBase64,
    'media_nonce': mediaNonceBase64,
    'media_mac': mediaMacBase64,
    'file_name': fileName,
    'is_spoiler': isSpoiler,
    'is_voice': isVoice,
    'is_video_note': isVideoNote,
    'duration_ms': durationMs,
    'status': status,
    'step': processingStep,
    'local_preview': localPreviewPath,
    'group_id': groupId,
    'is_call_log': isCallLog,
    'call_direction': callDirection,
    'call_outcome': callOutcome,
    'call_duration': callDurationSeconds,
    'reply_to_id': replyToMessageId,
    'reply_to_preview': replyToPreview,
    'edited': edited,
    'my_reaction': myReaction,
    'peer_reaction': peerReaction,
    'read_receipt_sent': readReceiptSent,
  };

  static StoredMessage fromJson(Map<String, dynamic> j) => StoredMessage(
    j['id'] as String? ?? '',
    j['text'] as String,
    j['is_mine'] as bool,
    j['ts'] as int,
    isMedia: j['is_media'] as bool? ?? false,
    isFile: j['is_file'] as bool? ?? false,
    isVideo: j['is_video'] as bool? ?? false,
    fileSize: j['file_size'] as int? ?? 0,
    chunked: j['chunked'] as bool? ?? false,
    mediaId: j['media_id'] as String?,
    mediaKeyBase64: j['media_key'] as String?,
    mediaNonceBase64: j['media_nonce'] as String?,
    mediaMacBase64: j['media_mac'] as String?,
    fileName: j['file_name'] as String?,
    isSpoiler: j['is_spoiler'] as bool? ?? false,
    isVoice: j['is_voice'] as bool? ?? false,
    isVideoNote: j['is_video_note'] as bool? ?? false,
    durationMs: j['duration_ms'] as int?,
    status: j['status'] as String? ?? 'sent',
    processingStep: j['step'] as String?,
    localPreviewPath: j['local_preview'] as String?,
    groupId: j['group_id'] as String?,
    isCallLog: j['is_call_log'] as bool? ?? false,
    callDirection: j['call_direction'] as String?,
    callOutcome: j['call_outcome'] as String?,
    callDurationSeconds: j['call_duration'] as int?,
    replyToMessageId: j['reply_to_id'] as String?,
    replyToPreview: j['reply_to_preview'] as String?,
    edited: j['edited'] as bool? ?? false,
    myReaction: j['my_reaction'] as String?,
    peerReaction: j['peer_reaction'] as String?,
    readReceiptSent: j['read_receipt_sent'] as bool? ?? false,
  );
}

class ChatSummary {
  final String peerLogin;
  String? lastKnownAccountId;
  String? lastKnownDeviceId;
  String lastMessage;
  int lastTimestamp;
  bool isDeleted;
  int unreadCount;
  String? pinnedMessageId;

  /// Когда ЧАТ (не отдельное сообщение — см. pinnedMessageId выше) был
  /// закреплён в списке чатов — null, если не закреплён. Момент закрепления
  /// нужен, а не просто bool: несколько закреплённых чатов сортируются
  /// между собой по свежести закрепления (см. ChatStore.compareForList).
  int? chatPinnedAt;

  /// Уведомления по этому чату выключены — как локально (не проигрывать
  /// звук/вибрацию на новое сообщение), так и на сервере (см.
  /// ApiClient.muteChat — сервер не шлёт будящий push, пока чат замьючен).
  bool muted;

  /// Две независимые стороны блокировки (см. ApiClient.getBlockedContacts):
  /// blockedByMe — заблокировал ли Я этого собеседника (надпись первого
  /// приоритета в композере-заглушке); blockingMe — заблокировал ли ОН
  /// меня (надпись второго приоритета, если сам я его не блокировал).
  bool blockedByMe;
  bool blockingMe;

  /// Галочки в списке чатов (см. ТЗ пользователя) — показываются, только
  /// когда последнее сообщение чата МОЁ (lastMessageIsMine): одна, если
  /// собеседник его ещё не прочитал (lastMessageIsRead == false), две —
  /// если уже прочитал. Для входящих последних сообщений галочки не
  /// показываются вовсе, вне зависимости от этих полей.
  bool lastMessageIsMine;
  bool lastMessageIsRead;

  ChatSummary(
    this.peerLogin,
    this.lastMessage,
    this.lastTimestamp, {
    this.lastKnownAccountId,
    this.lastKnownDeviceId,
    this.isDeleted = false,
    this.unreadCount = 0,
    this.pinnedMessageId,
    this.chatPinnedAt,
    this.muted = false,
    this.blockedByMe = false,
    this.blockingMe = false,
    this.lastMessageIsMine = false,
    this.lastMessageIsRead = false,
  });
}

class ChatStore {
  static const _storage = FlutterSecureStorage();
  static String _messagesKey(String peerLogin) => 'messages:$peerLogin';
  static const _peersIndexKey = 'known_peers';

  static final _changesController = StreamController<void>.broadcast();
  static Stream<void> get changes => _changesController.stream;

  static Future<List<StoredMessage>> getMessages(String peerLogin) async {
    final stored = await _storage.read(key: _messagesKey(peerLogin));
    if (stored == null) return [];
    final list = jsonDecode(stored) as List<dynamic>;
    return list
        .map((e) => StoredMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> _writeMessages(
    String peerLogin,
    List<StoredMessage> messages,
  ) {
    return _storage.write(
      key: _messagesKey(peerLogin),
      value: jsonEncode(messages.map((m) => m.toJson()).toList()),
    );
  }

  // "Надгробия" удалённых id — нужны на случай, когда входящее
  // control-сообщение 'delete' (см. message_router.dart) обгоняет само
  // удаляемое сообщение: обе доставки идут независимо через одну и ту же
  // офлайн-очередь на сервере, и хотя сервер отдаёт их в порядке
  // ORDER BY created_at (создание 'delete' физически позже — его нельзя
  // отправить раньше, чем удаляемое сообщение уже существует), сам факт
  // "раньше создано" не гарантирует "раньше обработано" на приёмной
  // стороне (например, если 'delete' успело доставиться и подтвердиться, а
  // оригинал — ещё не расшифрован из-за временного сбоя сессии, см.
  // AlreadyProcessedException/session-reset выше, и будет переспрошен
  // позже). Без этого addMessage тихо добавил(а) бы уже "удалённое"
  // сообщение обратно — removeWhere в deleteMessages к этому моменту уже
  // отработал и ему нечего будет вычищать при повторном приходе 'delete'
  // (которого и не будет: у отправителя это было одно-единственное событие).
  static String _deletedIdsKey(String peerLogin) => 'deleted_ids:$peerLogin';
  static const _maxTombstones = 500;

  static Future<Set<String>> _getTombstones(String peerLogin) async {
    final stored = await _storage.read(key: _deletedIdsKey(peerLogin));
    if (stored == null) return {};
    return (jsonDecode(stored) as List<dynamic>).cast<String>().toSet();
  }

  static Future<void> _addTombstones(String peerLogin, List<String> ids) async {
    if (ids.isEmpty) return;
    final set = await _getTombstones(peerLogin);
    set.addAll(ids);
    // Ограничиваем размер — это короткоживущая защита от гонки доставки, а
    // не журнал на всю историю чата, расти бесконечно ей незачем.
    final trimmed = set.length > _maxTombstones
        ? set.skip(set.length - _maxTombstones).toSet()
        : set;
    await _storage.write(
      key: _deletedIdsKey(peerLogin),
      value: jsonEncode(trimmed.toList()),
    );
  }

  /// true, если это сообщение уже было помечено удалённым ДО того, как
  /// успело реально попасть в хранилище — заодно "расходует" запись: раз
  /// она сослужила службу, незачем занимать место дальше.
  static Future<bool> _consumeTombstone(
    String peerLogin,
    String messageId,
  ) async {
    final set = await _getTombstones(peerLogin);
    if (!set.remove(messageId)) return false;
    await _storage.write(
      key: _deletedIdsKey(peerLogin),
      value: jsonEncode(set.toList()),
    );
    return true;
  }

  // Каждое из addMessage/addMessages/_replace/deleteMessages читает ВЕСЬ
  // список сообщений пира, меняет его в памяти и пишет обратно целиком —
  // без сериализации это классический lost update: если два вызова для
  // ОДНОГО peerLogin пересекаются по времени (что и происходит при быстрой
  // отправке нескольких сообщений подряд — вставка следующего "sending"
  // стартует раньше, чем успевает записаться статус "sent" предыдущего),
  // тот, что запишет свою копию списка ПОЗЖЕ, перезатирает изменение
  // первого его же более старым снимком. Внешне это выглядело как
  // сообщение, навсегда застрявшее на статусе "sending", хотя собеседник
  // его уже получил — апдейт статуса просто был молча затёрт. Очередь
  // по peerLogin ниже гарантирует, что для одного и того же чата такие
  // операции всегда выполняются строго одна за другой.
  static final Map<String, Future<void>> _peerLocks = {};

  static Future<T> _withPeerLock<T>(
    String peerLogin,
    Future<T> Function() action,
  ) {
    final previous = _peerLocks[peerLogin] ?? Future<void>.value();
    final completer = Completer<void>();
    _peerLocks[peerLogin] = previous.then((_) => completer.future);
    return previous.then((_) async {
      try {
        return await action();
      } finally {
        completer.complete();
      }
    });
  }

  // То же самое, но для ОБЩЕГО индекса чатов (known_peers) — setPinned,
  // setChatPinned, setChatMuted, _touchPeer, clearHistory, removeChat и
  // остальные ниже все читают ВЕСЬ список чатов, меняют один элемент и
  // пишут список обратно целиком. Раньше это не было сериализовано вообще:
  // если, например, "Очистить историю" (читает peers, сбрасывает превью,
  // пишет обратно) и одновременно пришедшее сообщение (_touchPeer — тоже
  // читает peers, обновляет своё превью, пишет обратно) пересекались по
  // времени, тот вызов, что записывал СВОЙ более старый снимок списка
  // ПОЗЖЕ, тихо затирал изменение первого — внешне это выглядело как
  // "превью последнего сообщения не очистилось". Один общий лок на весь
  // индекс (а не per-peer, как выше) — раз это один и тот же файл в
  // хранилище, сериализовать нужно ВСЕ операции над ним между собой, а не
  // только для одного и того же peerLogin.
  static Future<void>? _peersLock;

  static Future<T> _withPeersLock<T>(Future<T> Function() action) {
    final previous = _peersLock ?? Future<void>.value();
    final completer = Completer<void>();
    _peersLock = previous.then((_) => completer.future);
    return previous.then((_) async {
      try {
        return await action();
      } finally {
        completer.complete();
      }
    });
  }

  static Future<void> addMessage(
    String peerLogin,
    StoredMessage message, {
    String? accountId,
    bool incrementUnread = false,
  }) async {
    var added = false;
    await _withPeerLock(peerLogin, () async {
      final messages = await getMessages(peerLogin);
      // На переподключении сервер теперь ждёт ack перед тем, как убрать
      // сообщение из своей очереди (см. websocket.go) — если ack потеряется
      // по пути обратно, то же самое сообщение может честно прийти ещё раз
      // при следующем подключении. Тут — единственная точка, куда стекаются
      // все входящие сообщения, поэтому дубль по message_id гасим именно
      // здесь, а не в каждом месте, откуда вызывается addMessage.
      if (messages.any((m) => m.messageId == message.messageId)) return;
      if (await _consumeTombstone(peerLogin, message.messageId)) return;
      messages.add(message);
      added = true;
      await _writeMessages(peerLogin, messages);
    });
    if (!added) return;
    await _touchPeer(
      peerLogin,
      message.text,
      message.timestamp,
      accountId: accountId,
      incrementUnread: incrementUnread,
      isMine: message.isMine,
      isRead: message.status == 'read',
    );
  }

  /// Добавляет сразу несколько сообщений одной записью в хранилище и
  /// ОДНИМ уведомлением об изменениях — используется для группы файлов,
  /// которая должна появиться в чате разом, а не по одному сообщению.
  static Future<void> addMessages(
    String peerLogin,
    List<StoredMessage> newMessages, {
    String? accountId,
    bool incrementUnread = false,
  }) async {
    if (newMessages.isEmpty) return;
    var actuallyAdded = <StoredMessage>[];
    await _withPeerLock(peerLogin, () async {
      final messages = await getMessages(peerLogin);
      final existingIds = messages.map((m) => m.messageId).toSet();
      // Тот же дубль-гард, что и в addMessage — см. комментарий там.
      final candidates = newMessages
          .where((m) => !existingIds.contains(m.messageId))
          .toList();
      final tombstones = await _getTombstones(peerLogin);
      actuallyAdded = candidates
          .where((m) => !tombstones.contains(m.messageId))
          .toList();
      final consumed = candidates
          .where((m) => tombstones.contains(m.messageId))
          .map((m) => m.messageId)
          .toSet();
      if (consumed.isNotEmpty) {
        tombstones.removeAll(consumed);
        await _storage.write(
          key: _deletedIdsKey(peerLogin),
          value: jsonEncode(tombstones.toList()),
        );
      }
      if (actuallyAdded.isEmpty) return;
      messages.addAll(actuallyAdded);
      await _writeMessages(peerLogin, messages);
    });
    if (actuallyAdded.isEmpty) return;
    final last = actuallyAdded.reduce(
      (a, b) => a.timestamp >= b.timestamp ? a : b,
    );
    await _touchPeer(
      peerLogin,
      last.isVoice
          ? '🎤 ${tr('media.voiceNote')}'
          : last.isVideoNote
          ? '🎥 ${tr('media.videoNote')}'
          : last.isMedia
          ? (last.isFile
                ? (last.fileName ?? '📎 ${tr('media.file')}')
                : '📷 ${tr('media.photo')}')
          : last.text,
      last.timestamp,
      accountId: accountId,
      incrementUnread: incrementUnread,
      isMine: last.isMine,
      isRead: last.status == 'read',
    );
  }

  /// Пишет запись о завершённом звонке — тем же путём, что и обычное
  /// сообщение (одна запись + одно уведомление об изменениях).
  static Future<void> addCallLog(
    String peerLogin, {
    required String direction,
    required String outcome,
    required int timestamp,
    int? durationSeconds,
    String? accountId,
    bool incrementUnread = false,
    // Общий для обеих сторон звонка UUID (см. CallService._callId) — даёт
    // записи звонка ОДИНАКОВЫЙ id на обоих устройствах, поэтому "удалить у
    // обоих" (InnerMessage.delete по messageId) теперь находит и стирает
    // её и у собеседника тоже, а не только локально. Если не передан
    // (редкий краевой случай — звонок отклонили кнопкой в уведомлении при
    // полностью закрытом приложении, там callId нативная сторона пока не
    // хранит) — старая, чисто локальная схема id, как и раньше.
    String? callId,
  }) {
    final id = callId != null ? 'call_$callId' : 'call_${timestamp}_$direction';
    // text используется только как превью последнего сообщения в списке
    // чатов (ChatSummary) — сам пузырь звонка в чате рендерится отдельно
    // и это поле не читает.
    final preview = switch (outcome) {
      'answered' => '📞 ${tr('call.answered')}',
      'missed' => '📞 ${tr('call.missed')}',
      _ => '📞 ${tr('call.noAnswer')}',
    };
    // Единственное исключение из общих правил read-receipt: если
    // собеседник реально ответил — это уже живое, синхронное
    // подтверждение "он в курсе" само по себе, отдельно спрашивать не
    // нужно. На missed/no_answer — обычные дефолты, звонок пойдёт по
    // тому же пути read-receipt, что и любое другое сообщение.
    final answered = outcome == 'answered';
    return addMessage(
      peerLogin,
      StoredMessage(
        id,
        preview,
        direction == 'outgoing',
        timestamp,
        isCallLog: true,
        callDirection: direction,
        callOutcome: outcome,
        callDurationSeconds: durationSeconds,
        status: answered ? 'read' : 'sent',
        readReceiptSent: answered,
      ),
      accountId: accountId,
      incrementUnread: incrementUnread,
    );
  }

  static Future<void> _replace(
    String peerLogin,
    String messageId,
    StoredMessage Function(StoredMessage old) update,
  ) async {
    await _withPeerLock(peerLogin, () async {
      final messages = await getMessages(peerLogin);
      final index = messages.indexWhere((m) => m.messageId == messageId);
      if (index == -1) return;
      messages[index] = update(messages[index]);
      await _writeMessages(peerLogin, messages);
    });
    _changesController.add(null);
  }

  static Future<void> updateMessageStatus(
    String peerLogin,
    String messageId,
    String newStatus,
  ) {
    return _replace(
      peerLogin,
      messageId,
      (old) => old.copyWith(
        status: newStatus,
        clearProcessingStep:
            newStatus == 'sent' ||
            newStatus == 'failed' ||
            newStatus == 'queued',
      ),
    );
  }

  static Future<void> updateProcessingStep(
    String peerLogin,
    String messageId,
    String step,
  ) {
    return _replace(
      peerLogin,
      messageId,
      (old) => old.copyWith(processingStep: step),
    );
  }

  /// Сохраняет реальный mediaId и ключи ПОСЛЕ успешной загрузки на
  /// сервер — без этого вызова сообщение навсегда остаётся без mediaId,
  /// что и вызывало крах при попытке показать финальное превью.
  static Future<void> updateMediaInfo(
    String peerLogin,
    String messageId, {
    required String mediaId,
    required String keyBase64,
    String? nonceBase64,
    String? macBase64,
  }) {
    return _replace(
      peerLogin,
      messageId,
      (old) => old.copyWith(
        mediaId: mediaId,
        mediaKeyBase64: keyBase64,
        mediaNonceBase64: nonceBase64,
        mediaMacBase64: macBase64,
      ),
    );
  }

  /// isMine=true — это МОЯ реакция (я тапнул эмодзи); false — реакция
  /// пришла от собеседника (получена через message_router). emoji=null
  /// снимает реакцию этой стороны.
  static Future<void> setReaction(
    String peerLogin,
    String messageId, {
    required bool isMine,
    String? emoji,
  }) {
    return _replace(
      peerLogin,
      messageId,
      (old) => old.copyWith(
        myReaction: isMine ? emoji : null,
        clearMyReaction: isMine && emoji == null,
        peerReaction: !isMine ? emoji : null,
        clearPeerReaction: !isMine && emoji == null,
      ),
    );
  }

  static Future<void> editMessageText(
    String peerLogin,
    String messageId,
    String newText,
  ) {
    return _replace(
      peerLogin,
      messageId,
      (old) => old.copyWith(text: newText, edited: true),
    );
  }

  /// Применяется у АВТОРА сообщений — приходит от собеседника через
  /// InnerMessage.readReceipt после того, как он реально увидел эти (наши)
  /// сообщения. Молча игнорирует id, которых уже нет в истории (удалены)
  /// или которые уже 'read' — идемпотентно.
  static Future<void> markMessagesRead(
    String peerLogin,
    List<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return;
    final ids = messageIds.toSet();
    var lastAfterUpdate = const <StoredMessage>[];
    await _withPeerLock(peerLogin, () async {
      final messages = await getMessages(peerLogin);
      var changed = false;
      for (var i = 0; i < messages.length; i++) {
        if (ids.contains(messages[i].messageId) &&
            messages[i].status != 'read') {
          messages[i] = messages[i].copyWith(status: 'read');
          changed = true;
        }
      }
      if (changed) await _writeMessages(peerLogin, messages);
      lastAfterUpdate = messages;
    });
    // Галочки в списке чатов (см. ChatSummary.lastMessageIsRead) отражают
    // read-статус ПОСЛЕДНЕГО сообщения, а не конкретно того, что попало в
    // этот список id — пересчитываем по факту, а не пытаемся угадать,
    // совпадает ли одно из только что прочитанных с текущим последним.
    if (lastAfterUpdate.isNotEmpty) {
      final last = lastAfterUpdate.reduce(
        (a, b) => a.timestamp >= b.timestamp ? a : b,
      );
      await _withPeersLock(() async {
        final peers = await getKnownPeers();
        final existing = peers.where((p) => p.peerLogin == peerLogin).toList();
        if (existing.isNotEmpty &&
            (existing.first.lastMessageIsMine != last.isMine ||
                existing.first.lastMessageIsRead !=
                    (last.isMine && last.status == 'read'))) {
          existing.first.lastMessageIsMine = last.isMine;
          existing.first.lastMessageIsRead =
              last.isMine && last.status == 'read';
          await _writePeers(peers);
        }
      });
    }
    _changesController.add(null);
  }

  /// Применяется у ПОЛУЧАТЕЛЯ (перед тем как отправить собеседнику
  /// InnerMessage.readReceipt) — отмечает, что квитанция за эти (чужие)
  /// сообщения уже отправлена, чтобы не слать её повторно при следующем
  /// открытии чата.
  static Future<void> markReadReceiptsSent(
    String peerLogin,
    List<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return;
    final ids = messageIds.toSet();
    await _withPeerLock(peerLogin, () async {
      final messages = await getMessages(peerLogin);
      var changed = false;
      for (var i = 0; i < messages.length; i++) {
        if (ids.contains(messages[i].messageId) &&
            !messages[i].readReceiptSent) {
          messages[i] = messages[i].copyWith(readReceiptSent: true);
          changed = true;
        }
      }
      if (changed) await _writeMessages(peerLogin, messages);
    });
  }

  /// Удаляет ЛОКАЛЬНО (и у себя при "у меня", и здесь же — при "у
  /// обоих", после того как control-сообщение уже отправлено собеседнику;
  /// сам факт отправки — забота вызывающего кода, не этой функции).
  static Future<void> deleteMessages(
    String peerLogin,
    List<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return;
    final ids = messageIds.toSet();
    var remaining = const <StoredMessage>[];
    await _withPeerLock(peerLogin, () async {
      final messages = await getMessages(peerLogin);
      messages.removeWhere((m) => ids.contains(m.messageId));
      remaining = messages;
      await _writeMessages(peerLogin, messages);
      // Помечаем удалённым и то, чего ещё не было в списке — если сообщение
      // с этим id придёт позже (переспрошенная офлайн-очередь, гонка
      // 'delete' vs оригинала, см. _consumeTombstone выше), addMessage не
      // должен молча вернуть его обратно в чат.
      await _addTombstones(peerLogin, ids.toList());
    });
    // Превью последнего сообщения в списке чатов могло указывать как раз на
    // одно из только что удалённых (это касается и своего удаления, и
    // входящего control-сообщения 'delete' от собеседника, см.
    // message_router.dart) — пересчитываем его по тому, что реально
    // осталось, иначе список продолжал бы показывать текст уже удалённого
    // сообщения как ни в чём не бывало.
    await _withPeersLock(() async {
      final peers = await getKnownPeers();
      final existing = peers.where((p) => p.peerLogin == peerLogin).toList();
      if (existing.isEmpty) {
        _changesController.add(null);
        return;
      }
      if (remaining.isEmpty) {
        existing.first.lastMessage = '';
        existing.first.lastTimestamp = 0;
        existing.first.lastMessageIsMine = false;
        existing.first.lastMessageIsRead = false;
      } else {
        final last = remaining.reduce(
          (a, b) => a.timestamp >= b.timestamp ? a : b,
        );
        existing.first.lastMessage = last.text;
        existing.first.lastTimestamp = last.timestamp;
        existing.first.lastMessageIsMine = last.isMine;
        existing.first.lastMessageIsRead = last.status == 'read';
      }
      await _writePeers(peers);
    });
  }

  /// null — открепить. Один закреп на чат; новый вызов просто заменяет
  /// старый идентификатор.
  static Future<void> setPinned(String peerLogin, String? messageId) {
    return _withPeersLock(() async {
      final peers = await getKnownPeers();
      final existing = peers.where((p) => p.peerLogin == peerLogin).toList();
      if (existing.isEmpty) {
        if (messageId == null) return;
        peers.add(ChatSummary(peerLogin, '', 0, pinnedMessageId: messageId));
      } else {
        existing.first.pinnedMessageId = messageId;
      }
      await _writePeers(peers);
    });
  }

  /// Закрепление ЧАТА в списке чатов (не путать с setPinned выше — то
  /// закрепляет одно СООБЩЕНИЕ внутри уже открытого чата, баннером сверху
  /// переписки). См. ChatSummary.chatPinnedAt — момент закрепления, а не
  /// просто флаг, ради сортировки нескольких закреплённых чатов между собой.
  static Future<void> setChatPinned(String peerLogin, bool pinned) {
    return _withPeersLock(() async {
      final peers = await getKnownPeers();
      final existing = peers.where((p) => p.peerLogin == peerLogin).toList();
      if (existing.isEmpty) {
        if (!pinned) return;
        peers.add(
          ChatSummary(
            peerLogin,
            '',
            0,
            chatPinnedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      } else {
        existing.first.chatPinnedAt = pinned
            ? DateTime.now().millisecondsSinceEpoch
            : null;
      }
      await _writePeers(peers);
    });
  }

  /// Замьючен ли чат локально — используется, чтобы не проигрывать звук
  /// входящего сообщения, пока приложение открыто (см. message_router.dart:
  /// сам мьют на сервере подавляет только push, когда приложение закрыто/
  /// свёрнуто — про звук ЖИВОГО сообщения, пришедшего по уже открытому
  /// WebSocket-соединению, сервер знать не может и не должен).
  static Future<bool> isChatMuted(String peerLogin) async {
    final peers = await getKnownPeers();
    final existing = peers.where((p) => p.peerLogin == peerLogin);
    return existing.isNotEmpty && existing.first.muted;
  }

  /// Локальный флаг мьюта — серверный вызов (ApiClient.muteChat/unmuteChat,
  /// нужен для подавления push) делает вызывающий код отдельно, эта функция
  /// только сохраняет состояние для локального UI (иконка/текст пункта меню).
  static Future<void> setChatMuted(String peerLogin, bool muted) {
    return _withPeersLock(() async {
      final peers = await getKnownPeers();
      final existing = peers.where((p) => p.peerLogin == peerLogin).toList();
      if (existing.isEmpty) return;
      existing.first.muted = muted;
      await _writePeers(peers);
    });
  }

  /// Сверяет локальные флаги мьюта со списком account_id, замьюченных на
  /// сервере (см. ApiClient.getMutedChats) — вызывается один раз при
  /// подключении, чтобы локальное состояние не разъезжалось с серверным
  /// (например, после переустановки приложения — сама переписка и так
  /// теряется, но мьют, once поставленный, должен остаться в силе).
  static Future<void> syncMutedFromServer(Set<String> mutedAccountIds) {
    return _withPeersLock(() async {
      final peers = await getKnownPeers();
      var changed = false;
      for (final p in peers) {
        final shouldBeMuted =
            p.lastKnownAccountId != null &&
            mutedAccountIds.contains(p.lastKnownAccountId);
        if (p.muted != shouldBeMuted) {
          p.muted = shouldBeMuted;
          changed = true;
        }
      }
      if (changed) await _writePeers(peers);
    });
  }

  /// Локальный флаг "я заблокировал" — серверный вызов (ApiClient.
  /// blockContact/unblockContact) делает вызывающий код отдельно, эта
  /// функция только сохраняет состояние для локального UI (композер-
  /// заглушка в chat_screen.dart, пункт меню).
  static Future<void> setChatBlockedByMe(String peerLogin, bool blocked) {
    return _withPeersLock(() async {
      final peers = await getKnownPeers();
      final existing = peers.where((p) => p.peerLogin == peerLogin).toList();
      if (existing.isEmpty) return;
      existing.first.blockedByMe = blocked;
      await _writePeers(peers);
    });
  }

  /// Сверяет локальные флаги блокировки (в обе стороны) с сервером (см.
  /// ApiClient.getBlockedContacts) — вызывается один раз при подключении,
  /// тем же способом, что и syncMutedFromServer.
  static Future<void> syncBlockedFromServer(
    Set<String> blockedByMeAccountIds,
    Set<String> blockingMeAccountIds,
  ) {
    return _withPeersLock(() async {
      final peers = await getKnownPeers();
      var changed = false;
      for (final p in peers) {
        final accountId = p.lastKnownAccountId;
        final shouldBeBlockedByMe =
            accountId != null && blockedByMeAccountIds.contains(accountId);
        final shouldBeBlockingMe =
            accountId != null && blockingMeAccountIds.contains(accountId);
        if (p.blockedByMe != shouldBeBlockedByMe) {
          p.blockedByMe = shouldBeBlockedByMe;
          changed = true;
        }
        if (p.blockingMe != shouldBeBlockingMe) {
          p.blockingMe = shouldBeBlockingMe;
          changed = true;
        }
      }
      if (changed) await _writePeers(peers);
    });
  }

  /// Очищает историю чата, но саму запись в списке чатов оставляет (в
  /// отличие от removeChat ниже) — ровно то же самое, что "удалить все
  /// сообщения", просто по всем id разом (включая записи о звонках — они
  /// хранятся в том же списке, что и обычные сообщения, никакого особого
  /// статуса у них нет); сама отправка control-сообщения собеседнику (если
  /// отмечена галочка "у обоих") — забота вызывающего кода.
  static Future<void> clearHistory(String peerLogin) async {
    await _withPeerLock(peerLogin, () async {
      await _writeMessages(peerLogin, []);
      await _storage.delete(key: _deletedIdsKey(peerLogin));
    });
    await _withPeersLock(() async {
      final peers = await getKnownPeers();
      final existing = peers.where((p) => p.peerLogin == peerLogin).toList();
      if (existing.isNotEmpty) {
        existing.first.lastMessage = '';
        existing.first.lastTimestamp = 0;
        await _writePeers(peers);
      } else {
        _changesController.add(null);
      }
    });
  }

  /// В отличие от clearHistory — ещё и убирает сам чат из списка. Сообщения
  /// собеседнику (если отмечена галочка "у обоих") отправляет вызывающий код
  /// ДО этого вызова — сама эта функция только чистит локальное хранилище.
  static Future<void> removeChat(String peerLogin) async {
    await _withPeerLock(peerLogin, () async {
      await _storage.delete(key: _messagesKey(peerLogin));
      await _storage.delete(key: _deletedIdsKey(peerLogin));
    });
    await _withPeersLock(() async {
      final peers = await getKnownPeers();
      peers.removeWhere((p) => p.peerLogin == peerLogin);
      await _writePeers(peers);
    });
  }

  /// Порядок в списке чатов: сначала закреплённые (самые свежезакреплённые
  /// — в самом верху), затем остальные — по времени последнего сообщения,
  /// как и раньше. Общая точка и для getKnownPeers, и для
  /// HomePlaceholderScreen._refreshChats (там ещё подмешивается
  /// синтетическая запись "Заметок", которую тоже нужно сортировать по тем
  /// же правилам).
  static int compareForList(ChatSummary a, ChatSummary b) {
    final aPinned = a.chatPinnedAt;
    final bPinned = b.chatPinnedAt;
    if (aPinned != null && bPinned != null) return bPinned.compareTo(aPinned);
    if (aPinned != null) return -1;
    if (bPinned != null) return 1;
    return b.lastTimestamp.compareTo(a.lastTimestamp);
  }

  static Future<void> _touchPeer(
    String peerLogin,
    String lastMessage,
    int timestamp, {
    String? accountId,
    bool incrementUnread = false,
    bool isMine = false,
    bool isRead = false,
  }) {
    return _withPeersLock(() async {
      final peers = await getKnownPeers();
      final existing = peers.where((p) => p.peerLogin == peerLogin).toList();
      if (existing.isNotEmpty) {
        existing.first.lastMessage = lastMessage;
        existing.first.lastTimestamp = timestamp;
        existing.first.lastMessageIsMine = isMine;
        existing.first.lastMessageIsRead = isMine && isRead;
        if (accountId != null) existing.first.lastKnownAccountId = accountId;
        if (incrementUnread) existing.first.unreadCount += 1;
      } else {
        peers.add(
          ChatSummary(
            peerLogin,
            lastMessage,
            timestamp,
            lastKnownAccountId: accountId,
            unreadCount: incrementUnread ? 1 : 0,
            lastMessageIsMine: isMine,
            lastMessageIsRead: isMine && isRead,
          ),
        );
      }
      await _writePeers(peers);
    });
  }

  static Future<void> clearUnread(String peerLogin) {
    return _withPeersLock(() async {
      final peers = await getKnownPeers();
      final existing = peers.where((p) => p.peerLogin == peerLogin).toList();
      if (existing.isEmpty) return;
      if (existing.first.unreadCount == 0) return;
      existing.first.unreadCount = 0;
      await _writePeers(peers);
    });
  }

  static Future<void> setPeerDeletedStatus(String peerLogin, bool isDeleted) {
    return _withPeersLock(() async {
      final peers = await getKnownPeers();
      final existing = peers.where((p) => p.peerLogin == peerLogin).toList();
      if (existing.isEmpty) return;
      existing.first.isDeleted = isDeleted;
      await _writePeers(peers);
    });
  }

  static Future<void> setLastKnownDeviceId(String peerLogin, String deviceId) {
    return _withPeersLock(() async {
      final peers = await getKnownPeers();
      final existing = peers.where((p) => p.peerLogin == peerLogin).toList();
      if (existing.isEmpty) return;
      existing.first.lastKnownDeviceId = deviceId;
      await _writePeers(peers);
    });
  }

  static Future<void> _writePeers(List<ChatSummary> peers) async {
    await _storage.write(
      key: _peersIndexKey,
      value: jsonEncode(
        peers
            .map(
              (p) => {
                'login': p.peerLogin,
                'account_id': p.lastKnownAccountId,
                'device_id': p.lastKnownDeviceId,
                'last_message': p.lastMessage,
                'last_ts': p.lastTimestamp,
                'is_deleted': p.isDeleted,
                'unread': p.unreadCount,
                'pinned_message_id': p.pinnedMessageId,
                'chat_pinned_at': p.chatPinnedAt,
                'muted': p.muted,
                'blocked_by_me': p.blockedByMe,
                'blocking_me': p.blockingMe,
                'last_is_mine': p.lastMessageIsMine,
                'last_is_read': p.lastMessageIsRead,
              },
            )
            .toList(),
      ),
    );
    _changesController.add(null);
  }

  static Future<List<ChatSummary>> getKnownPeers() async {
    final stored = await _storage.read(key: _peersIndexKey);
    if (stored == null) return [];
    final list = jsonDecode(stored) as List<dynamic>;
    return list
        .map(
          (e) => ChatSummary(
            e['login'] as String,
            e['last_message'] as String,
            e['last_ts'] as int,
            lastKnownAccountId: e['account_id'] as String?,
            lastKnownDeviceId: e['device_id'] as String?,
            isDeleted: e['is_deleted'] as bool? ?? false,
            unreadCount: e['unread'] as int? ?? 0,
            pinnedMessageId: e['pinned_message_id'] as String?,
            chatPinnedAt: e['chat_pinned_at'] as int?,
            muted: e['muted'] as bool? ?? false,
            blockedByMe: e['blocked_by_me'] as bool? ?? false,
            blockingMe: e['blocking_me'] as bool? ?? false,
            lastMessageIsMine: e['last_is_mine'] as bool? ?? false,
            lastMessageIsRead: e['last_is_read'] as bool? ?? false,
          ),
        )
        .toList()
      ..sort(compareForList);
  }

  /// Разовый самопочиняющийся пересчёт lastMessageIsMine/lastMessageIsRead
  /// по РЕАЛЬНОЙ истории каждого чата — нужен для уже существующих чатов,
  /// заведённых ДО того, как эти два поля вообще появились (см. ТЗ
  /// пользователя): у них в сохранённом JSON просто нет ключей
  /// last_is_mine/last_is_read, getKnownPeers() молча подставляет false, и
  /// галочки не появляются, пока в чат не придёт/не уйдёт НОВОЕ сообщение
  /// (только тогда сработает _touchPeer). Вызывается один раз при
  /// подключении (см. HomePlaceholderScreen._connect), пересчитывает ВСЕХ
  /// разом по последнему реальному сообщению — так корректно и для старых
  /// чатов, и как подстраховка от любого возможного рассинхрона вообще.
  static Future<void> backfillLastMessageMeta() {
    return _withPeersLock(() async {
      final peers = await getKnownPeers();
      var changed = false;
      for (final p in peers) {
        final messages = await getMessages(p.peerLogin);
        if (messages.isEmpty) continue;
        final last = messages.reduce(
          (a, b) => a.timestamp >= b.timestamp ? a : b,
        );
        final isRead = last.isMine && last.status == 'read';
        if (p.lastMessageIsMine != last.isMine ||
            p.lastMessageIsRead != isRead) {
          p.lastMessageIsMine = last.isMine;
          p.lastMessageIsRead = isRead;
          changed = true;
        }
      }
      if (changed) await _writePeers(peers);
    });
  }
}
