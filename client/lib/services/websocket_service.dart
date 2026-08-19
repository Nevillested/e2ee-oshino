import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config.dart';
import '../storage/outbox_store.dart';
import '../storage/chat_store.dart';
import '../api/api_client.dart';

/// Человекочитаемое состояние подключения к серверу — для индикатора в
/// шапке списка чатов. Не претендует на бОльшую детализацию, чем реально
/// умеет отличать сам WebSocketService: Dart/IOWebSocketChannel не даёт
/// отдельно поймать фазу DNS-резолва отдельно от TCP-хендшейка, поэтому obе
/// объединены в connecting.
enum ConnectionStatus { waitingForNetwork, connecting, connected, reconnecting }

class WebSocketService {
  WebSocketService._internal();
  static final WebSocketService instance = WebSocketService._internal();

  final _statusController = StreamController<ConnectionStatus>.broadcast();
  Stream<ConnectionStatus> get statusUpdates => _statusController.stream;
  ConnectionStatus status = ConnectionStatus.connecting;

  void _setStatus(ConnectionStatus s) {
    if (status == s) return;
    status = s;
    _statusController.add(s);
  }

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  StreamSubscription? _connectivitySubscription;
  Timer? _reconnectTimer;
  String? _token;
  String? _deviceId;
  bool _manuallyDisconnected = false;
  bool _hadNetwork = true;

  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  final _callController = StreamController<Map<String, dynamic>>.broadcast();
  final _presenceController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _blockStatusController = StreamController<void>.broadcast();
  final _avatarChangedController = StreamController<String>.broadcast();

  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  Stream<Map<String, dynamic>> get callSignals => _callController.stream;
  // "presence" (появление/уход собеседника) и "typing" (печатает прямо
  // сейчас) — см. WSMsgPresence/WSMsgTypingRelay на сервере, отдаются как
  // есть (сырой decoded JSON), разбор — на стороне chat_screen.dart.
  Stream<Map<String, dynamic>> get presenceEvents => _presenceController.stream;
  // "block_status_changed" — кто-то нас заблокировал/разблокировал (см.
  // notifyBlockStatusChanged на сервере) — БЕЗ деталей в самом сигнале,
  // сервер остаётся единственным источником истины: получатели просто
  // перезапрашивают актуальное состояние (см. ApiClient.getBlockedContacts)
  // вместо того чтобы ждать следующего открытия чата.
  Stream<void> get blockStatusEvents => _blockStatusController.stream;
  // "avatar_changed" — у кого-то (см. AccountId в самом сообщении)
  // поменялось фото профиля (см. notifyAvatarChanged на сервере) — тоже
  // без реального фото внутри, только account_id, для которого нужно
  // сбросить локальный кэш (см. AvatarCache.invalidate) и перезапросить
  // заново.
  Stream<String> get avatarChangedEvents => _avatarChangedController.stream;
  bool get isConnected => _channel != null;

  final _sessionInvalidController = StreamController<void>.broadcast();
  Stream<void> get sessionInvalidated => _sessionInvalidController.stream;

