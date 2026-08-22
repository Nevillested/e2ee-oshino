import 'dart:convert';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class InnerMessage {
  final String messageId;
  final String type;
  final int sentAt;
  final String body;
  final String? groupId;

  /// Сообщение, на которое отвечают (см. InnerMessage.text/.media) — если
  /// не null, отправлено вместе с превью текста оригинала, снятым В
  /// МОМЕНТ ответа: так превью переживает последующее редактирование или
  /// удаление оригинала у отвечающего — то же самое, что делает и Telegram.
  final String? replyToMessageId;
  final String? replyToPreview;

  InnerMessage({
    required this.messageId,
    required this.type,
    required this.sentAt,
    required this.body,
    this.groupId,
    this.replyToMessageId,
    this.replyToPreview,
  });

  factory InnerMessage.text(
    String body, {
    String? replyToMessageId,
    String? replyToPreview,
  }) => InnerMessage(
    messageId: _uuid.v4(),
    type: 'text',
    sentAt: DateTime.now().millisecondsSinceEpoch,
    body: body,
    replyToMessageId: replyToMessageId,
    replyToPreview: replyToPreview,
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
    String? replyToMessageId,
    String? replyToPreview,
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
      replyToMessageId: replyToMessageId,
      replyToPreview: replyToPreview,
    );
  }

  /// Голосовое сообщение — зашифровано/загружено тем же путём, что и
  /// любой файл (см. InnerMessage.media), просто отдельный тип, чтобы
  /// получатель однозначно знал рендерить плеер, а не пузырь с фото/файлом.
  factory InnerMessage.voice({
    String? messageId,
    required String mediaId,
    required String keyBase64,
    String? nonceBase64,
    String? macBase64,
    int fileSize = 0,
    bool chunked = false,
    required int durationMs,
    String? replyToMessageId,
    String? replyToPreview,
  }) {
    final body = jsonEncode({
      'media_id': mediaId,
      'key': keyBase64,
      'nonce': nonceBase64,
      'mac': macBase64,
      'file_size': fileSize,
      'chunked': chunked,
      'duration_ms': durationMs,
    });
    return InnerMessage(
      messageId: messageId ?? _uuid.v4(),
      type: 'voice',
      sentAt: DateTime.now().millisecondsSinceEpoch,
      body: body,
      replyToMessageId: replyToMessageId,
      replyToPreview: replyToPreview,
    );
  }

  /// Видео-сообщение (у нас квадратное, а не кружком) — тот же принцип,
  /// что и .voice.
  factory InnerMessage.videoNote({
    String? messageId,
    required String mediaId,
    required String keyBase64,
    String? nonceBase64,
    String? macBase64,
    int fileSize = 0,
    bool chunked = false,
    required int durationMs,
    String? replyToMessageId,
    String? replyToPreview,
  }) {
    final body = jsonEncode({
      'media_id': mediaId,
      'key': keyBase64,
      'nonce': nonceBase64,
      'mac': macBase64,
      'file_size': fileSize,
      'chunked': chunked,
      'duration_ms': durationMs,
    });
    return InnerMessage(
      messageId: messageId ?? _uuid.v4(),
      type: 'video_note',
      sentAt: DateTime.now().millisecondsSinceEpoch,
      body: body,
      replyToMessageId: replyToMessageId,
      replyToPreview: replyToPreview,
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
  /// callId — тот же UUID звонка (CallService._callId), что уже известен
  /// звонившему с самого начала попытки — даёт записи в истории
  /// получателя тот же id, что и у звонившего (см. ChatStore.addCallLog),
  /// чтобы "удалить у обоих" тоже находило и эту запись, а не только
  /// созданные вживую записи обеих сторон при звонке, где оба были онлайн.
  factory InnerMessage.missedCall({required int calledAt, String? callId}) {
    final body = jsonEncode({'called_at': calledAt, 'call_id': callId});
    return InnerMessage(
      messageId: _uuid.v4(),
      type: 'call_missed',
      sentAt: DateTime.now().millisecondsSinceEpoch,
      body: body,
    );
  }

  /// Реакция на сообщение — emoji=null означает "снять реакцию". Как и
  /// остальные control-типы ниже, идёт тем же каналом (тот же Double
  /// Ratchet, та же офлайн-очередь на сервере), что и обычные сообщения —
  /// сервер по-прежнему не видит ничего, кроме шифротекста.
  factory InnerMessage.reaction({
    required String targetMessageId,
    String? emoji,
  }) {
    final body = jsonEncode({'target_id': targetMessageId, 'emoji': emoji});
    return InnerMessage(
      messageId: _uuid.v4(),
      type: 'reaction',
      sentAt: DateTime.now().millisecondsSinceEpoch,
      body: body,
    );
  }

  /// pinned=false — открепление. Один закреп на чат: новый pin просто
  /// заменяет старый (специального сообщения "открепили X, закрепили Y"
  /// не шлём, у получателя действие тоже просто идемпотентно применяется).
  factory InnerMessage.pin({
    required String targetMessageId,
    required bool pinned,
  }) {
    final body = jsonEncode({'target_id': targetMessageId, 'pinned': pinned});
    return InnerMessage(
      messageId: _uuid.v4(),
      type: 'pin',
      sentAt: DateTime.now().millisecondsSinceEpoch,
      body: body,
    );
  }

  /// Редактирование — получатель ищет сообщение с target_id в своей
  /// локальной истории и, если находит, заменяет текст и помечает
  /// отредактированным. Разрешено только для СВОИХ текстовых сообщений
  /// без группы — это ограничение проверяется на UI-уровне отправителя,
  /// получатель доверяет присланному (как и всему остальному в этом
  /// протоколе — собеседник аутентифицирован Double Ratchet).
  factory InnerMessage.edit({
    required String targetMessageId,
    required String newText,
  }) {
    final body = jsonEncode({'target_id': targetMessageId, 'text': newText});
    return InnerMessage(
      messageId: _uuid.v4(),
      type: 'edit',
      sentAt: DateTime.now().millisecondsSinceEpoch,
      body: body,
    );
  }

  /// "Удалить у обоих" — список id, чтобы одним сообщением удалить сразу
  /// пачку (режим выбора). У получателя просто выпиливаются из локальной
  /// истории те id, что у него реально есть — отсутствующие тихо
  /// игнорируются.
  factory InnerMessage.delete({required List<String> targetMessageIds}) {
    final body = jsonEncode({'target_ids': targetMessageIds});
    return InnerMessage(
      messageId: _uuid.v4(),
      type: 'delete',
      sentAt: DateTime.now().millisecondsSinceEpoch,
      body: body,
    );
  }

  /// "Очистить историю у обоих" — БЕЗ списка id, безусловная команда
  /// "сотри у себя абсолютно всё в этом чате": текст, фото, видео, файлы,
  /// голосовые/видеосообщения, звонки (они тоже сообщения, см.
  /// ChatStore.addCallLog), реакции — вообще всё. Раньше для этого
  /// использовался InnerMessage.delete со списком id, снятым на СВОЕЙ
  /// стороне — но записи о звонках до недавнего времени генерировались на
  /// каждой стороне с разными id (см. историю фиксов), и даже сейчас
  /// список id может из-за этого не совпасть 1:1 — часть истории у
  /// получателя оставалась. Один безусловный сигнал этой проблемы не
  /// имеет в принципе: получателю нечего сверять, он просто чистит себя
  /// целиком (см. ChatStore.clearHistory на принимающей стороне).
  factory InnerMessage.clearChat() {
    return InnerMessage(
      messageId: _uuid.v4(),
      type: 'clear_chat',
      sentAt: DateTime.now().millisecondsSinceEpoch,
      body: '{}',
    );
  }

  /// "Удалить диалог у обоих" — тем же принципом, что и clearChat выше
  /// (безусловно, без id), но говорит получателю ещё и убрать САМ ЧАТ из
  /// списка целиком, а не просто оставить его пустым — см.
  /// ChatStore.removeChat на принимающей стороне (она и так стирает всё
  /// содержимое, отдельно посылать clearChat вдобавок не нужно).
  factory InnerMessage.deleteChat() {
    return InnerMessage(
      messageId: _uuid.v4(),
      type: 'delete_chat',
      sentAt: DateTime.now().millisecondsSinceEpoch,
      body: '{}',
    );
  }

  /// "Прочитано" — отправитель этого control-сообщения сообщает, что
  /// реально увидел перечисленные id (это ЧУЖИЕ для него сообщения — те,
  /// что он получил). У получателя control-сообщения (исходного автора
  /// этих id) статус меняется на 'read', см. ChatStore.markMessagesRead.
  factory InnerMessage.readReceipt({required List<String> targetMessageIds}) {
    final body = jsonEncode({'target_ids': targetMessageIds});
    return InnerMessage(
      messageId: _uuid.v4(),
      type: 'read_receipt',
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
    'reply_to_id': replyToMessageId,
    'reply_to_preview': replyToPreview,
  });

  static InnerMessage decode(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return InnerMessage(
      messageId: json['message_id'] as String,
      type: json['type'] as String,
      sentAt: json['sent_at'] as int,
      body: json['body'] as String,
      groupId: json['group_id'] as String?,
      replyToMessageId: json['reply_to_id'] as String?,
      replyToPreview: json['reply_to_preview'] as String?,
    );
  }
}
