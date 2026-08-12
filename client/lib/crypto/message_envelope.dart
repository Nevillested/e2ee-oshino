import 'dart:convert';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class InnerMessage {
  final String messageId;
  final String type;
  final int sentAt;
  final String body;
  final String? groupId;

  InnerMessage({
    required this.messageId,
    required this.type,
    required this.sentAt,
    required this.body,
    this.groupId,
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

  /// Несколько файлов (и опционально подпись), отправленные одним
  /// пользовательским действием, уходят собеседнику ОДНИМ зашифрованным
  /// конвертом — чтобы на его стороне вся группа появилась в чате разом,
  /// а не по одному сообщению по мере загрузки каждого файла.
  factory InnerMessage.mediaGroup({
    required String groupId,
    String? caption,
    String? textMessageId,
    required List<Map<String, dynamic>> files,
  }) {
    final body = jsonEncode({
      'caption': caption,
      'text_message_id': textMessageId,
      'files': files,
    });
    return InnerMessage(
      messageId: _uuid.v4(),
      type: 'media_group',
      sentAt: DateTime.now().millisecondsSinceEpoch,
      body: body,
      groupId: groupId,
    );
  }

  /// Уведомление о пропущенном звонке — уходит собеседнику как ОБЫЧНОЕ
  /// сообщение (через ту же очередь offline-доставки на сервере, что и
  /// текст/медиа), в отличие от call_* сигналов звонка, которые сервер не
  /// хранит вообще. Отправляется только когда сервер прямо подтвердил,
  /// что получатель был офлайн (call_unavailable) — иначе получатель уже
  /// увидел звонок в реальном времени и сам записал его локально.
  factory InnerMessage.missedCall({required int calledAt}) {
    final body = jsonEncode({'called_at': calledAt});
    return InnerMessage(
      messageId: _uuid.v4(),
      type: 'call_missed',
      sentAt: DateTime.now().millisecondsSinceEpoch,
      body: body,
    );
  }

  String encode() => jsonEncode({
        'message_id': messageId,
        'type': type,
        'sent_at': sentAt,
        'body': body,
        'group_id': groupId,
      });

  static InnerMessage decode(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return InnerMessage(
      messageId: json['message_id'] as String,
      type: json['type'] as String,
      sentAt: json['sent_at'] as int,
      body: json['body'] as String,
      groupId: json['group_id'] as String?,
    );
  }
}