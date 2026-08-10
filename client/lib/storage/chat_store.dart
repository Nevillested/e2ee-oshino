import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StoredMessage {
  final String messageId;
  final String text;
  final bool isMine;
  final int timestamp;
  final bool isMedia;
  final bool isFile;
  final int fileSize;
  final bool chunked;
  final String? mediaId;
  final String? mediaKeyBase64;
  final String? mediaNonceBase64;
  final String? mediaMacBase64;
  final String? fileName;
  final String status;
  final String? processingStep;
  final String? localPreviewPath;

  StoredMessage(
    this.messageId,
    this.text,
    this.isMine,
    this.timestamp, {
    this.isMedia = false,
    this.isFile = false,
    this.fileSize = 0,
    this.chunked = false,
    this.mediaId,
    this.mediaKeyBase64,
    this.mediaNonceBase64,
    this.mediaMacBase64,
    this.fileName,
    this.status = 'sent',
    this.processingStep,
    this.localPreviewPath,
  });

  Map<String, dynamic> toJson() => {
        'id': messageId,
        'text': text,
        'is_mine': isMine,
        'ts': timestamp,
        'is_media': isMedia,
        'is_file': isFile,
        'file_size': fileSize,
        'chunked': chunked,
        'media_id': mediaId,
        'media_key': mediaKeyBase64,
        'media_nonce': mediaNonceBase64,
        'media_mac': mediaMacBase64,
        'file_name': fileName,
        'status': status,
        'step': processingStep,
        'local_preview': localPreviewPath,
      };

  static StoredMessage fromJson(Map<String, dynamic> j) => StoredMessage(
        j['id'] as String? ?? '',
        j['text'] as String,
        j['is_mine'] as bool,
        j['ts'] as int,
        isMedia: j['is_media'] as bool? ?? false,
        isFile: j['is_file'] as bool? ?? false,
        fileSize: j['file_size'] as int? ?? 0,
        chunked: j['chunked'] as bool? ?? false,
        mediaId: j['media_id'] as String?,
        mediaKeyBase64: j['media_key'] as String?,
        mediaNonceBase64: j['media_nonce'] as String?,
        mediaMacBase64: j['media_mac'] as String?,
        fileName: j['file_name'] as String?,
        status: j['status'] as String? ?? 'sent',
        processingStep: j['step'] as String?,
        localPreviewPath: j['local_preview'] as String?,
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

  ChatSummary(
    this.peerLogin,
    this.lastMessage,
    this.lastTimestamp, {
    this.lastKnownAccountId,
    this.lastKnownDeviceId,
    this.isDeleted = false,
    this.unreadCount = 0,
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
    return list.map((e) => StoredMessage.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<void> addMessage(
    String peerLogin,
    StoredMessage message, {
    String? accountId,
    bool incrementUnread = false,
  }) async {
    final messages = await getMessages(peerLogin);
    messages.add(message);
    await _storage.write(
      key: _messagesKey(peerLogin),
      value: jsonEncode(messages.map((m) => m.toJson()).toList()),
    );
    await _touchPeer(
      peerLogin,
      message.text,
      message.timestamp,
      accountId: accountId,
      incrementUnread: incrementUnread,
    );
  }

  static Future<void> _replace(String peerLogin, String messageId, StoredMessage Function(StoredMessage old) update) async {
    final messages = await getMessages(peerLogin);
    final index = messages.indexWhere((m) => m.messageId == messageId);
    if (index == -1) return;
    messages[index] = update(messages[index]);
    await _storage.write(
      key: _messagesKey(peerLogin),
      value: jsonEncode(messages.map((m) => m.toJson()).toList()),
    );
    _changesController.add(null);
  }

  static Future<void> updateMessageStatus(String peerLogin, String messageId, String newStatus) {
    return _replace(peerLogin, messageId, (old) => StoredMessage(
          old.messageId, old.text, old.isMine, old.timestamp,
          isMedia: old.isMedia, isFile: old.isFile, fileSize: old.fileSize, chunked: old.chunked,
          mediaId: old.mediaId, mediaKeyBase64: old.mediaKeyBase64, mediaNonceBase64: old.mediaNonceBase64,
          mediaMacBase64: old.mediaMacBase64, fileName: old.fileName, status: newStatus,
          processingStep: (newStatus == 'sent' || newStatus == 'failed' || newStatus == 'queued') ? null : old.processingStep,
          localPreviewPath: old.localPreviewPath,
        ));
  }

  static Future<void> updateProcessingStep(String peerLogin, String messageId, String step) {
    return _replace(peerLogin, messageId, (old) => StoredMessage(
          old.messageId, old.text, old.isMine, old.timestamp,
          isMedia: old.isMedia, isFile: old.isFile, fileSize: old.fileSize, chunked: old.chunked,
          mediaId: old.mediaId, mediaKeyBase64: old.mediaKeyBase64, mediaNonceBase64: old.mediaNonceBase64,
          mediaMacBase64: old.mediaMacBase64, fileName: old.fileName, status: old.status,
          processingStep: step,
          localPreviewPath: old.localPreviewPath,
        ));
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
    return _replace(peerLogin, messageId, (old) => StoredMessage(
          old.messageId, old.text, old.isMine, old.timestamp,
          isMedia: old.isMedia, isFile: old.isFile, fileSize: old.fileSize, chunked: old.chunked,
          mediaId: mediaId, mediaKeyBase64: keyBase64, mediaNonceBase64: nonceBase64,
          mediaMacBase64: macBase64, fileName: old.fileName, status: old.status,
          processingStep: old.processingStep,
          localPreviewPath: old.localPreviewPath,
        ));
  }

  static Future<void> _touchPeer(
    String peerLogin,
    String lastMessage,
    int timestamp, {
    String? accountId,
    bool incrementUnread = false,
  }) async {
    final peers = await getKnownPeers();
    final existing = peers.where((p) => p.peerLogin == peerLogin).toList();
    if (existing.isNotEmpty) {
      existing.first.lastMessage = lastMessage;
      existing.first.lastTimestamp = timestamp;
      if (accountId != null) existing.first.lastKnownAccountId = accountId;
      if (incrementUnread) existing.first.unreadCount += 1;
    } else {
      peers.add(ChatSummary(
        peerLogin,
        lastMessage,
        timestamp,
        lastKnownAccountId: accountId,
        unreadCount: incrementUnread ? 1 : 0,
      ));
    }
    await _writePeers(peers);
  }

  static Future<void> clearUnread(String peerLogin) async {
    final peers = await getKnownPeers();
    final existing = peers.where((p) => p.peerLogin == peerLogin).toList();
    if (existing.isEmpty) return;
    if (existing.first.unreadCount == 0) return;
    existing.first.unreadCount = 0;
    await _writePeers(peers);
  }

  static Future<void> setPeerDeletedStatus(String peerLogin, bool isDeleted) async {
    final peers = await getKnownPeers();
    final existing = peers.where((p) => p.peerLogin == peerLogin).toList();
    if (existing.isEmpty) return;
    existing.first.isDeleted = isDeleted;
    await _writePeers(peers);
  }

  static Future<void> setLastKnownDeviceId(String peerLogin, String deviceId) async {
    final peers = await getKnownPeers();
    final existing = peers.where((p) => p.peerLogin == peerLogin).toList();
    if (existing.isEmpty) return;
    existing.first.lastKnownDeviceId = deviceId;
    await _writePeers(peers);
  }

  static Future<void> _writePeers(List<ChatSummary> peers) async {
    await _storage.write(
      key: _peersIndexKey,
      value: jsonEncode(peers
          .map((p) => {
                'login': p.peerLogin,
                'account_id': p.lastKnownAccountId,
                'device_id': p.lastKnownDeviceId,
                'last_message': p.lastMessage,
                'last_ts': p.lastTimestamp,
                'is_deleted': p.isDeleted,
                'unread': p.unreadCount,
              })
          .toList()),
    );
    _changesController.add(null);
  }

  static Future<List<ChatSummary>> getKnownPeers() async {
    final stored = await _storage.read(key: _peersIndexKey);
    if (stored == null) return [];
    final list = jsonDecode(stored) as List<dynamic>;
    return list
        .map((e) => ChatSummary(
              e['login'] as String,
              e['last_message'] as String,
              e['last_ts'] as int,
              lastKnownAccountId: e['account_id'] as String?,
              lastKnownDeviceId: e['device_id'] as String?,
              isDeleted: e['is_deleted'] as bool? ?? false,
              unreadCount: e['unread'] as int? ?? 0,
            ))
        .toList()
      ..sort((a, b) => b.lastTimestamp.compareTo(a.lastTimestamp));
  }
}