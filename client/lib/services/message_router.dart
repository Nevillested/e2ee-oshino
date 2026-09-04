import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter/widgets.dart' show WidgetsBinding, AppLifecycleState;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../api/api_client.dart';
import '../crypto/double_ratchet.dart';
import '../crypto/key_store.dart';
import '../crypto/message_cipher.dart';
import '../crypto/message_envelope.dart';
import '../crypto/session_store.dart';
import '../crypto/x3dh.dart';
import '../session.dart';
import '../storage/chat_store.dart';
import '../storage/peer_account_store.dart';
import '../storage/peer_identity_store.dart';
import 'active_chat_tracker.dart';
import 'debug_log.dart';
import 'local_notifications.dart';
import 'message_cleanup.dart';
import 'send_lock.dart';
import 'send_queue_processor.dart';
import 'sound_service.dart';
import 'websocket_service.dart';

const _uuid = Uuid();

/// Служебные типы control-сообщений — синхронизируются как обычно, но не
/// считаются "сообщением" для звукового уведомления (см. _processIncoming).
const _silentTypes = {
  'reaction',
  'pin',
  'edit',
  'delete',
  'clear_chat',
  'delete_chat',
  'read_receipt',
};

class MessageRouter {
  static bool _started = false;

  static void start() {
    if (_started) return;
    _started = true;
    WebSocketService.instance.messages.listen(_handleIncoming);
  }

  /// Живой сигнал "у собеседника только что появилась НОВАЯ реакция на
  /// сообщение" — нужен ChatScreen, чтобы проиграть анимацию простановки
  /// (см. _ReactionChip) именно для СВЕЖЕГО события, а не для реакции,
  /// которая была в истории уже при открытии чата. Обычный broadcast
  /// (доставка асинхронная, следующим микротаском) — тут не критично,
  /// в отличие от incomingDeletes ниже, порядок с ChatStore.setReaction не
  /// важен для самой анимации (она смотрит только на факт "только что").
  static final _reactionController =
      StreamController<({String peerLogin, String messageId})>.broadcast();
  static Stream<({String peerLogin, String messageId})> get incomingReactions =>
      _reactionController.stream;

  /// Живой сигнал "собеседник удалил сообщения и у нас тоже" — ChatScreen
  /// использует его, чтобы (если этот чат открыт) успеть сфотографировать
  /// ещё живые пузыри (см. _captureShatterImages) и проиграть тот же эффект
  /// "рассыпания", что и при удалении со своей стороны, а не просто молча
  /// обнаружить, что сообщения исчезли, при следующей перерисовке. sync:
  /// true — намеренно: слушатель должен успеть сработать РАНЬШЕ, чем ниже
  /// по коду выполнится ChatStore.deleteMessages и пузыри реально уйдут из
  /// локального хранилища (а значит и из дерева виджетов при следующей
  /// перерисовке) — обычный (асинхронный) broadcast доставляет события
  /// микрозадачей и не даёт такой гарантии порядка.
  static final _incomingDeleteController =
      StreamController<({String peerLogin, List<String> targetIds})>.broadcast(
        sync: true,
      );
  static Stream<({String peerLogin, List<String> targetIds})>
  get incomingDeletes => _incomingDeleteController.stream;

  static Future<void> _handleIncoming(Map<String, dynamic> envelope) async {
    final senderDeviceId = envelope['sender_device_id'] as String?;
    if (senderDeviceId == null) return;
    // Транспортный довесок от WebSocketService (см. комментарий там) —
    // не часть самого конверта, вынимаем до передачи дальше.
    final deliveryId = envelope.remove('_deliveryId') as String?;
    DebugLog.log(
      'Router incoming from=$senderDeviceId deliveryId=${deliveryId ?? '-'}',
    );

    await SendLock.run(
      senderDeviceId,
      () => _processIncoming(senderDeviceId, envelope, deliveryId),
    );
  }

  /// Служебный конверт (см. _onDecryptFailure) — не шифруется Double
  /// Ratchet (сессия и есть то, что сломано), просто просит собеседника
  /// стереть локальную сессию с нами, чтобы следующая же его отправка
  /// сама подняла свежий X3DH-хендшейк.
  static const _sessionResetType = 'session_reset';

  static const _resetFailureThreshold = 3;
  static const _resetCooldown = Duration(seconds: 30);
  static String _failureCountKey(String deviceId) =>
      'session_reset_failcount:$deviceId';
  static String _lastResetKey(String deviceId) =>
      'session_reset_last_request:$deviceId';

