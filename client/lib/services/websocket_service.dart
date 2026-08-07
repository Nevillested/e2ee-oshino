import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config.dart';
import '../storage/outbox_store.dart';
import '../storage/chat_store.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

class WebSocketService {
  StreamSubscription? _connectivitySubscription;
  WebSocketService._internal();
  static final WebSocketService instance = WebSocketService._internal();
bool _hadNetwork = true;
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  String? _token;
  String? _deviceId;
  bool _manuallyDisconnected = false;

  final _messageController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  bool get isConnected => _channel != null;

void connect(String token, String deviceId) {
  _token = token;
  _deviceId = deviceId;
  _manuallyDisconnected = false;
  _openConnection();

  // Не дожидаемся, пока сама ОС решит сообщить об обрыве TCP (это может
  // занять минуты) — при любом изменении сети форсируем переподключение
  // немедленно.
_connectivitySubscription?.cancel();
_connectivitySubscription = Connectivity().onConnectivityChanged.listen((result) {
  final hasNetwork = result.isNotEmpty && !result.contains(ConnectivityResult.none);

  // Форсируем переподключение только при настоящем переходе из "сети не
  // было" в "сеть появилась" — а не при любом шевелении интерфейса,
  // которое эмуляторы и некоторые устройства могут слать довольно часто
  // без реального разрыва связи.
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

    final deliveryId = outer['DeliveryId'];
    if (deliveryId is String && deliveryId.isNotEmpty) {
      // Подтверждаем получение немедленно, до расшифровки — ACK означает
      // "байты дошли до устройства по сети", а не "успешно расшифрованы".
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

    // Простая фиксированная задержка перед повторной попыткой — этого
    // достаточно для кратких сетевых сбоев вроде того, что мы видели.
    // Если понадобится, позже можно заменить на растущую задержку.
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), _openConnection);
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