  void connect(String token, String deviceId) {
    _token = token;
    _deviceId = deviceId;
    _manuallyDisconnected = false;
    _openConnection();

    _connectivitySubscription?.cancel();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      result,
    ) {
      final hasNetwork =
          result.isNotEmpty && !result.contains(ConnectivityResult.none);
      if (hasNetwork && !_hadNetwork) {
        _forceReconnect();
      } else if (!hasNetwork) {
        _setStatus(ConnectionStatus.waitingForNetwork);
      }
      _hadNetwork = hasNetwork;
    });
  }

  void _forceReconnect() {
    if (_manuallyDisconnected) return;
    _subscription?.cancel();
    _channel?.sink.close();
    _channel = null;
    _reconnectTimer?.cancel();
    _openConnection();
  }

  void _openConnection() {
    if (_token == null || _deviceId == null) return;

    _setStatus(ConnectionStatus.connecting);

    final uri = Uri.parse('${ApiConfig.wsBaseUrl}/ws?device_id=$_deviceId');

    // pingInterval — без него "зомби"-соединение (сокет технически ещё
    // жив с точки зрения клиента, но реально не пропускает данные — типично
    // при обрыве по таймауту NAT/оператора без честного TCP FIN/RST) висит
    // в статусе "подключено" сколь угодно долго: ни onError, ни onDone
    // никогда не срабатывают, потому что клиенту физически неоткуда узнать
    // о разрыве. С pingInterval dart:io сам шлёт ping и, не дождавшись
    // pong, закрывает сокет — тогда уже отработает наш обычный
    // onDone/onError → _scheduleReconnect().
    final channel = IOWebSocketChannel.connect(
      uri,
      headers: {'Authorization': 'Bearer $_token'},
      pingInterval: const Duration(seconds: 20),
    );
    _channel = channel;

    // connect() возвращает канал сразу, а само подключение (включая DNS)
    // происходит асинхронно — если сети нет ("Failed host lookup" и т.п.),
    // ошибка приходит именно через .ready и, если её не поймать явно, летит
    // как необработанное исключение (просто шум в логах, а не крэш —
    // .listen(onError:) ниже слушает уже установленное соединение и здесь
    // не участвует). Ловим и тихо уходим в обычный цикл переподключения.
    //
    // .timeout(8s) — без него зависшая на "чёрной дыре" сети попытка (пакеты
    // молча пропадают, никто явно не отвечает отказом — обычное дело при
    // смене вышки/сети на мобильном) висела бы неопределённо долго, пока не
    // сработает таймаут TCP-connect уровня ОС (может быть заметно больше
    // минуты) — всё это время приложение выглядит "открытым и онлайн", а
    // сервер уже считает устройство отключённым и кладёт сообщения в очередь
    // вместо живой доставки.
    channel.ready
        .timeout(const Duration(seconds: 8))
        .then((_) {
          _setStatus(ConnectionStatus.connected);
        })
        .catchError((Object e) {
          // Могли успеть переподключиться другим циклом, пока эта, уже
          // отвязанная попытка донашивала свой таймаут — тогда трогать
          // текущее (уже другое) соединение нельзя.
          if (!identical(_channel, channel)) return;
          debugPrint(
            'WebSocketService: не удалось подключиться ($e), повтор через reconnect',
          );
          channel.sink.close();
          _channel = null;
          _scheduleReconnect();
        });

    flushOutbox();

    _subscription = channel.stream.listen(
      (raw) {
        try {
          final outer = jsonDecode(raw as String) as Map<String, dynamic>;
          final type = outer['Type'] as String?;

          if (type == 'presence' || type == 'typing') {
            _presenceController.add(outer);
            return;
          }

          if (type == 'block_status_changed') {
            _blockStatusController.add(null);
            return;
          }

          if (type == 'avatar_changed') {
            final accountId = outer['AccountId'] as String?;
            if (accountId != null) _avatarChangedController.add(accountId);
            return;
          }

          if (type != null && type.startsWith('call_')) {
            // Только call_offer приходит с DeliveryId (сервер ждёт от нас
            // подтверждения именно для него — если не дождётся, посчитает
            // соединение "зомби" и обработает как офлайн, с push и очередью
            // отложенного звонка). Для остальных call_* кадров DeliveryId
            // нет, и это просто безопасный no-op.
            final deliveryId = outer['DeliveryId'];
            if (deliveryId is String && deliveryId.isNotEmpty) {
              _channel?.sink.add(
                jsonEncode({'Type': 'ack', 'DeliveryId': deliveryId}),
              );
            }

            final ciphertext = outer['Ciphertext'] as String?;
            final payload = ciphertext != null
                ? jsonDecode(ciphertext) as Map<String, dynamic>
                : <String, dynamic>{};
            payload['type'] = type;
            _callController.add(payload);
            return;
          }

          // ВАЖНО: ack тут раньше слался сразу по факту получения кадра —
          // до того, как конверт вообще успевал расшифроваться и
          // сохраниться (MessageRouter обрабатывает его асинхронно, из
          // отдельной подписки на _messageController, уже после того как
          // этот listener отработал). Если расшифровка/запись потом падали
          // (сбойная сессия, гонка и т.п.), сервер к этому моменту уже
          // считал сообщение доставленным и стирал его из очереди —
          // тихая, необратимая потеря уже на клиенте, поверх любой
          // серверной надёжности. Теперь ack шлёт сам MessageRouter,
          // только после того как реально сохранил сообщение (см.
          // ackDelivery/message_router.dart) — DeliveryId едет вместе с
          // конвертом как транспортный довесок, а не отправляется отсюда.
          final deliveryId = outer['DeliveryId'];
          final ciphertext = outer['Ciphertext'];
          if (ciphertext is String) {
            final envelope = jsonDecode(ciphertext) as Map<String, dynamic>;
            if (deliveryId is String && deliveryId.isNotEmpty) {
              envelope['_deliveryId'] = deliveryId;
            }
            _messageController.add(envelope);
          }
        } catch (_) {}
      },
      onError: (_) => _scheduleReconnect(),
      onDone: () => _scheduleReconnect(),
    );
  }

  void _scheduleReconnect() {
    _channel = null;
    _subscription?.cancel();
    if (_manuallyDisconnected) return;
    _setStatus(
      _hadNetwork
          ? ConnectionStatus.reconnecting
          : ConnectionStatus.waitingForNetwork,
    );
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () async {
      final token = _token;
      if (token == null) {
        _openConnection();
        return;
      }
      // Соединение оборвалось — прежде чем пытаться переподключиться,
      // проверяем, не отозвал ли сервер токен (например, вход выполнен
      // на другом устройстве). Если отозвал — дальше пытаться бессмысленно.
      final valid = await ApiClient().checkSession(token);
      if (valid == false) {
        // Именно false — сервер явно ответил "токен невалиден", это точно
        // принудительный логаут (вход с другого устройства).
        _manuallyDisconnected = true;
        _sessionInvalidController.add(null);
        return;
      }
      // valid == true или valid == null (не удалось проверить, например нет
      // сети) — в обоих случаях просто пробуем переподключиться дальше, не
      // разлогиниваем пользователя из-за временного отсутствия интернета.
      _openConnection();
    });
  }

  void disconnect() {
    _manuallyDisconnected = true;
    _reconnectTimer?.cancel();
    _connectivitySubscription?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    _channel = null;
  }

  /// Подтверждает серверу доставку сообщения с данным DeliveryId — вызывает
  /// MessageRouter, и ТОЛЬКО после того, как реально расшифровал и сохранил
  /// его (см. комментарий в listener() выше про то, почему ack больше не
  /// шлётся отсюда же по факту получения кадра).
  void ackDelivery(String deliveryId) {
    _channel?.sink.add(jsonEncode({'Type': 'ack', 'DeliveryId': deliveryId}));
  }

  /// silent — служебное control-сообщение (реакция/пин/правка/удаление),
  /// см. WSMsgFrom.Silent на сервере: открытым текстом просим сервер не
  /// слать будящий push офлайн-получателю ради него. Само сообщение
  /// шифруется и доставляется как обычно — флаг влияет только на push.
  Future<String> sendEnvelope(
    String toDeviceId,
    Map<String, dynamic> envelope,
    String messageId, {
    bool silent = false,
  }) async {
    if (_channel == null) {
      await OutboxStore.add(toDeviceId, envelope, messageId, silent: silent);
      return 'queued';
    }

    final message = {
      'ToDeviceId': toDeviceId,
      'Ciphertext': jsonEncode(envelope),
      'Type': 'message',
      'Silent': silent,
    };
    _channel!.sink.add(jsonEncode(message));
    return 'sent';
  }

  /// Сигналы звонка (offer/answer/ICE и т.д.) — не проходят через очередь
  /// офлайн-доставки: если собеседник недоступен прямо сейчас, звонок
  /// просто не проходит, ждать его появления в сети не нужно.
  void sendCallSignal(
    String toDeviceId,
    String type,
    Map<String, dynamic> payload,
  ) {
    final message = {
      'ToDeviceId': toDeviceId,
      'Ciphertext': jsonEncode(payload),
      'Type': type,
    };
    _channel?.sink.add(jsonEncode(message));
  }

  /// Подписка на живой статус устройства собеседника (см.
  /// "presence_subscribe" на сервере) — сервер тут же отвечает текущим
  /// статусом (см. presenceEvents), а дальше присылает обновления сам, пока
  /// не придёт unsubscribePresence или это соединение не оборвётся. Если
  /// канал сейчас не поднят — просто no-op: подписываться не на чем, а
  /// когда соединение восстановится, вызывающая сторона (chat_screen)
  /// подпишется заново по statusUpdates.
  void subscribePresence(String peerDeviceId) {
    _channel?.sink.add(
      jsonEncode({'Type': 'presence_subscribe', 'ToDeviceId': peerDeviceId}),
    );
  }

  void unsubscribePresence(String peerDeviceId) {
    _channel?.sink.add(
      jsonEncode({
        'Type': 'presence_unsubscribe',
        'ToDeviceId': peerDeviceId,
      }),
    );
  }

  /// "Я сейчас печатаю" — чистый relay без очереди/подтверждения, вызывающая
  /// сторона сама решает, как часто слать (см. троттлинг в chat_screen.dart).
  void sendTyping(String peerDeviceId) {
    _channel?.sink.add(
      jsonEncode({'Type': 'typing', 'ToDeviceId': peerDeviceId}),
    );
  }

  Future<void> flushOutbox() async {
    final pending = await OutboxStore.getAll();
    if (pending.isEmpty) return;

    for (final item in pending) {
      final toDeviceId = item['to_device_id'] as String;
      final envelope = item['envelope'] as Map<String, dynamic>;
      final messageId = item['message_id'] as String?;
      final silent = item['silent'] as bool? ?? false;

      final message = {
        'ToDeviceId': toDeviceId,
        'Ciphertext': jsonEncode(envelope),
        'Type': 'message',
        'Silent': silent,
      };
      _channel?.sink.add(jsonEncode(message));

      if (messageId != null) {
        await ChatStore.updateMessageStatus(toDeviceId, messageId, 'sent');
      }
    }

    await OutboxStore.clear();
  }
}
