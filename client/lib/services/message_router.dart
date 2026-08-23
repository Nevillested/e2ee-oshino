import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
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
          DebugLog.log(
            'Router DROP from=$senderDeviceId reason=no-session-and-no-handshake',
          );
          return;
        }
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
        final fileName = mediaInfo['file_name'] as String;
        final fileSize = mediaInfo['file_size'] as int? ?? 0;
        final chunked = mediaInfo['chunked'] as bool? ?? false;

        await ChatStore.addMessage(
          ownerInfo.login,
          StoredMessage(
            inner.messageId,
            isFile ? fileName : '📷 Фото',
            false,
            inner.sentAt,
            isMedia: true,
            isFile: isFile,
            fileSize: fileSize,
            chunked: chunked,
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
          final fileName = f['file_name'] as String;
          newMessages.add(
            StoredMessage(
              f['message_id'] as String,
              isFile ? fileName : '📷 Фото',
              false,
              inner.sentAt,
              isMedia: true,
              isFile: isFile,
              fileSize: f['file_size'] as int? ?? 0,
              chunked: f['chunked'] as bool? ?? false,
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
        await ChatStore.deleteMessages(ownerInfo.login, targetIds);
      } else if (inner.type == 'clear_chat') {
        // Собеседник нажал "очистить историю" — безусловная команда стереть
        // у себя абсолютно всё содержимое чата (см. InnerMessage.clearChat),
        // без сверки по id. Сам чат в списке остаётся, просто пустым.
        await ChatStore.clearHistory(ownerInfo.login);
      } else if (inner.type == 'delete_chat') {
        // Собеседник удалил у себя весь диалог с галочкой "у обоих" — у нас
        // тоже убираем сам чат из списка (см. InnerMessage.deleteChat), а не
        // просто оставляем его пустым, как после обычной очистки истории.
        await ChatStore.removeChat(ownerInfo.login);
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
        if (!muted) SoundService.playMessageSound();
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
    await PeerIdentityStore.save(
      senderDeviceId,
      envelope['sender_identity_dh_pubkey'] as String,
    );
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
    await SessionStore.clearState(senderDeviceId);
    await _sendSessionReset(senderDeviceId);
  }

  static Future<void> _clearFailureCount(String senderDeviceId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_failureCountKey(senderDeviceId));
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
  static final Map<String, ({String accountId, String login})> _ownerCache =
      {};

  static Future<({String accountId, String login})?> _resolveOwner(
    String deviceId,
  ) async {
    final cached = _ownerCache[deviceId];
    if (cached != null) return cached;

    final cachedAccountId = await PeerAccountStore.get(deviceId);
    if (cachedAccountId != null) {
      final peers = await ChatStore.getKnownPeers();
      final match = peers.where((p) => p.lastKnownAccountId == cachedAccountId);
      if (match.isNotEmpty) {
        final resolved = (
          accountId: cachedAccountId,
          login: match.first.peerLogin,
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