  // Сколько ждать с первого "нет сессии и нет хендшейка" от отправителя,
  // прежде чем сдаться и начать подтверждать такие доставки серверу — см.
  // _giveUpKey ниже. Раньше такие сообщения НИКОГДА не подтверждались:
  // сервер честно передоставлял их заново на каждый реконнект НАВСЕГДА
  // (см. разбор пользовательского лога — тысячи повторов одних и тех же
  // DROP на каждый реконнект, годами копящийся хвост от контакта с давно
  // потерянной сессией). Держать их неподтверждёнными есть смысл ТОЛЬКО
  // на случай гонки доставки: собеседник шлёт несколько сообщений подряд
  // почти одновременно, и то самое, что несёт X3DH-инициализацию (обычно
  // самое первое), доставляется НЕ первым — тогда последующие ещё смогут
  // расшифроваться, как только придёт то, что поднимет сессию. Разумный
  // запас на такую гонку — минуты, не часы и тем более не дни.
  static const _noSessionGiveUpDelay = Duration(minutes: 2);
  static String _noSessionFirstSeenKey(String deviceId) =>
      'no_session_first_seen:$deviceId';

  static Future<void> _processIncoming(
    String senderDeviceId,
    Map<String, dynamic> envelope,
    String? deliveryId,
  ) async {
    try {
      if (envelope['type'] == _sessionResetType) {
        // Собеседник обнаружил у себя рассинхрон при чтении НАШИХ
        // сообщений и просит начать с чистого листа — стираем сессию,
        // наша следующая отправка ему сама поднимет новый X3DH.
        DebugLog.log(
          'Router session_reset received from=$senderDeviceId — clearing local session state',
        );
        await SessionStore.clearState(senderDeviceId);
        await _clearFailureCount(senderDeviceId);
        if (deliveryId != null) {
          WebSocketService.instance.ackDelivery(deliveryId);
        }
        return;
      }

      var state = await SessionStore.getState(senderDeviceId);
      var isFreshSession = false;

      // Временное расширенное логирование расшифровки на период
      // closed-тестирования (см. обсуждение с пользователем) — снимаем
      // перед релизом в проде. Логируем только БЕЗОПАСНЫЕ метаданные:
      // публичные ключи ratchet (это Diffie-Hellman public key, не
      // секрет), номера сообщений, счётчики — НИКОГДА rootKey/chain key/
      // message key и уж тем более текст сообщения.
      DebugLog.log(
        'Router decrypt-attempt from=$senderDeviceId '
        'hadLocalSession=${state != null} '
        'envelopeHasX3dhInit=${envelope['ephemeral_pubkey'] != null} '
        'envelope.message_number=${envelope['message_number']} '
        'envelope.ratchet_pubkey=${envelope['ratchet_pubkey']} '
        '${state != null ? _stateDebugInfo(state) : ''}',
      );

      if (state == null) {
        final fresh = await _establishFreshIncoming(senderDeviceId, envelope);
        if (fresh == null) {
          debugPrint(
            'MessageRouter: нет локальной сессии для senderDeviceId='
            '$senderDeviceId, а конверт не содержит данных для нового '
            'X3DH-хендшейка — сообщение отброшено, расшифровать нечем',
          );
          final gaveUp = await _giveUpIfNoSessionTooLong(senderDeviceId);
          DebugLog.log(
            'Router DROP from=$senderDeviceId reason=no-session-and-no-handshake'
            '${gaveUp ? ' (gave up — acking to stop redelivery loop)' : ''}',
          );
          if (gaveUp && deliveryId != null) {
            WebSocketService.instance.ackDelivery(deliveryId);
          }
          return;
        }
        await _clearNoSessionFirstSeen(senderDeviceId);
        DebugLog.log(
          'Router accepted fresh X3DH init from=$senderDeviceId (no prior session)',
        );
        state = fresh;
        isFreshSession = true;
      }

      String rawInner;
      try {
        final messageKey = await state.nextReceivingKey(envelope);
        rawInner = await decryptMessage(messageKey, envelope);
      } on AlreadyProcessedException catch (e) {
        // Безобидный дубль (повторная доставка уже расшифрованного
        // сообщения, например после реконнекта) — сама сессия здорова,
        // просто подтверждаем и молча игнорируем. Ни в коем случае не
        // считаем это как decrypt-failure: иначе burst дублей после
        // реконнекта (см. лог пользователя) сносит рабочую сессию и
        // собеседник перестаёт доходить на много часов.
        DebugLog.log(
          'Router IGNORING duplicate from=$senderDeviceId $e — session untouched',
        );
        if (deliveryId != null) {
          WebSocketService.instance.ackDelivery(deliveryId);
        }
        return;
      } catch (e) {
        // Расшифровка с текущим состоянием не удалась — если конверт
        // всё же несёт валидные X3DH-поля (собеседник уже сам поднял
        // свежую сессию, а мы этого не заметили, потому что у нас
        // формально "было" старое состояние), пробуем принять её как
        // новую и повторить один раз, прежде чем считать это неудачей.
        DebugLog.log(
          'Router decrypt-FAILED from=$senderDeviceId error=$e '
          'isFreshSession=$isFreshSession '
          'envelope.message_number=${envelope['message_number']} '
          'envelope.ratchet_pubkey=${envelope['ratchet_pubkey']} '
          '${_stateDebugInfo(state)} — trying fallback fresh-session establish',
        );
        final fresh = isFreshSession
            ? null
            : await _establishFreshIncoming(senderDeviceId, envelope);
        if (fresh == null) {
          DebugLog.log(
            'Router decrypt-FAILED from=$senderDeviceId — no fallback available '
            '(envelope carries no X3DH init fields, or session was already fresh)',
          );

          // Конверт зашифрован под ratchet-ключом, ОТЛИЧНЫМ от текущего
          // ключа нашей принимающей цепочки — это не признак поломки
          // сессии, а нормальное, ожидаемое явление: сообщение безвозвратно
          // устарело (типично — сервер повторно доставляет то, что мы уже
          // давно обогнали, см. startPendingMessageSweeper на сервере,
          // который раз в 20с дожимает всё ещё не подтверждённое). Разбор
          // реального теста показал: именно ОДНО такое "залежавшееся"
          // сообщение, приходя заново каждые ~20с, за несколько таких
          // повторов набирало _resetFailureThreshold и роняло ВСЮ сессию —
          // включая принимающую цепочку, которая в этот же момент штатно
          // расшифровывала другие, свежие сообщения. Хуже того: сброс шлёт
          // собеседнику просьбу тоже стереть у себя сессию — а у него в
          // этот момент могли быть сообщения "в полёте", зашифрованные под
          // ещё-живым (для него) состоянием, что запускало ту же цепочку
          // уже в обратную сторону — самоподдерживающийся шторм взаимных
          // сбросов на много минут (лог пользователя — 6+ последовательных
          // авто-сбросов подряд).
          //
          // Правильное поведение (как у настоящего Double Ratchet — старые
          // "просроченные" сообщения, чей message key вышел за пределы окна
          // skipped-keys, просто необратимо теряются, это штатно): сдаться
          // СРАЗУ по этой конкретной доставке, не трогая счётчик и не
          // трогая сессию вообще. Auto-reset остаётся только для
          // по-настоящему тревожного случая — расшифровка проваливается на
          // ТЕКУЩЕМ (актуальном) ключе цепочки, а не на устаревшем чужом.
          final incomingKeyB64 = envelope['ratchet_pubkey'] as String?;
          final currentKeyB64 = state.receivingRatchetPublicKey != null
              ? base64Encode(state.receivingRatchetPublicKey!)
              : null;
          final isStaleRatchetKey =
              incomingKeyB64 != null &&
              currentKeyB64 != null &&
              incomingKeyB64 != currentKeyB64;
          if (isStaleRatchetKey) {
            DebugLog.log(
              'Router giving up on stale-ratchet-key delivery from=$senderDeviceId '
              '(envelope ratchet_pubkey=$incomingKeyB64 differs from current '
              'session key=$currentKeyB64 — normal for an already-superseded '
              'redelivery, session left untouched, not counted toward reset)',
            );
            if (deliveryId != null) {
              WebSocketService.instance.ackDelivery(deliveryId);
            }
            return;
          }

          await _onDecryptFailure(senderDeviceId, deliveryId);
          rethrow;
        }
        DebugLog.log(
          'Router recovered via fresh X3DH init from=$senderDeviceId after decrypt failure',
        );
        final messageKey = await fresh.nextReceivingKey(envelope);
        rawInner = await decryptMessage(messageKey, envelope);
        state = fresh;
      }

      await _clearFailureCount(senderDeviceId);
      await _clearNoSessionFirstSeen(senderDeviceId);
      await SessionStore.saveState(senderDeviceId, state);

      final inner = InnerMessage.decode(rawInner);
      DebugLog.log(
        'Router decrypted from=$senderDeviceId type=${inner.type} messageId=${inner.messageId}',
      );
      final ownerInfo = await _resolveOwner(senderDeviceId);
      if (ownerInfo == null) {
        DebugLog.log(
          'Router DROP from=$senderDeviceId reason=resolve-owner-failed',
        );
        return;
      }

      final chatIsOpen = ActiveChatTracker.currentPeerLogin == ownerInfo.login;

      if (inner.type == 'text') {
        await ChatStore.addMessage(
          ownerInfo.login,
          StoredMessage(
            inner.messageId,
            inner.body,
            false,
            inner.sentAt,
            groupId: inner.groupId,
            replyToMessageId: inner.replyToMessageId,
            replyToPreview: inner.replyToPreview,
          ),
          accountId: ownerInfo.accountId,
          incrementUnread: !chatIsOpen,
        );
      } else if (inner.type == 'media') {
        final mediaInfo = jsonDecode(inner.body) as Map<String, dynamic>;
        final isFile = mediaInfo['is_file'] as bool? ?? false;
        final isVideo = mediaInfo['is_video'] as bool? ?? false;
        final fileName = mediaInfo['file_name'] as String;
        final fileSize = mediaInfo['file_size'] as int? ?? 0;
        final chunked = mediaInfo['chunked'] as bool? ?? false;
        final spoiler = mediaInfo['spoiler'] as bool? ?? false;

        await ChatStore.addMessage(
          ownerInfo.login,
          StoredMessage(
            inner.messageId,
            isFile ? fileName : (isVideo ? '🎬 Видео' : '📷 Фото'),
            false,
            inner.sentAt,
            isMedia: true,
            isFile: isFile,
            isVideo: isVideo,
            fileSize: fileSize,
            chunked: chunked,
            isSpoiler: spoiler,
            mediaId: mediaInfo['media_id'] as String,
            mediaKeyBase64: mediaInfo['key'] as String,
            mediaNonceBase64: mediaInfo['nonce'] as String?,
            mediaMacBase64: mediaInfo['mac'] as String?,
            fileName: fileName,
            groupId: inner.groupId,
            replyToMessageId: inner.replyToMessageId,
            replyToPreview: inner.replyToPreview,
          ),
          accountId: ownerInfo.accountId,
          incrementUnread: !chatIsOpen,
        );
      } else if (inner.type == 'voice' || inner.type == 'video_note') {
        final info = jsonDecode(inner.body) as Map<String, dynamic>;
        final isVideoNote = inner.type == 'video_note';
        await ChatStore.addMessage(
          ownerInfo.login,
          StoredMessage(
            inner.messageId,
            isVideoNote ? '🎥 Видеосообщение' : '🎤 Голосовое сообщение',
            false,
            inner.sentAt,
            isMedia: true,
            isVoice: !isVideoNote,
            isVideoNote: isVideoNote,
            fileSize: info['file_size'] as int? ?? 0,
            chunked: info['chunked'] as bool? ?? false,
            durationMs: info['duration_ms'] as int?,
            mediaId: info['media_id'] as String,
            mediaKeyBase64: info['key'] as String,
            mediaNonceBase64: info['nonce'] as String?,
            mediaMacBase64: info['mac'] as String?,
            groupId: inner.groupId,
            replyToMessageId: inner.replyToMessageId,
            replyToPreview: inner.replyToPreview,
          ),
          accountId: ownerInfo.accountId,
          incrementUnread: !chatIsOpen,
        );
      } else if (inner.type == 'media_group') {
        final groupInfo = jsonDecode(inner.body) as Map<String, dynamic>;
        final caption = groupInfo['caption'] as String?;
        final textMessageId = groupInfo['text_message_id'] as String?;
        final filesRaw = (groupInfo['files'] as List<dynamic>)
            .cast<Map<String, dynamic>>();

        final newMessages = <StoredMessage>[];
        if (caption != null && caption.isNotEmpty && textMessageId != null) {
          newMessages.add(
            StoredMessage(
              textMessageId,
              caption,
              false,
              inner.sentAt,
              groupId: inner.groupId,
            ),
          );
        }
        for (final f in filesRaw) {
          final isFile = f['is_file'] as bool? ?? false;
          final isVideo = f['is_video'] as bool? ?? false;
          final fileName = f['file_name'] as String;
          newMessages.add(
            StoredMessage(
              f['message_id'] as String,
              isFile ? fileName : (isVideo ? '🎬 Видео' : '📷 Фото'),
              false,
              inner.sentAt,
              isMedia: true,
              isFile: isFile,
              isVideo: isVideo,
              fileSize: f['file_size'] as int? ?? 0,
              chunked: f['chunked'] as bool? ?? false,
              isSpoiler: f['spoiler'] as bool? ?? false,
              mediaId: f['media_id'] as String,
              mediaKeyBase64: f['key'] as String,
              mediaNonceBase64: f['nonce'] as String?,
              mediaMacBase64: f['mac'] as String?,
              fileName: fileName,
              groupId: inner.groupId,
            ),
          );
        }

        await ChatStore.addMessages(
          ownerInfo.login,
          newMessages,
          accountId: ownerInfo.accountId,
          incrementUnread: !chatIsOpen,
        );
      } else if (inner.type == 'call_missed') {
        // Собеседник звонил, пока мы были офлайн, и call_offer до нас в
        // реальном времени не дошёл — это подстраховочное уведомление, дошедшее
        // через обычную очередь offline-доставки, а не через сигналы звонка.
        final callInfo = jsonDecode(inner.body) as Map<String, dynamic>;
        final calledAt = callInfo['called_at'] as int? ?? inner.sentAt;
        await ChatStore.addCallLog(
          ownerInfo.login,
          direction: 'incoming',
          outcome: 'missed',
          timestamp: calledAt,
          accountId: ownerInfo.accountId,
          incrementUnread: !chatIsOpen,
          callId: callInfo['call_id'] as String?,
        );
      } else if (inner.type == 'reaction') {
        // Реакция от собеседника — с НАШЕЙ стороны это всегда "peer"-реакция,
        // независимо от того, кто автор самого сообщения, на которое она стоит.
        final data = jsonDecode(inner.body) as Map<String, dynamic>;
        final targetId = data['target_id'] as String?;
        if (targetId != null) {
          final newEmoji = data['emoji'] as String?;
          await ChatStore.setReaction(
            ownerInfo.login,
            targetId,
            isMine: false,
            emoji: newEmoji,
          );
          // Только реальная простановка (не снятие) заслуживает анимации —
          // см. incomingReactions выше.
          if (newEmoji != null) {
            _reactionController.add((
              peerLogin: ownerInfo.login,
              messageId: targetId,
            ));
          }
          // Виброотклик на чужую реакцию — только если мы прямо сейчас
          // смотрим именно в этот чат (иначе непонятно, по какому поводу
          // телефон дёрнулся, если мы вообще не видим этот пузырь).
          if (chatIsOpen) HapticFeedback.vibrate();
        }
      } else if (inner.type == 'pin') {
        final data = jsonDecode(inner.body) as Map<String, dynamic>;
        final targetId = data['target_id'] as String?;
        final pinned = data['pinned'] as bool? ?? false;
        await ChatStore.setPinned(ownerInfo.login, pinned ? targetId : null);
      } else if (inner.type == 'edit') {
        final data = jsonDecode(inner.body) as Map<String, dynamic>;
        final targetId = data['target_id'] as String?;
        final newText = data['text'] as String?;
        if (targetId != null && newText != null) {
          await ChatStore.editMessageText(ownerInfo.login, targetId, newText);
        }
      } else if (inner.type == 'delete') {
        final data = jsonDecode(inner.body) as Map<String, dynamic>;
        final targetIds =
            (data['target_ids'] as List<dynamic>?)?.cast<String>() ?? const [];
        // ДО удаления — пока пузыри ещё реально в хранилище (и, если чат
        // открыт, ещё смонтированы в дереве виджетов), см. incomingDeletes.
        if (targetIds.isNotEmpty) {
          _incomingDeleteController.add((
            peerLogin: ownerInfo.login,
            targetIds: targetIds,
          ));
        }
        // Снимок ДО удаления — та же логика, что и у локального удаления в
        // ChatScreen (см. purgeMessageArtifacts, ТЗ пользователя: удаление —
        // полный сброс, без следов в кэше/очередях), просто здесь источник
        // удаления — собеседник, а не сам пользователь.
        final allMessages = await ChatStore.getMessages(ownerInfo.login);
        final toPurge = allMessages
            .where((m) => targetIds.contains(m.messageId))
            .toList();
        await ChatStore.deleteMessages(ownerInfo.login, targetIds);
        await purgeAllMessageArtifacts(toPurge);
      } else if (inner.type == 'clear_chat') {
        // Собеседник нажал "очистить историю" — безусловная команда стереть
        // у себя абсолютно всё содержимое чата (см. InnerMessage.clearChat),
        // без сверки по id. Сам чат в списке остаётся, просто пустым.
        final allMessages = await ChatStore.getMessages(ownerInfo.login);
        await ChatStore.clearHistory(ownerInfo.login);
        await purgeAllMessageArtifacts(allMessages);
      } else if (inner.type == 'delete_chat') {
        // Собеседник удалил у себя весь диалог с галочкой "у обоих" — у нас
        // тоже убираем сам чат из списка (см. InnerMessage.deleteChat), а не
        // просто оставляем его пустым, как после обычной очистки истории.
        final allMessages = await ChatStore.getMessages(ownerInfo.login);
        await ChatStore.removeChat(ownerInfo.login);
        await purgeAllMessageArtifacts(allMessages);
      } else if (inner.type == 'read_receipt') {
        // Собеседник подтверждает, что реально увидел перечисленные — это
        // НАШИ сообщения (targetIds всегда ссылаются на сообщения автора
        // квитанции, т.е. на нас), поэтому статус меняем без разбора
        // isMine, как и в остальных ветках выше.
        final data = jsonDecode(inner.body) as Map<String, dynamic>;
        final targetIds =
            (data['target_ids'] as List<dynamic>?)?.cast<String>() ?? const [];
        await ChatStore.markMessagesRead(ownerInfo.login, targetIds);
      }

      // Подтверждаем серверу доставку ТОЛЬКО теперь — конверт уже реально
      // расшифрован и сохранён (или осознанно ни во что не превратился,
      // как read_receipt/пустая реакция — тоже "обработано", ack честен).
      // Раньше ack уходил сразу по получении кадра, до этого места — любой
      // сбой ниже по цепочке (расшифровка, запись) означал, что сервер уже
      // считал сообщение доставленным и стирал его, а оно фактически терялось.
      if (deliveryId != null) {
        WebSocketService.instance.ackDelivery(deliveryId);
      }
      DebugLog.log(
        'Router OK from=$senderDeviceId type=${inner.type} messageId=${inner.messageId}',
      );

      // Реакция/пин/правка/удаление — служебные события, не самостоятельные
      // сообщения: не заслуживают звука, даже если чат закрыт (собеседник
      // увидит их, когда сам откроет чат — специально идти проверять их не
      // нужно). Замьюченный чат тоже не должен звучать — раньше эта
      // проверка тут отсутствовала: мьют реально гасил только push (когда
      // приложение закрыто/свёрнуто), а живое сообщение по уже открытому
      // WebSocket-соединению всё равно проигрывало звук.
      if (!chatIsOpen && !_silentTypes.contains(inner.type)) {
        final muted = await ChatStore.isChatMuted(ownerInfo.login);
        if (!muted) {
          SoundService.playMessageSound();
          // Приложение свёрнуто (но процесс жив, сообщение дошло по WS) —
          // показываем локальное уведомление. В foreground не показываем
          // (ТЗ пользователя): там пользователь и так в приложении.
          if (WidgetsBinding.instance.lifecycleState !=
              AppLifecycleState.resumed) {
            unawaited(showBackgroundMessageNotification());
          }
        }
      }
    } catch (e, stackTrace) {
      debugPrint('MessageRouter: ошибка обработки сообщения: $e\n$stackTrace');
      DebugLog.log(
        'Router FAILED from=$senderDeviceId deliveryId=${deliveryId ?? '-'} error=$e',
      );
    }
  }

