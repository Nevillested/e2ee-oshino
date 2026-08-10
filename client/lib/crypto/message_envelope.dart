import 'dart:convert';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class InnerMessage {
  final String messageId;
  final String type;
  final int sentAt;
  final String body;

  InnerMessage({
    required this.messageId,
    required this.type,
    required this.sentAt,
    required this.body,
  });

  factory InnerMessage.text(String body) => InnerMessage(
        messageId: _uuid.v4(),
        type: 'text',
        sentAt: DateTime.now().millisecondsSinceEpoch,
        body: body,
      );

factory InnerMessage.media({
  String? messageId,
  required String mediaId,
  required String keyBase64,
  String? nonceBase64,
  String? macBase64,
  required String fileName,
  bool isFile = false,
  int fileSize = 0,
  bool chunked = false,
}) {
  final body = jsonEncode({
    'media_id': mediaId,
    'key': keyBase64,
    'nonce': nonceBase64,
    'mac': macBase64,
    'file_name': fileName,
    'is_file': isFile,
    'file_size': fileSize,
    'chunked': chunked,
  });
  return InnerMessage(
    messageId: messageId ?? _uuid.v4(),
    type: 'media',
    sentAt: DateTime.now().millisecondsSinceEpoch,
    body: body,
  );
}

  String encode() => jsonEncode({
        'message_id': messageId,
        'type': type,
        'sent_at': sentAt,
        'body': body,
      });

  static InnerMessage decode(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return InnerMessage(
      messageId: json['message_id'] as String,
      type: json['type'] as String,
      sentAt: json['sent_at'] as int,
      body: json['body'] as String,
    );
  }
}