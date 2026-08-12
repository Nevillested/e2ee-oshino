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
enum ConnectionStatus {
  waitingForNetwork,
  connecting,
  connected,
  reconnecting,
}

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

  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  Stream<Map<String, dynamic>> get callSignals => _callController.stream;
  bool get isConnected => _channel != null;

final _sessionInvalidController = StreamController<void>.broadcast();
Stream<void> get sessionInvalidated => _sessionInvalidController.stream;

  void connect(String token, String deviceId) {
    _token = token;
    _deviceId = deviceId;
    _manuallyDisconnected = false;
    _openConnection();

    _connectivitySubscription?.cancel();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((result) {
      final hasNetwork = result.isNotEmpty && !result.contains(ConnectivityResult.none);
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
    _channel = IOWebSocketChannel.connect(
      uri,
      headers: {'Authorization': 'Bearer $_token'},
      pingInterval: const Duration(seconds: 20),
    );

    // connect() возвращает канал сразу, а само подключение (включая DNS)
    // происходит асинхронно — если сети нет ("Failed host lookup" и т.п.),
    // ошибка приходит именно через .ready и, если её не поймать явно, летит
    // как необработанное исключение (просто шум в логах, а не крэш —
    // .listen(onError:) ниже слушает уже установленное соединение и здесь
    // не участвует). Ловим и тихо уходим в обычный цикл переподключения.
    _channel!.ready.then((_) {
      _setStatus(ConnectionStatus.connected);
    }).catchError((Object e) {
      debugPrint('WebSocketService: не удалось подключиться ($e), повтор через reconnect');
      _scheduleReconnect();
    });

    flushOutbox();

    _subscription = _channel!.stream.listen(
      (raw) {
        try {
          final outer = jsonDecode(raw as String) as Map<String, dynamic>;
          final type = outer['Type'] as String?;

          if (type != null && type.startsWith('call_')) {
            // Только call_offer приходит с DeliveryId (сервер ждёт от нас
            // подтверждения именно для него — если не дождётся, посчитает
            // соединение "зомби" и обработает как офлайн, с push и очередью
            // отложенного звонка). Для остальных call_* кадров DeliveryId
            // нет, и это просто безопасный no-op.
            final deliveryId = outer['DeliveryId'];
            if (deliveryId is String && deliveryId.isNotEmpty) {
              _channel?.sink.add(jsonEncode({'Type': 'ack', 'DeliveryId': deliveryId}));
            }

            final ciphertext = outer['Ciphertext'] as String?;
            final payload = ciphertext != null
                ? jsonDecode(ciphertext) as Map<String, dynamic>
                : <String, dynamic>{};
            payload['type'] = type;
            _callController.add(payload);
            return;
          }

          final deliveryId = outer['DeliveryId'];
          if (deliveryId is String && deliveryId.isNotEmpty) {
            _channel?.sink.add(jsonEncode({'Type': 'ack', 'DeliveryId': deliveryId}));
          }

          final ciphertext = outer['Ciphertext'];
          if (ciphertext is String) {
            final envelope = jsonDecode(ciphertext) as Map<String, dynamic>;
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
  _setStatus(_hadNetwork ? ConnectionStatus.reconnecting : ConnectionStatus.waitingForNetwork);
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
  void sendCallSignal(String toDeviceId, String type, Map<String, dynamic> payload) {
    final message = {
      'ToDeviceId': toDeviceId,
      'Ciphertext': jsonEncode(payload),
      'Type': type,
    };
    _channel?.sink.add(jsonEncode(message));
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