  /// Только БЕЗОПАСНЫЕ для логов поля состояния сессии — публичный ключ
  /// ratchet собеседника (это Diffie-Hellman public key, не секрет) и
  /// голые счётчики/флаги. rootKey/chain key/message key — секретный
  /// материал, сюда никогда не попадают ни в каком виде.
  static String _stateDebugInfo(RatchetState state) {
    final peerPubkey = state.receivingRatchetPublicKey != null
        ? base64Encode(state.receivingRatchetPublicKey!)
        : 'null';
    return 'receiveMsgNum=${state.receiveMessageNumber} '
        'sendMsgNum=${state.sendMessageNumber} '
        'needsSendingRatchet=${state.needsSendingRatchet} '
        'receivingRatchetPubkey=$peerPubkey '
        'skippedKeys=${state.skippedReceivingKeys.keys.toList()}';
  }

  /// Пытается поднять входящую сессию с нуля из X3DH-полей конверта (если
  /// они там есть) — используется и когда локальной сессии вообще нет, и
  /// как fallback, когда расшифровка с уже имеющимся (рассинхронизированным)
  /// состоянием не удалась, но собеседник прислал свежий хендшейк.
  static Future<RatchetState?> _establishFreshIncoming(
    String senderDeviceId,
    Map<String, dynamic> envelope,
  ) async {
    final rootKey = await establishIncomingSessionRaw(envelope);
    if (rootKey == null) return null;
    final newIdentityDh = envelope['sender_identity_dh_pubkey'] as String;
    // Только диагностика (см. ТЗ пользователя — максимальная надёжность и
    // безопасность X3DH/Double Ratchet): identity DH-ключ устройства в норме
    // не меняется за время его жизни (см. KeyStore.getOrCreateIdentityDhKeyPair
    // — генерируется один раз и хранится постоянно). Если для уже знакомого
    // device_id вдруг приходит ДРУГОЙ identity-ключ, это либо переустановка
    // приложения тем же человеком (легитимно), либо подмена ключа кем-то
    // третьим (см. PeerIdentityStore — используется на экране "Проверка
    // ключей" для ручной сверки) — самостоятельно отличить одно от другого
    // здесь нельзя, но громко залогировать, чтобы это было видно при разборе
    // лога, можно и нужно. Сессию всё равно устанавливаем — жёсткая
    // блокировка тут менее приемлема (сломала бы легитимные переустановки),
    // чем "мы это хотя бы записали для дальнейшего расследования".
    final previous = await PeerIdentityStore.get(senderDeviceId);
    final previousIdentityDh = previous?['identity_dh'];
    if (previousIdentityDh != null && previousIdentityDh != newIdentityDh) {
      DebugLog.log(
        'Router SECURITY-WARNING identity_dh_pubkey CHANGED for from=$senderDeviceId '
        '— either a legitimate reinstall or a possible key substitution; '
        'session established anyway, verify via safety-number screen if unsure',
      );
    }
    await PeerIdentityStore.save(senderDeviceId, newIdentityDh);
    return RatchetState.initAsReceiver(
      rootKey: rootKey,
      remoteEphemeralPubkey: base64DecodeSafe(
        envelope['ephemeral_pubkey'] as String,
      ),
    );
  }

