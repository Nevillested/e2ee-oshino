import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config.dart';
import '../storage/outbox_store.dart';
import '../storage/chat_store.dart';
import '../api/api_client.dart';

class WebSocketService {
  WebSocketService._internal();
  static final WebSocketService instance = WebSocketService._internal();

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

    final uri = Uri.parse('${ApiConfig.wsBaseUrl}/ws?device_id=$_deviceId');

    _channel = IOWebSocketChannel.connect(
      uri,
      headers: {'Authorization': 'Bearer $_token'},
    );

    flushOutbox();

    _subscription = _channel!.stream.listen(
      (raw) {
        try {
          final outer = jsonDecode(raw as String) as Map<String, dynamic>;
          final type = outer['Type'] as String?;

          if (type != null && type.startsWith('call_')) {
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

  Future<String> sendEnvelope(
    String toDeviceId,
    Map<String, dynamic> envelope,
    String messageId,
  ) async {
    if (_channel == null) {
      await OutboxStore.add(toDeviceId, envelope, messageId);
      return 'queued';
    }

    final message = {
      'ToDeviceId': toDeviceId,
      'Ciphertext': jsonEncode(envelope),
      'Type': 'message',
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

      final message = {
        'ToDeviceId': toDeviceId,
        'Ciphertext': jsonEncode(envelope),
        'Type': 'message',
      };
      _channel?.sink.add(jsonEncode(message));

      if (messageId != null) {
        await ChatStore.updateMessageStatus(toDeviceId, messageId, 'sent');
      }
    }

    await OutboxStore.clear();
  }
}