import 'dart:io';
import '../storage/chat_store.dart';
import '../storage/media_cache.dart';
import '../storage/pending_send_store.dart';
import '../storage/send_queue_store.dart';
import 'debug_log.dart';
import 'send_ack_registry.dart';

/// Полная зачистка ВСЕХ следов одного сообщения на диске/в очередях —
/// не только запись в ChatStore (её удаляет вызывающий код отдельно), но и
/// расшифрованный кэш, локальный кадр-превью, задание в офлайн-очереди
/// (PendingSendStore) и надёжная очередь доставки (SendQueueStore/
/// SendAckRegistry). ТЗ пользователя: удаление сообщения — это полный
/// сброс к состоянию "как будто его никогда не было", а не просто исчез
/// пузырь из списка — иначе повторная попытка того же файла могла бы
/// наткнуться на осевший где-то старый кэш/задание.
///
/// Единая точка для ЛЮБОГО источника удаления — локального (ChatScreen),
/// пришедшего от собеседника (MessageRouter: 'delete'/clear_history/
/// remove_chat control-сообщения) и удаления всего чата из списка
/// (HomePlaceholderScreen) — вызывать ДО того, как сама запись пропадёт
/// из ChatStore (иначе mediaId/groupId/localPreviewPath уже будет неоткуда
/// взять).
Future<void> purgeMessageArtifacts(StoredMessage msg) async {
  final mediaId = msg.mediaId;
  if (mediaId != null) {
    await MediaCache.delete(mediaId);
  }
  final localPreview = msg.localPreviewPath;
  if (localPreview != null) {
    try {
      final file = File(localPreview);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  // Задание может лежать под groupId (вся группа целиком) и/или под
  // собственным messageId (одиночное сообщение, либо старое задание,
  // заведённое до появления группового пути) — чистим оба ключа, remove()
  // на отсутствующем id — тихий no-op.
  final keys = <String>{msg.messageId, if (msg.groupId != null) msg.groupId!};
  for (final key in keys) {
    await PendingSendStore.remove(key);
    await SendQueueStore.remove(key);
    SendAckRegistry.cancel(key);
  }

  DebugLog.log(
    'purgeMessageArtifacts messageId=${msg.messageId} '
    'mediaId=${mediaId ?? '-'} groupId=${msg.groupId ?? '-'}',
  );
}

/// То же самое сразу для целого списка сообщений (массовое удаление,
/// очистка истории, удаление чата) — просто последовательно по каждому.
Future<void> purgeAllMessageArtifacts(Iterable<StoredMessage> messages) async {
  for (final msg in messages) {
    await purgeMessageArtifacts(msg);
  }
}