  /// Считает подряд идущие неудачные попытки расшифровки от одного
  /// отправителя — хранит счётчик на диске (а не просто в памяти
  /// процесса), потому что на свёрнутом приложении Android может убить и
  /// поднять процесс заново между двумя доставками (см. лог — "WS status
  /// -> connected" без предшествующего "connecting" — признак холодного
  /// старта): счётчик в оперативной памяти в этом случае каждый раз
  /// обнулялся бы, так и не доходя до порога.
  ///
  /// После нескольких подряд решаем, что сессия с этим отправителем
  /// рассинхронизирована навсегда (см. docstring в double_ratchet.dart:
  /// такое состояние само себя не чинит), сбрасываем её у себя и просим
  /// собеседника сделать то же самое, чтобы его следующая отправка сама
  /// подняла свежий X3DH.
  static Future<void> _onDecryptFailure(
    String senderDeviceId,
    String? deliveryId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final countKey = _failureCountKey(senderDeviceId);
    final count = (prefs.getInt(countKey) ?? 0) + 1;
    await prefs.setInt(countKey, count);
    DebugLog.log(
      'Router decrypt-failure-count from=$senderDeviceId count=$count',
    );
    if (count < _resetFailureThreshold) return;

    // Дальше отступать некуда — конкретно ЭТО сообщение зашифровано
    // цепочкой, которую мы уже не расшифруем, даже после сброса сессии
    // ниже (сброс лечит будущие сообщения, а не то, что уже зашифровано
    // мёртвым ключом). Подтверждаем его серверу, чтобы оно не приходило
    // заново при каждом переподключении бесконечно.
    if (deliveryId != null) {
      WebSocketService.instance.ackDelivery(deliveryId);
      DebugLog.log(
        'Router giving up on undecryptable delivery=$deliveryId from=$senderDeviceId',
      );
    }

    final lastRequestKey = _lastResetKey(senderDeviceId);
    final lastRequestMs = prefs.getInt(lastRequestKey);
    final now = DateTime.now();
    if (lastRequestMs != null &&
        now.difference(DateTime.fromMillisecondsSinceEpoch(lastRequestMs)) <
            _resetCooldown) {
      return;
    }
    await prefs.setInt(lastRequestKey, now.millisecondsSinceEpoch);

    DebugLog.log(
      'Router auto session-reset triggered for=$senderDeviceId after $count consecutive decrypt failures',
    );
    await resetSessionWith(
      senderDeviceId,
      reason: 'auto ($count decrypt failures)',
    );
  }

