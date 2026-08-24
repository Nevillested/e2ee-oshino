import 'dart:async';
import 'dart:convert';
import 'package:call_ring_plugin/call_ring_plugin.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:proximity_sensor/proximity_sensor.dart';
import 'package:uuid/uuid.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../crypto/double_ratchet.dart';
import '../crypto/key_store.dart';
import '../crypto/message_cipher.dart';
import '../crypto/message_envelope.dart';
import '../crypto/session_store.dart';
import '../crypto/x3dh.dart';
import '../l10n/app_strings.dart';
import 'websocket_service.dart';
import '../api/api_client.dart';
import '../session.dart';
import '../navigator_key.dart';
import '../screens/call_screen.dart';
import '../storage/chat_store.dart';
import '../storage/peer_account_store.dart';
import '../storage/peer_identity_store.dart';
import 'debug_log.dart';
import 'peer_messenger.dart';
import 'peer_profile_cache.dart';
import 'pip_service.dart';
import 'send_lock.dart';
import 'sound_service.dart';

enum CallState { idle, outgoingRinging, incomingRinging, connected, ended }

// Эмитится только для звонков, требующих ручного выбора "принять/отклонить"
// — автопринятые (кнопка "Ответить" в push-уведомлении) CallService
// открывает сам, напрямую (см. _autoAcceptAndOpenScreen).
class IncomingCallInfo {
  final String callId;
  final String peerDeviceId;
  IncomingCallInfo(this.callId, this.peerDeviceId);
}

class CallService {
  CallService._internal();
  static final CallService instance = CallService._internal();

  static const _uuid = Uuid();

