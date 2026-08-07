import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StoredMessage {
  final String messageId;
  final String text;
  final bool isMine;
  final int timestamp;
  final bool isMedia;
  final String? mediaId;
  final String? mediaKeyBase64;
  final String? mediaNonceBase64;
  final String? mediaMacBase64;
  final String? fileName;
  final String status; // 'sent' | 'queued'

  StoredMessage(
    this.messageId,
    this.text,
    this.isMine,
    this.timestamp, {
    this.isMedia = false,
    this.mediaId,
    this.mediaKeyBase64,
    this.mediaNonceBase64,
    this.mediaMacBase64,
    this.fileName,
    this.status = 'sent',
  });

  StoredMessage copyWithStatus(String newStatus) => StoredMessage(
        messageId,
        text,
        isMine,
        timestamp,
        isMedia: isMedia,
        mediaId: mediaId,
        mediaKeyBase64: mediaKeyBase64,
        mediaNonceBase64: mediaNonceBase64,
        mediaMacBase64: mediaMacBase64,
        fileName: fileName,
        status: newStatus,
      );

  Map<String, dynamic> toJson() => {
        'id': messageId,
        'text': text,
        'is_mine': isMine,
        'ts': timestamp,
        'is_media': isMedia,
        'media_id': mediaId,
        'media_key': mediaKeyBase64,
        'media_nonce': mediaNonceBase64,
        'media_mac': mediaMacBase64,
        'file_name': fileName,
        'status': status,
      };

  static StoredMessage fromJson(Map<String, dynamic> j) => StoredMessage(
        j['id'] as String? ?? '',
        j['text'] as String,
        j['is_mine'] as bool,
        j['ts'] as int,
        isMedia: j['is_media'] as bool? ?? false,
        mediaId: j['media_id'] as String?,
        mediaKeyBase64: j['media_key'] as String?,
        mediaNonceBase64: j['media_nonce'] as String?,
        mediaMacBase64: j['media_mac'] as String?,
        fileName: j['file_name'] as String?,
        status: j['status'] as String? ?? 'sent',
      );
}

class ChatSummary {
  final String peerAccountId;
  String? peerLogin;
  String lastMessage;
  int lastTimestamp;
  ChatSummary(this.peerAccountId, this.peerLogin, this.lastMessage, this.lastTimestamp);
}

/// История переписки хранится по account_id собеседника (стабильный
/// идентификатор — не меняется при выходе/входе), а не по device_id
/// (меняется при каждой новой регистрации устройства). Так переписка не
/// теряется и не дублируется, если у собеседника сменилось устройство.
class ChatStore {
  static const _storage = FlutterSecureStorage();
  static String _messagesKey(String peerAccountId) => 'messages:$peerAccountId';
  static const _peersIndexKey = 'known_peers';

  static Future<List<StoredMessage>> getMessages(String peerAccountId) async {
    final stored = await _storage.read(key: _messagesKey(peerAccountId));
    if (stored == null) return [];
    final list = jsonDecode(stored) as List<dynamic>;
    return list.map((e) => StoredMessage.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<void> addMessage(
    String peerAccountId,
    StoredMessage message, {
    String? peerLogin,
  }) async {
    final messages = await getMessages(peerAccountId);
    messages.add(message);
    await _storage.write(
      key: _messagesKey(peerAccountId),
      value: jsonEncode(messages.map((m) => m.toJson()).toList()),
    );
    await _touchPeer(peerAccountId, message.text, message.timestamp, peerLogin: peerLogin);
  }
static Future<void> updateMessageStatus(
  String peerDeviceId,
  String messageId,
  String newStatus,
) async {
  final messages = await getMessages(peerDeviceId);
  final index = messages.indexWhere((m) => m.messageId == messageId);
  if (index == -1) return;

  messages[index] = messages[index].copyWithStatus(newStatus);
  await _storage.write(
    key: _messagesKey(peerDeviceId),
    value: jsonEncode(messages.map((m) => m.toJson()).toList()),
  );
}
  static Future<void> _touchPeer(
    String peerAccountId,
    String lastMessage,
    int timestamp, {
    String? peerLogin,
  }) async {
    final peers = await getKnownPeers();
    final existing = peers.where((p) => p.peerAccountId == peerAccountId).toList();
    if (existing.isNotEmpty) {
      existing.first.lastMessage = lastMessage;
      existing.first.lastTimestamp = timestamp;
      if (peerLogin != null) existing.first.peerLogin = peerLogin;
    } else {
      peers.add(ChatSummary(peerAccountId, peerLogin, lastMessage, timestamp));
    }
    await _storage.write(
      key: _peersIndexKey,
      value: jsonEncode(peers.map((p) => {
        'account_id': p.peerAccountId,
        'login': p.peerLogin,
        'last_message': p.lastMessage,
        'last_ts': p.lastTimestamp,
      }).toList()),
    );
  }

  static Future<List<ChatSummary>> getKnownPeers() async {
    final stored = await _storage.read(key: _peersIndexKey);
    if (stored == null) return [];
    final list = jsonDecode(stored) as List<dynamic>;
    return list
        .map((e) => ChatSummary(
              e['account_id'] as String,
              e['login'] as String?,
              e['last_message'] as String,
              e['last_ts'] as int,
            ))
        .toList()
      ..sort((a, b) => b.lastTimestamp.compareTo(a.lastTimestamp));
  }
}