  /// Стирает локальную сессию Double Ratchet с этим устройством и просит
  /// собеседника сделать то же самое — единая точка и для автоматического
  /// самолечения (см. _onDecryptFailure выше — 3 подряд неудачи
  /// расшифровки), и для ручного действия пользователя ("Сбросить
  /// шифрование" в меню чата, см. chat_screen.dart), и для полной очистки
  /// истории/чата "у обоих" (см. ChatScreen._deleteMessages/
  /// HomePlaceholderScreen — ТЗ пользователя: раз уже стираем всё
  /// содержимое с обеих сторон, разумно заодно гарантированно начать и
  /// шифрование с чистого листа, а не полагаться на то, что старая сессия
  /// и так была здорова).
  static Future<void> resetSessionWith(
    String deviceId, {
    required String reason,
  }) async {
    DebugLog.log('Router resetSessionWith device=$deviceId reason=$reason');
    await SessionStore.clearState(deviceId);
    await _sendSessionReset(deviceId);
  }

  static Future<void> _clearFailureCount(String senderDeviceId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_failureCountKey(senderDeviceId));
  }

  /// Публичные обёртки над _onDecryptFailure/_clearFailureCount — см.
  /// CallService._decryptCallSignal. Раньше сигналы звонка сознательно НЕ
  /// участвовали в этом счётчике (комментарий там объяснял: "сессия общая
  /// с обычными сообщениями, самолечение уже покрыто здесь"). На практике
  /// это предположение подвело: реальный кейс — рассинхронизированная
  /// сессия ловится именно на call_offer (SecretBoxAuthenticationError,
  /// "wrong MAC"), а если между этими двумя устройствами в этот момент
  /// почти не идёт обычная переписка (например, тестируют именно звонки),
  /// счётчик обычных сообщений никогда не набирает порог — звонок
  /// оказывается обречён биться в мёртвую сессию бесконечно, никакого
  /// самолечения так и не происходит. Deliver-id тут всегда null — ack за
  /// сам конверт call_offer уже отправлен раньше, безусловно, в
  /// websocket_service.dart (см. комментарий там), второй раз это делать
  /// не нужно.
  static Future<void> reportSignalDecryptFailure(String senderDeviceId) =>
      _onDecryptFailure(senderDeviceId, null);

  static Future<void> reportSignalDecryptSuccess(String senderDeviceId) =>
      _clearFailureCount(senderDeviceId);

  /// true, если пора сдаться и подтвердить эту доставку серверу, а не ждать
  /// снова. Первый раз просто запоминает момент — ничего не подтверждает,
  /// давая шанс гонке доставки разрешиться самой (см. _noSessionGiveUpDelay
  /// выше). Молчаливо переживает перезапуск процесса — счётчик в
  /// SharedPreferences, а не в памяти, по той же причине, что и у
  /// decrypt-failure-count (см. _onDecryptFailure).
  static Future<bool> _giveUpIfNoSessionTooLong(String senderDeviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _noSessionFirstSeenKey(senderDeviceId);
    final firstSeenMs = prefs.getInt(key);
    final now = DateTime.now();
    if (firstSeenMs == null) {
      await prefs.setInt(key, now.millisecondsSinceEpoch);
      return false;
    }
    return now.difference(DateTime.fromMillisecondsSinceEpoch(firstSeenMs)) >
        _noSessionGiveUpDelay;
  }

  static Future<void> _clearNoSessionFirstSeen(String senderDeviceId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_noSessionFirstSeenKey(senderDeviceId));
  }

  static Future<void> _sendSessionReset(String toDeviceId) async {
    final myDeviceId = await KeyStore.getStoredDeviceId();
    if (myDeviceId == null) return;
    final envelope = <String, dynamic>{
      'type': _sessionResetType,
      'sender_device_id': myDeviceId,
    };
    await SendQueueProcessor.instance.enqueue(
      toDeviceId: toDeviceId,
      envelope: envelope,
      deliveryId: _uuid.v4(),
      silent: true,
    );
  }

  // device_id → владелец не меняется на протяжении жизни устройства (модель
  // "1 аккаунт = 1 устройство", см. OSHINOBU_OVERVIEW.md) — раньше каждое
  // ВХОДЯЩЕЕ событие (текст, реакция, правка, удаление и т.д.) сначала ждало
  // полный HTTP round-trip на /devices/{id}/owner, прежде чем вообще
  // применить его локально. При обоих собеседниках онлайн доставка через
  // WebSocket сама по себе почти мгновенна — именно это ожидание сети было
  // причиной заметной задержки (особенно бросалось в глаза на удалении,
  // где пользователь ждёт, что пузырь исчезнет сразу). Кэшируем результат:
  // сначала в памяти процесса (мгновенно на все последующие события до
  // перезапуска), затем на диске через PeerAccountStore (device_id →
  // account_id, уже используется в других местах) + известный логин из
  // списка чатов — и только если ни то, ни другое не помогло, идём в сеть.
  static final Map<
    String,
    ({String accountId, String login, String displayName})
  >
  _ownerCache = {};

  static Future<({String accountId, String login, String displayName})?>
  _resolveOwner(String deviceId) async {
    final cached = _ownerCache[deviceId];
    if (cached != null) return cached;

    final cachedAccountId = await PeerAccountStore.get(deviceId);
    if (cachedAccountId != null) {
      final peers = await ChatStore.getKnownPeers();
      final match = peers.where((p) => p.lastKnownAccountId == cachedAccountId);
      if (match.isNotEmpty) {
        // peerLogin тут — просто известный логин чата (ключ ChatStore), не
        // отображаемое имя: путь через кэш экономит сетевой запрос, но не
        // несёт displayName — подставляем login как разумный фолбэк
        // (реальное отображаемое имя резолвится отдельно там, где оно
        // реально показывается пользователю — PeerProfileCache).
        final resolved = (
          accountId: cachedAccountId,
          login: match.first.peerLogin,
          displayName: match.first.peerLogin,
        );
        _ownerCache[deviceId] = resolved;
        return resolved;
      }
    }

    final token = await Session.getToken();
    if (token == null) return null;
    final resolved = await ApiClient().getDeviceOwnerInfo(token, deviceId);
    if (resolved != null) {
      _ownerCache[deviceId] = resolved;
      unawaited(PeerAccountStore.save(deviceId, resolved.accountId));
    }
    return resolved;
  }
}