  Map<String, dynamic> _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };

  Future<void> _refreshIceServers() async {
    final token = await Session.getToken();
    if (token == null) return;
    final creds = await ApiClient().getTurnCredentials(token);
    if (creds == null) return;

    _iceServers = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {
          'urls': creds['urls'],
          'username': creds['username'],
          'credential': creds['password'],
        },
      ],
    };
  }

  RTCPeerConnection? _peerConnection;
  MediaStream? localStream;
  MediaStreamTrack? _videoTrack;

  String? _callId;
  String? _peerDeviceId;
  String? _pendingOfferSdp;
  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];

  // Для записи звонка в историю чата: когда начался, когда (если вообще)
  // соединился, и кто был инициатором — с чьей стороны это устройство.
  DateTime? _callStartedAt;
  DateTime? _connectedAt;
  bool _isOutgoingCall = false;

  /// Момент реального ответа на звонок — источник истины для счётчика
  /// длительности на экране звонка и для лога звонка в чате (везде, где
  /// фиксируется длительность, она считается именно от этого момента).
  DateTime? get connectedAt => _connectedAt;

  // Затемнение экрана датчиком приближения — только пока разговор идёт
  // через ушной динамик (не через громкую связь).
  StreamSubscription<int>? _proximitySub;
  bool _proximityScreenOffActive = false;
  bool? _proximitySensorAvailable;

  // На видеозвонке экран гаснет по обычному системному таймауту — на
  // видео просто смотрят, не касаясь экрана, и ОС (особенно агрессивно —
  // на Samsung) гасит его как при простое. WakelockPlus держит экран
  // включённым ровно пока есть смысл на него смотреть — своё видео или
  // видео собеседника — и отпускает его сразу же, как только оба видео
  // выключены или разговор закончился, не мешая ни обычному энергосбережению
  // вне звонков, ни датчику приближения на чисто голосовых звонках (см.
  // _updateProximityScreenOff — тот работает по своему, не пересекающемуся
  // условию: только когда видео НЕТ и разговор не на громкой связи).
  bool _wakelockActive = false;

  final _stateController = StreamController<CallState>.broadcast();
  final _incomingCallController =
      StreamController<IncomingCallInfo>.broadcast();
  final _remoteStreamController = StreamController<MediaStream?>.broadcast();

  /// Текущий поток собеседника — храним отдельным полем, а не только шлём
  /// через remoteStreamUpdates: это broadcast-стрим, и он НЕ повторяет уже
  /// прошедшие события новым подписчикам. CallScreen может быть уничтожен и
  /// пересоздан несколько раз за один звонок (например, свернули в PiP и
  /// развернули обратно) — новый экземпляр подписывается на стрим уже ПОСЛЕ
  /// того, как поток пришёл, и без этого поля остался бы без видео,
  /// молча ожидая событие, которое никогда не повторится.
  MediaStream? _remoteStream;
  MediaStream? get remoteStream => _remoteStream;

  /// Человекочитаемые шаги установки соединения (обмен ключами/кандидатами
  /// WebRTC и т.п.) — показываются на экране разговора, пока он открыт уже
  /// (сразу по нажатию), а самого соединения ещё нет, чтобы не выглядело,
  /// будто приложение просто зависло.
  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusUpdates => _statusController.stream;
  String status = '';

  void _setStatus(String message) {
    status = message;
    _statusController.add(message);
  }

  /// Логин собеседника текущего звонка — CallScreen выставляет его при
  /// открытии, чтобы уведомление и системный PiP (SystemPipVideoView) могли
  /// показать имя, не имея собственного BuildContext/навигации.
  String? currentPeerLogin;

  /// account_id собеседника — тем же принципом, что и currentPeerLogin выше:
  /// нужен _openCallScreen(), чтобы пересобрать CallScreen (с фото
  /// профиля) при повторном открытии из PiP/уведомления, когда исходный
  /// вызывающий виджет (ChatScreen/IncomingCallScreen) уже не на сцене.
  String? currentPeerAccountId;

  /// true, пока CallScreen реально смонтирован (пользователь на экране
  /// разговора). НЕ то же самое, что "звонок активен" — звонок может
  /// продолжаться (см. CallState), пока пользователь ушёл в другой экран
  /// приложения (список чатов и т.п.).
  bool isCallScreenVisible = false;
  final _callScreenVisibilityController = StreamController<bool>.broadcast();
  Stream<bool> get callScreenVisibilityUpdates =>
      _callScreenVisibilityController.stream;

  void setCallScreenVisible(bool visible) {
    isCallScreenVisible = visible;
    _callScreenVisibilityController.add(visible);
  }

  /// true, пока Activity реально находится в настоящем системном
  /// Picture-in-Picture (см. MainActivity.kt/PipService) — плавающее окошко
  /// видно поверх ВСЕЙ системы (домашний экран, другие приложения), а не
  /// только внутри нашего приложения.
  bool isInSystemPip = false;
  final _systemPipController = StreamController<bool>.broadcast();
  Stream<bool> get systemPipUpdates => _systemPipController.stream;

  /// Реагирует на смену системного PiP-режима — единственное место, которое
  /// решает, нужно ли (пере)открыть CallScreen. Слушается один раз в
  /// startListening(), а не в самом CallScreen/SystemPipVideoView, ровно по
  /// той же причине, что и остальная логика в этом файле: экран может быть
  /// не смонтирован в момент события.
  void _handlePipModeChange(PipModeEvent event) {
    isInSystemPip = event.isInPip;
    _systemPipController.add(event.isInPip);

    if (event.isInPip) {
      // Вошли в PiP (вручную кнопкой или автоматически при сворачивании
      // из-за видео собеседника) — прячем CallScreen, чтобы после выхода
      // из PiP через открытие приложения (см. ветку reopen ниже)
      // пользователь увидел обычное приложение, а не экран звонка.
      if (isCallScreenVisible) {
        final nav = rootNavigatorKey.currentState;
        if (nav != null && nav.canPop()) nav.pop();
      }
      return;
    }

    switch (event.exitReason) {
      case PipExitReason.expand:
        // Развернули PiP его собственной кнопкой — возвращаем полноэкранный
        // экран разговора.
        _openCallScreen();
        break;
      case PipExitReason.reopen:
      case null:
        // Приложение открыли заново (лаунчер/недавние) или причина
        // неизвестна — оставляем как есть: пользователь видит обычное
        // приложение, звонок продолжается в фоне, вернуться на экран
        // разговора можно через уведомление "Идёт разговор".
        break;
    }
  }

  /// Сигнал о том, включена ли камера у СОБЕСЕДНИКА прямо сейчас.
  bool remoteVideoEnabled = false;

  /// Разовое автопереключение на громкую связь при первом появлении видео
  /// у собеседника — не должно срабатывать повторно за этот же звонок,
  /// если пользователь потом сам вернётся на ушной динамик.
  bool _autoSpeakerTriggered = false;
  final _remoteVideoStateController = StreamController<bool>.broadcast();
  Stream<bool> get remoteVideoStateUpdates =>
      _remoteVideoStateController.stream;

  Stream<CallState> get stateStream => _stateController.stream;
  Stream<IncomingCallInfo> get incomingCalls => _incomingCallController.stream;
  Stream<MediaStream?> get remoteStreamUpdates =>
      _remoteStreamController.stream;

  CallState _state = CallState.idle;
  CallState get state => _state;

  bool micEnabled = true;
  bool videoEnabled = false;
  bool speakerOn = false;

  bool _listenerStarted = false;

  // true, если пользователь нажал "Ответить" прямо в уведомлении о
  // звонке — ближайший (или уже идущий) входящий звонок нужно принять
  // автоматически, без повторного тапа уже на экране входящего вызова.
  bool _autoAcceptPending = false;

  void startListening() {
    if (_listenerStarted) return;
    _listenerStarted = true;
    WebSocketService.instance.callSignals.listen(_handleSignal);
    PipService.autoAcceptRequests.listen((_) => requestAutoAcceptNextCall());
    PipService.pipModeChanges.listen(_handlePipModeChange);
    // Тап по САМОМУ уведомлению "Идёт разговор" (не по кнопке) — открыть
    // экран разговора, если он сейчас не на виду.
    PipService.openCallScreenRequests.listen((_) {
      debugPrint(
        'CallService: openCallScreenRequests -> вызываю _openCallScreen()',
      );
      _openCallScreen();
    });
    // Кнопка "Завершить звонок" в том же уведомлении — см. подробное
    // объяснение у CallRingPlugin.endCallRequests, почему это не может идти
    // через flutter_local_notifications.
    CallRingPlugin.endCallRequests.listen((_) {
      debugPrint('CallService: endCallRequests получен -> вызываю endCall()');
      endCall();
    });
    // Кнопка "Отклонить" в уведомлении о ВХОДЯЩЕМ звонке, нажатая пока
    // приложение живо — см. подробное объяснение у
    // CallRingPlugin.declineCallRequests, почему одного HTTP-пути (для
    // офлайн-звонков) здесь недостаточно.
    CallRingPlugin.declineCallRequests.listen((_) {
      debugPrint(
        'CallService: declineCallRequests получен -> вызываю declineCall()',
      );
      declineCall();
    });
    debugPrint('CallService: startListening() — все подписки установлены');
  }

  /// Вызывается и при холодном старте (HomePlaceholderScreen опрашивает
  /// consumeAutoAccept() один раз при подключении), и "на горячую" — когда
  /// приложение уже было открыто, и MainActivity.onNewIntent толкает
  /// событие напрямую (см. PipService.autoAcceptRequests), поскольку
  /// HomePlaceholderScreen в этом случае не пересоздаётся и не спросит
  /// нативную сторону заново сама.
  void requestAutoAcceptNextCall() {
    debugPrint(
      'CallService: requestAutoAcceptNextCall() state=$_state pendingSdp=${_pendingOfferSdp != null}',
    );
    if (_state == CallState.incomingRinging &&
        _pendingOfferSdp != null &&
        _peerDeviceId != null) {
      // Звонок уже идёт (например, пользователь успел увидеть экран
      // входящего вызова до того, как нажал "Ответить" по уведомлению) —
      // принимаем прямо сейчас, а не ждём следующего call_offer.
      _autoAcceptAndOpenScreen(_peerDeviceId!);
    } else {
      _autoAcceptPending = true;
    }
  }

  /// Принимает звонок И сразу открывает экран разговора — используется
  /// ТОЛЬКО для автопринятия (кнопка "Ответить" в push-уведомлении).
  /// Раньше эта логика жила в HomePlaceholderScreen (через incomingCalls +
  /// проверку info.autoAccepted), но она срабатывала лишь для звонка,
  /// который приходит ПОСЛЕ запроса автопринятия — если звонок уже шёл
  /// (см. requestAutoAcceptNextCall выше), никто не открывал экран вообще.
  /// Централизовано здесь и работает единообразно в обоих случаях, через
  /// глобальный rootNavigatorKey (CallService не завязан на конкретный
  /// BuildContext).
  Future<void> _autoAcceptAndOpenScreen(String peerDeviceId) async {
    debugPrint(
      'CallService: _autoAcceptAndOpenScreen(peerDeviceId=$peerDeviceId) старт, '
      'currentPeerLogin=$currentPeerLogin, state=$_state',
    );
    if (currentPeerLogin == null) {
      await _resolvePeerLogin(peerDeviceId);
    }
    try {
      await acceptCall();
      debugPrint(
        'CallService: _autoAcceptAndOpenScreen: acceptCall() завершился, state=$_state',
      );
    } catch (e, st) {
      debugPrint('CallService: автоответ провалился: $e\n$st');
    }
    _openCallScreen();
  }

  Future<void> _resolvePeerLogin(String peerDeviceId) async {
    try {
      final token = await Session.getToken();
      if (token == null) {
        debugPrint(
          'CallService: _resolvePeerLogin: нет токена сессии, оставляю currentPeerLogin=null',
        );
        return;
      }
      final owner = await ApiClient().getDeviceOwnerInfo(token, peerDeviceId);
      if (owner != null) {
        currentPeerLogin = owner.login;
        currentPeerAccountId = owner.accountId;
        debugPrint('CallService: _resolvePeerLogin -> ${owner.login}');
      } else {
        debugPrint(
          'CallService: _resolvePeerLogin: getDeviceOwnerInfo вернул null для $peerDeviceId',
        );
      }
    } catch (e) {
      // Не критично — уведомление/пузырь используют запасной текст.
      debugPrint('CallService: _resolvePeerLogin провалился: $e');
    }
  }

  void _openCallScreen() {
    if (isCallScreenVisible) {
      debugPrint(
        'CallService: _openCallScreen: пропускаю — CallScreen уже на виду',
      );
      return;
    }
    final peerLogin = currentPeerLogin;
    if (peerLogin == null) {
      debugPrint(
        'CallService: _openCallScreen: пропускаю — currentPeerLogin==null, показывать нечего',
      );
      return;
    }
    final nav = rootNavigatorKey.currentState;
    debugPrint(
      'CallService: _openCallScreen: push CallScreen(peerLogin=$peerLogin), navigatorState=$nav',
    );
    nav?.push(
      MaterialPageRoute(
        builder: (_) => CallScreen(
          peerLogin: peerLogin,
          peerAccountId: currentPeerAccountId ?? '',
        ),
      ),
    );
  }

  void _setState(CallState s) {
    debugPrint('CallService: _setState: $_state -> $s');
    _state = s;
    _stateController.add(s);

    // Момент реального ответа — для caller это событие от WebRTC
    // (onConnectionState), для callee — оптимистичный переход сразу после
    // acceptCall(). В обоих случаях это единственный момент, когда
    // _setState(connected) вызывается, поэтому фиксируем длительность
    // именно здесь, один раз за звонок.
    if (s == CallState.connected && _connectedAt == null) {
      _connectedAt = DateTime.now();
    }

    // Уведомление "идёт разговор" живёт здесь, а не в CallScreen — экран
    // может быть закрыт (пользователь ушёл в другой чат), пока звонок
    // продолжается, и тогда именно CallService остаётся единственным, кто
    // гарантированно знает, что разговор закончился и уведомление пора
    // убрать.
    if (s == CallState.connected) {
      final fallbackName = currentPeerLogin ?? tr('call.otherParty');
      CallRingPlugin.showOngoingCallNotification(fallbackName);
      // Отображаемое имя (см. ТЗ пользователя — используется везде, где
      // раньше показывался login) резолвится асинхронно и обновляет уже
      // показанное уведомление, если/когда придёт — сперва показываем
      // login, чтобы уведомление не задерживалось ради сети.
      final accountId = currentPeerAccountId;
      final login = currentPeerLogin;
      if (accountId != null && accountId.isNotEmpty && login != null) {
        unawaited(
          PeerProfileCache.get(accountId, login).then((profile) {
            if (profile == null || _state != CallState.connected) return;
            if (profile.displayName != fallbackName) {
              CallRingPlugin.showOngoingCallNotification(profile.displayName);
            }
          }),
        );
      }
    } else if (s == CallState.idle) {
      CallRingPlugin.hideOngoingCallNotification();
    }

    // Автовход в PiP (при сворачивании ВСЕГО приложения) должен быть
    // доступен весь срок звонка целиком: и на дозвоне/установке соединения,
    // и уже во время разговора, и даже если пользователь ушёл с CallScreen
    // на список чатов, продолжая разговор в фоне. Поэтому завязано на
    // CallState, а не на то, смонтирован ли сейчас CallScreen.
    PipService.setCallActive(s != CallState.idle);

    // Затемнение датчиком приближения — та же логика: имеет смысл только
    // пока идёт реальный разговор.
    _updateProximityScreenOff();
    _updateWakelock();

    if (s == CallState.outgoingRinging) {
      SoundService.startRingback();
    } else {
      SoundService.stopRingback();
    }

    // Мелодия входящего звонка всегда идёт из ОДНОГО источника — нативного
    // CallRingService, а не из Dart-плеера. Раньше при "холодном" запуске
    // через push успевали ненадолго звучать оба независимых плеера
    // одновременно (нативный, разбудивший приложение, и Dart-овый, начатый
    // здесь) — обрыв и щелчок на стыке избежать было нельзя, синхронизировать
    // два независимых аудио-движка мы не можем, поэтому оставляем только
    // один — благо startRinging()/stopRinging() идемпотентны и одинаково
    // работают что при живом звонке (когда сервис ещё не поднят и стартует
    // прямо тут), что при уже разбуженном (тогда это просто no-op).
    if (s == CallState.incomingRinging) {
      CallRingPlugin.startRinging(callId: _callId);
    } else {
      CallRingPlugin.stopRinging();
    }
  }

  /// Включает/выключает "затемнение датчиком приближения" через
  /// нативный proximity wake lock Android (тот же механизм, что и у
  /// системного телефонного приложения) — работает только пока идёт
  /// разговор И звук идёт через ушной динамик, а не громкую связь: если
  /// телефон на громкой связи, его обычно кладут на стол экраном вверх,
  /// и гасить экран там не нужно и вредно.
  ///
  /// Важный нюанс самого плагина: setProximityScreenOff() только
  /// выставляет флаг на нативной стороне — реальный захват wake lock
  /// происходит внутри обработчика ПОДПИСКИ на поток events, поэтому флаг
  /// всегда нужно выставлять ДО подписки, и переподписываться заново
  /// при каждом включении (иначе повторный вызов с уже активной
  /// подпиской попросту ничего не делает).
  Future<void> _updateProximityScreenOff() async {
    final shouldEnable = _state == CallState.connected && !speakerOn;
    if (shouldEnable == _proximityScreenOffActive) return;

    if (shouldEnable) {
      _proximitySensorAvailable ??= await _checkProximityAvailable();
      if (_proximitySensorAvailable != true) return;
    }

    _proximityScreenOffActive = shouldEnable;
    try {
      if (shouldEnable) {
        await ProximitySensor.setProximityScreenOff(true);
        await _proximitySub?.cancel();
        _proximitySub = ProximitySensor.events.listen((_) {}, onError: (_) {});
      } else {
        await _proximitySub?.cancel();
        _proximitySub = null;
        await ProximitySensor.setProximityScreenOff(false);
      }
    } catch (_) {
      // Датчика нет/платформа не поддерживает — звонок это ломать не должно.
    }
  }

  /// Держит экран включённым, пока есть видео (своё или собеседника) в
  /// активном разговоре — см. комментарий у _wakelockActive.
  Future<void> _updateWakelock() async {
    final shouldEnable =
        _state == CallState.connected && (videoEnabled || remoteVideoEnabled);
    if (shouldEnable == _wakelockActive) return;
    _wakelockActive = shouldEnable;
    try {
      if (shouldEnable) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {
      // Платформа не поддерживает — разговор это ломать не должно.
    }
  }

  Future<bool> _checkProximityAvailable() async {
    try {
      return await ProximitySensor.isProximitySensorAvailable();
    } catch (_) {
      return false;
    }
  }

  /// SDP/ICE-кандидаты и остальное содержимое сигналов звонка шифруются
  /// той же Double Ratchet сессией, что и обычные сообщения этому
  /// устройству (см. _encryptCallSignal/_decryptCallSignal ниже) — раньше
  /// call_* кадры уходили ОТКРЫТЫМ текстом (см. websocket.go: сервер прямо
  /// разбирает их как plaintext JSON, чтобы достать call_id для своей
  /// офлайн-очереди звонков), и это был единственный канал в приложении,
  /// не покрытый E2EE. call_id и sender_device_id ОСТАЮТСЯ снаружи, в
  /// открытом виде — они и раньше были нужны серверу для маршрутизации
  /// (см. PendingCallRegistry на сервере) и сами по себе не раскрывают
  /// содержимое разговора (та же модель, что и sender/recipient device_id
  /// у обычных сообщений).
  Future<void> _send(String type, Map<String, dynamic> payload) async {
    if (_peerDeviceId == null) return;
    await _sendTo(_peerDeviceId!, type, payload, callId: _callId);
  }

  /// То же самое, что и _send, но для ЛЮБОГО устройства, а не только
  /// текущего собеседника по звонку — нужен для авто-ответа "занято"
  /// (case 'call_offer' ниже): это единственный сигнал звонка, который
  /// отправляется НЕ в рамках собственного _peerDeviceId/_callId этого
  /// экземпляра CallService (мы разговариваем с ОДНИМ человеком, а
  /// "занято" шлём ДРУГОМУ, только что позвонившему).
  Future<void> _sendTo(
    String toDeviceId,
    String type,
    Map<String, dynamic> payload, {
    String? callId,
  }) async {
    final envelope = await SendLock.run(
      toDeviceId,
      () => _encryptCallSignal(toDeviceId, {...payload, 'type': type}),
    );
    if (envelope == null) {
      DebugLog.log(
        'CallService _sendTo: encrypt-FAILED type=$type to=$toDeviceId, dropped',
      );
      return;
    }
    envelope['call_id'] = callId;
    WebSocketService.instance.sendCallSignal(toDeviceId, type, envelope);
  }

  /// Шифрует payload для одного конкретного сигнала звонка — та же схема,
  /// что и в services/peer_messenger.dart (X3DH при первом обращении к
  /// этому устройству + шаг Double Ratchet), но БЕЗ SendQueueProcessor:
  /// звонки намеренно не проходят через дисковую очередь офлайн-доставки
  /// (см. исходный комментарий у sendCallSignal в websocket_service.dart)
  /// — устаревший ICE-кандидат, переотправленный после того, как звонок
  /// уже закончился, был бы просто мусором. null — если зашифровать не
  /// удалось (нет сети для X3DH-бандла и т.п.); вызывающий код просто
  /// теряет этот конкретный кадр, как терял бы и раньше при недоступном
  /// соединении.
  Future<Map<String, dynamic>?> _encryptCallSignal(
    String peerDeviceId,
    Map<String, dynamic> innerPayload,
  ) async {
    try {
      final myDeviceId = await KeyStore.getStoredDeviceId();
      var state = await SessionStore.getState(peerDeviceId);
      Map<String, dynamic>? initHeader;

      if (state == null) {
        final token = await Session.getToken();
        if (token == null || myDeviceId == null) return null;
        final bundle = await ApiClient().getPrekeyBundle(token, peerDeviceId);
        await PeerAccountStore.save(
          peerDeviceId,
          bundle['account_id'] as String,
        );
        await PeerIdentityStore.save(
          peerDeviceId,
          bundle['identity_dh_pubkey'] as String,
        );
        final outgoing = await establishOutgoingRoot(
          bundle: bundle,
          myDeviceId: myDeviceId,
        );
        state = await RatchetState.initAsSender(
          rootKey: outgoing.rootKey,
          ephemeralKeyPair: outgoing.ephemeralKeyPair,
        );
        initHeader = outgoing.initHeader;
      }

      final next = await state.nextSendingKey();
      await SessionStore.saveState(peerDeviceId, state);
      final headerFields = <String, dynamic>{
        ...next.header,
        'sender_device_id': myDeviceId,
        if (initHeader != null) ...initHeader,
      };
      final encrypted = await encryptMessage(
        next.messageKey,
        jsonEncode(innerPayload),
        aad: headerFields,
      );
      return {...encrypted, ...headerFields};
    } catch (e) {
      DebugLog.log('CallService encrypt-FAILED to=$peerDeviceId error=$e');
      return null;
    }
  }

  /// Обратная сторона _encryptCallSignal. В отличие от MessageRouter (см.
  /// _onDecryptFailure там) НЕ заводит счётчик неудач/авто-сброс сессии на
  /// сбойной расшифровке — сигналы звонка терпимы к потере одного кадра
  /// (WebRTC и так рассчитан на потерю отдельных ICE-кандидатов), а если
  /// сессия с этим устройством реально рассинхронизировалась — это та же
  /// самая сессия, что и у обычных сообщений, и её самолечение (3 подряд
  /// неудачи → session_reset) уже покрыто message_router.dart, отдельно
  /// дублировать эту логику здесь незачем.
  Future<Map<String, dynamic>?> _decryptCallSignal(
    String senderDeviceId,
    Map<String, dynamic> envelope,
  ) async {
    try {
      var state = await SessionStore.getState(senderDeviceId);
      if (state == null) {
        final rootKey = await establishIncomingSessionRaw(envelope);
        if (rootKey == null) return null;
        final identityDh = envelope['sender_identity_dh_pubkey'] as String?;
        if (identityDh != null) {
          await PeerIdentityStore.save(senderDeviceId, identityDh);
        }
        state = await RatchetState.initAsReceiver(
          rootKey: rootKey,
          remoteEphemeralPubkey: base64DecodeSafe(
            envelope['ephemeral_pubkey'] as String,
          ),
        );
      }
      final messageKey = await state.nextReceivingKey(envelope);
      final rawInner = await decryptMessage(messageKey, envelope);
      await SessionStore.saveState(senderDeviceId, state);
      return jsonDecode(rawInner) as Map<String, dynamic>;
    } on AlreadyProcessedException catch (e) {
      DebugLog.log(
        'CallService duplicate signal from=$senderDeviceId $e — ignored',
      );
      return null;
    } catch (e) {
      DebugLog.log('CallService decrypt-FAILED from=$senderDeviceId error=$e');
      return null;
    }
  }

  Future<void> _createPeerConnection() async {
    await _refreshIceServers();
    _peerConnection = await createPeerConnection(_iceServers);

    _peerConnection!.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _send('call_ice', {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    _peerConnection!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
        _remoteStreamController.add(_remoteStream);
      }
    };

    _peerConnection!.onConnectionState = (connState) {
      if (connState == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _setState(CallState.connected);
      } else if (connState ==
          RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        endCall();
      }
    };

    // Срабатывает, когда мы добавляем/убираем дорожку (например, включаем
    // видео посреди разговора) — соединение уже установлено, поэтому
    // нужно провести повторное согласование (renegotiation), а не полный
    // новый звонок.
    _peerConnection!.onRenegotiationNeeded = () async {
      if (_state != CallState.connected) return;
      await _renegotiate();
    };
  }

  Future<void> _renegotiate() async {
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);
    await _send('call_offer', {'sdp': offer.sdp, 'renegotiation': true});
  }

  /// Открываем ТОЛЬКО микрофон при старте звонка — камера не трогается
  /// вообще, пока пользователь явно не нажмёт "включить видео". Раньше
  /// камера захватывалась всегда (даже для чисто голосового звонка), что
  /// на части устройств (замечено на Pixel 3) вызывало конфликт нативного
  /// слоя камеры с отрисовкой Flutter — короткая вспышка интерфейса и
  /// чёрный экран сразу после ответа на звонок.
  Future<void> _openLocalAudio() async {
    localStream = await navigator.mediaDevices.getUserMedia({'audio': true});
    for (final track in localStream!.getAudioTracks()) {
      track.enabled = micEnabled;
    }
    for (final track in localStream!.getTracks()) {
      await _peerConnection!.addTrack(track, localStream!);
    }

    // Явно фиксируем маршрут звука через ушной динамик сразу после
    // открытия микрофона — без этого Android иногда выбирает какой-то
    // промежуточный/гибридный маршрут по умолчанию, который звучит
    // непривычно, пока пользователь не переключит вывод звука вручную
    // (что как раз и заставляет систему выбрать маршрут заново явно).
    speakerOn = false;
    await Helper.setSpeakerphoneOn(false);
  }

  Future<void> startCall(String peerDeviceId) async {
    _callId = _uuid.v4();
    _peerDeviceId = peerDeviceId;
    micEnabled = true;
    videoEnabled = false;
    remoteVideoEnabled = false;
    _remoteDescriptionSet = false;
    _pendingRemoteCandidates.clear();
    _callStartedAt = DateTime.now();
    _connectedAt = null;
    _isOutgoingCall = true;

    _setState(CallState.outgoingRinging);
    _setStatus(tr('call.securingConnection'));

    await _createPeerConnection();
    _setStatus(tr('call.enablingMic'));
    await _openLocalAudio();

    _setStatus(tr('call.buildingOffer'));
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);

    _setStatus(tr('call.ringing'));
    await _send('call_offer', {'sdp': offer.sdp});
  }

  Future<void> acceptCall() async {
    if (_pendingOfferSdp == null) return;

    micEnabled = true;
    videoEnabled = false;
    remoteVideoEnabled = false;

    _setStatus(tr('call.securingConnection'));
    await _createPeerConnection();
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(_pendingOfferSdp!, 'offer'),
    );
    _remoteDescriptionSet = true;
    for (final candidate in _pendingRemoteCandidates) {
      await _peerConnection!.addCandidate(candidate);
    }
    _pendingRemoteCandidates.clear();

    _setStatus(tr('call.enablingMic'));
    await _openLocalAudio();

    _setStatus(tr('call.buildingAnswer'));
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);

    await _send('call_answer', {'sdp': answer.sdp});
    _setStatus(tr('call.connecting'));
    _setState(CallState.connected);
  }

  Future<void> declineCall() async {
    debugPrint(
      'CallService: declineCall() вызван, state=$_state, peerDeviceId=$_peerDeviceId, callId=$_callId',
    );
    await _send('call_reject', {});
    await _resetLocal();
    debugPrint('CallService: declineCall() завершён, state=$_state');
  }

  Future<void> cancelCall() async {
    await _send('call_cancel', {});
    await _resetLocal();
  }

  Future<void> endCall({bool notifyRemote = true}) async {
    debugPrint(
      'CallService: endCall() вызван, notifyRemote=$notifyRemote, '
      'state=$_state, peerDeviceId=$_peerDeviceId, callId=$_callId',
    );
    if (notifyRemote && _peerDeviceId != null) {
      await _send('call_end', {});
    }
    await _resetLocal();
    debugPrint('CallService: endCall() завершён, state=$_state');
  }

  Future<void> _resetLocal({bool peerWasUnavailable = false}) async {
    debugPrint(
      'CallService: _resetLocal() старт, state=$_state, peerWasUnavailable=$peerWasUnavailable',
    );
    // На всякий случай — если по какой-то причине нативный
    // foreground-service звонка ещё активен, гасим его вместе с обычным
    // сбросом состояния. Вызов безопасен, даже если он и не был запущен.
    CallRingPlugin.stopRinging();
    // И снимаем обход блокировки экрана, если он был выставлен ради
    // показа этого звонка — звонок закончился, дальше приложение снова
    // должно уважать блокировку.
    PipService.clearShowWhenLocked();
    // Звонок закончился, пока пользователь был в системном PiP — само
    // окошко само по себе не закроется, иначе там осталось бы висеть
    // замороженное последнее видео собеседника.
    if (isInSystemPip) PipService.exitPip();

    await _logCallIfNeeded(peerWasUnavailable: peerWasUnavailable);

    for (final track in localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
    localStream?.dispose();
    localStream = null;
    _videoTrack?.stop();
    _videoTrack = null;
    _peerConnection?.close();
    _peerConnection = null;
    _pendingOfferSdp = null;
    _remoteDescriptionSet = false;
    _pendingRemoteCandidates.clear();
    _peerDeviceId = null;
    _callId = null;
    videoEnabled = false;
    _remoteStream = null;
    _remoteStreamController.add(null);
    remoteVideoEnabled = false;
    _remoteVideoStateController.add(false);
    PipService.setRemoteVideoActive(false);
    _autoSpeakerTriggered = false;
    currentPeerLogin = null;
    currentPeerAccountId = null;
    _setState(CallState.idle);
    debugPrint('CallService: _resetLocal() завершён');
  }

  /// Пишет запись о звонке в локальную историю чата с собеседником — по
  /// одной записи на КАЖДОЕ устройство (сервер звонки не хранит, это
  /// чисто локальное наблюдение). Вызывается один раз, в момент полного
  /// завершения звонка, до сброса состояния.
  ///
  /// Если сервер прямо подтвердил, что собеседник был офлайн
  /// (peerWasUnavailable, из сигнала call_unavailable) — он никогда не
  /// получал call_offer в реальном времени и сам ничего не запишет,
  /// поэтому дополнительно отправляем ему обычное (не call_*) зашифрованное
  /// сообщение о пропущенном звонке — оно, в отличие от сигналов звонка,
  /// встаёт в серверную очередь offline-доставки и дойдёт, когда он снова
  /// будет в сети.
  Future<void> _logCallIfNeeded({bool peerWasUnavailable = false}) async {
    final peerDeviceId = _peerDeviceId;
    final startedAt = _callStartedAt;
    if (peerDeviceId == null || startedAt == null) return;

    final direction = _isOutgoingCall ? 'outgoing' : 'incoming';
    String outcome;
    int? durationSeconds;
    if (_connectedAt != null) {
      outcome = 'answered';
      durationSeconds = DateTime.now().difference(_connectedAt!).inSeconds;
    } else if (_isOutgoingCall) {
      outcome = 'no_answer';
    } else {
      outcome = 'missed';
    }

    try {
      final token = await Session.getToken();
      if (token != null) {
        final owner = await ApiClient().getDeviceOwnerInfo(token, peerDeviceId);
        if (owner != null) {
          await ChatStore.addCallLog(
            owner.login,
            direction: direction,
            outcome: outcome,
            timestamp: startedAt.millisecondsSinceEpoch,
            durationSeconds: durationSeconds,
            accountId: owner.accountId,
            callId: _callId,
          );

          if (peerWasUnavailable && _isOutgoingCall) {
            try {
              await SendLock.run(
                owner.login,
                () => sendPeerMessage(
                  peerDeviceId,
                  InnerMessage.missedCall(
                    calledAt: startedAt.millisecondsSinceEpoch,
                    callId: _callId,
                  ),
                ),
              );
            } catch (e) {
              // Не получилось доставить уведомление сейчас — не критично,
              // при следующем звонке будет ещё одна попытка.
              DebugLog.log(
                'CallService missedCall notify FAILED to=$peerDeviceId error=$e',
              );
            }
          }
        }
      }
    } catch (_) {
      // Не удалось записать лог звонка — сам звонок это не должно ломать.
    }

    _callStartedAt = null;
    _connectedAt = null;
  }

  Future<void> toggleMic() async {
    micEnabled = !micEnabled;
    for (final track in localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = micEnabled;
    }
  }

  /// Камера открывается только здесь, лениво, при первом включении видео
  /// за весь звонок. Повторные вкл/выкл после этого — просто флаг
  /// enabled на уже существующей дорожке, без повторного захвата камеры.
  Future<void> toggleVideo() async {
    videoEnabled = !videoEnabled;

    if (videoEnabled && _videoTrack == null) {
      final videoStream = await navigator.mediaDevices.getUserMedia({
        'video': {'facingMode': 'user'},
      });
      _videoTrack = videoStream.getVideoTracks().first;
      localStream?.addTrack(_videoTrack!);
      await _peerConnection?.addTrack(_videoTrack!, localStream!);
      // addTrack сам вызовет onRenegotiationNeeded — отдельно дожимать не нужно.
    } else {
      _videoTrack?.enabled = videoEnabled;
    }

    await _send('call_video_state', {'enabled': videoEnabled});
    await _updateWakelock();
  }

  /// Переключает фронтальную/тыловую камеру на уже открытой видео-дорожке
  /// (flutter_webrtc сам умеет это через нативный слой — ничего заново
  /// захватывать/пересоздавать не нужно). Имеет смысл вызывать, только
  /// пока видео включено — если дорожки ещё нет, тихо ничего не делает.
  Future<void> switchCamera() async {
    final track = _videoTrack;
    if (track == null) return;
    await Helper.switchCamera(track);
  }

  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    await Helper.setSpeakerphoneOn(speakerOn);
    await _updateProximityScreenOff();
  }

  /// Кадры, которые должны относиться к УЖЕ идущему у нас звонку —
  /// sender_device_id внутри конверта это то, что клиент-отправитель сам о
  /// себе заявил (сервер маршрутизирует по авторизованному device_id из
  /// самого WS-соединения, но пересылает этот payload как есть, значение
  /// внутри него не подменяет — см. websocket.go, релей строки 689/632).
  /// Значит любой авторизованный пользователь технически может прислать
  /// call_ice/call_answer/etc. НАПРЯМУЮ на чей угодно device_id, подделав
  /// в payload чужой sender_device_id, выдавая себя за текущего собеседника
  /// жертвы. Сверяем с тем, кого мы реально ждём, вместо того чтобы
  /// доверять полю как есть. call_offer/call_unavailable сюда не входят —
  /// первый сам решает, новый это звонок или чужой, второй вообще не несёт
  /// sender_device_id (синтезируется сервером).
  static const _requiresActivePeerMatch = {
    'call_answer',
    'call_ice',
    'call_video_state',
    'call_reject',
    'call_busy',
    'call_cancel',
    'call_end',
  };

  Future<void> _handleSignal(Map<String, dynamic> envelope) async {
    final type = envelope['type'] as String?;

    // Единственный кадр без собственного конверта вообще (синтезируется
    // сервером, см. respondCallUnavailable в websocket.go) — нечего
    // расшифровывать, обрабатываем сразу.
    if (type == 'call_unavailable') {
      await _resetLocal(peerWasUnavailable: true);
      return;
    }

    final senderDeviceId = envelope['sender_device_id'] as String?;
    if (senderDeviceId == null) return;

    if (_requiresActivePeerMatch.contains(type) &&
        senderDeviceId != _peerDeviceId) {
      DebugLog.log(
        'CallService IGNORING $type from=$senderDeviceId — does not match active peer=$_peerDeviceId',
      );
      return;
    }

    final payload = await _decryptCallSignal(senderDeviceId, envelope);
    if (payload == null) {
      DebugLog.log(
        'CallService _handleSignal: decrypt returned null for type=$type from=$senderDeviceId, dropping',
      );
      return;
    }
    // call_id остаётся снаружи конверта в открытом виде (см. _send) — сюда
    // его переносим, чтобы остальной код ниже читал его из одного места.
    payload['call_id'] = envelope['call_id'];

    switch (type) {
      case 'call_offer':
        final isRenegotiation = payload['renegotiation'] == true;

        // renegotiation обязан относиться к УЖЕ идущему звонку с этим же
        // собеседником — иначе кто-то мог бы прислать "переsогласование"
        // якобы от другого своего (валидного) сеанса, пока мы разговариваем
        // с кем-то ещё, и подменить SDP в живом соединении.
        if (isRenegotiation && senderDeviceId != _peerDeviceId) {
          DebugLog.log(
            'CallService IGNORING renegotiation from=$senderDeviceId — does not match active peer=$_peerDeviceId',
          );
          return;
        }

        if (isRenegotiation && _peerConnection != null) {
          // Повторное согласование внутри уже идущего звонка (например,
          // собеседник только что включил видео) — не новый вызов.
          final sdp = payload['sdp'] as String?;
          if (sdp == null) return;
          await _peerConnection!.setRemoteDescription(
            RTCSessionDescription(sdp, 'offer'),
          );
          final answer = await _peerConnection!.createAnswer();
          await _peerConnection!.setLocalDescription(answer);
          await _send('call_answer', {'sdp': answer.sdp});
          return;
        }

        // Новый (не renegotiation) звонок, пока мы уже разговариваем, сами
        // кому-то дозваниваемся или отвечаем на другой входящий — авто-отказ
        // "занято", без показа экрана входящего вызова и без вмешательства в
        // уже идущий у нас разговор. Симметрично _endWithReason на стороне
        // ЭТОГО нового звонящего — он увидит "абонент разговаривает" (см.
        // тот же switch, case 'call_busy').
        if (_state != CallState.idle) {
          await _sendTo(
            senderDeviceId,
            'call_busy',
            {},
            callId: payload['call_id'] as String?,
          );
          return;
        }

        _callId = payload['call_id'] as String?;
        _peerDeviceId = senderDeviceId;
        _pendingOfferSdp = payload['sdp'] as String?;
        _callStartedAt = DateTime.now();
        _connectedAt = null;
        _isOutgoingCall = false;
        // Мелодию отдельно не трогаем — _setState(incomingRinging) сам
        // вызовет CallRingPlugin.startRinging(), а он идемпотентен: если
        // нативный сервис уже звонит (разбужен push-ом, пока приложение
        // было свёрнуто/закрыто), это просто no-op без рестарта плеера.
        _setState(CallState.incomingRinging);

        debugPrint(
          'CallService: call_offer получен, autoAcceptPending=$_autoAcceptPending',
        );
        final shouldAutoAccept = _autoAcceptPending;
        _autoAcceptPending = false;

        if (shouldAutoAccept) {
          // НЕ ждём завершения — сам _autoAcceptAndOpenScreen открывает
          // экран разговора как только сможет (после резолва логина и
          // acceptCall), а обмен ключами/кандидатами WebRTC идёт уже на
          // нём, с живым статусом через statusUpdates.
          unawaited(_autoAcceptAndOpenScreen(senderDeviceId));
        } else {
          _incomingCallController.add(
            IncomingCallInfo(_callId ?? '', senderDeviceId),
          );
        }
        break;

      case 'call_answer':
        final sdp = payload['sdp'] as String?;
        if (sdp == null || _peerConnection == null) return;
        await _peerConnection!.setRemoteDescription(
          RTCSessionDescription(sdp, 'answer'),
        );
        _remoteDescriptionSet = true;
        for (final candidate in _pendingRemoteCandidates) {
          await _peerConnection!.addCandidate(candidate);
        }
        _pendingRemoteCandidates.clear();
        break;

      case 'call_ice':
        final candidate = RTCIceCandidate(
          payload['candidate'] as String?,
          payload['sdpMid'] as String?,
          payload['sdpMLineIndex'] as int?,
        );
        if (_remoteDescriptionSet && _peerConnection != null) {
          await _peerConnection!.addCandidate(candidate);
        } else {
          _pendingRemoteCandidates.add(candidate);
        }
        break;

      case 'call_video_state':
        remoteVideoEnabled = payload['enabled'] as bool? ?? false;
        _remoteVideoStateController.add(remoteVideoEnabled);
        PipService.setRemoteVideoActive(remoteVideoEnabled);
        await _updateWakelock();

        // Разово за звонок: как только у собеседника появляется видео,
        // сами переключаем звук на громкую связь (удобно смотреть, не
        // прижимая телефон к уху) — но только один раз, дальше пользователь
        // волен переключаться туда-обратно вручную без нашего вмешательства.
        if (remoteVideoEnabled && !_autoSpeakerTriggered) {
          _autoSpeakerTriggered = true;
          if (!speakerOn) {
            await toggleSpeaker();
          }
        }
        break;

      case 'call_reject':
        // Собеседник был свободен (idle) и сам нажал "отклонить" — см.
        // declineCall(). Отличаем от call_busy ниже: разные причины,
        // разный текст для звонящего.
        await _endWithReason(tr('call.declined'));
        break;

      case 'call_busy':
        // Собеседник уже разговаривает/дозванивается/отвечает на другой
        // звонок — авто-отказ (см. case 'call_offer' выше), не ручное
        // действие пользователя.
        await _endWithReason(tr('call.busy'));
        break;

      case 'call_cancel':
      case 'call_end':
        await _resetLocal();
        break;
    }
  }

  /// Завершает звонок с коротким объяснением ПРИЧИНЫ для того, кто звонил
  /// (call_screen.dart показывает его как статус-текст, пока экран
  /// разговора ещё на виду) — без этого звонок просто мгновенно исчезал
  /// (см. _resetLocal -> CallState.idle -> CallScreen сразу же
  /// popUntil(isFirst)), и звонящий не понимал, что вообще произошло.
  /// Гудок дозвона останавливаем сразу, а сам переход в idle (и закрытие
  /// экрана) задерживаем — ровно на то время, чтобы текст успели прочитать.
  Future<void> _endWithReason(String reason) async {
    SoundService.stopRingback();
    _setStatus(reason);
    await Future.delayed(const Duration(milliseconds: 1800));
    await _resetLocal();
  }
}
