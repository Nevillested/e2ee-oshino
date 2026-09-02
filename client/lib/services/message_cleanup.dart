import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../storage/chat_store.dart';
import '../storage/chunked_upload_session_store.dart';
import '../storage/media_cache.dart';
import '../storage/pending_send_store.dart';
import '../storage/send_queue_store.dart';
import 'debug_log.dart';
import 'send_ack_registry.dart';
import 'upload_cancel_registry.dart';

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
  // См. StoredMessage.localSourcePath — тот же принцип, что и у
  // localPreviewPath выше, просто для видео/файла/голосового/видео-заметки.
  final localSource = msg.localSourcePath;
  if (localSource != null) {
    try {
      final file = File(localSource);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  // Незавершённая докачка большого файла по кусочкам (media_upload.dart) —
  // локальная зашифрованная копия и запись о сессии на сервере (media_id/
  // upload_id). Сам объект в MinIO (частично залитый) здесь не отменяем —
  // это не потеря данных, только временно занятое место; она вычищается
  // lifecycle-политикой бакета на стороне инфраструктуры (см. комментарий
  // в upload_media_chunked.go на сервере), не стоит рисковать сетевым
  // вызовом (нужен токен, которого здесь нет) в и без того "путь удаления".
  final chunkedSession = await ChunkedUploadSessionStore.get(msg.messageId);
  if (chunkedSession != null) {
    await ChunkedUploadSessionStore.clear(msg.messageId);
    try {
      final appDir = await getApplicationSupportDirectory();
      final encTempFile = File(
        '${appDir.path}/chunked_uploads/enc_${msg.messageId}.bin',
      );
      if (await encTempFile.exists()) await encTempFile.delete();
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

/// Отмена ещё не ушедшего исходящего сообщения(й) — «✕» на пузыре в чате
/// ИЛИ на строке в панели передач. Прерывает активную загрузку, чистит
/// все следы (кэш/очереди/задания) и удаляет сами записи из ChatStore.
/// Общая точка для ChatScreen._cancelSend и панели передач.
Future<void> cancelOutgoingMessages(
  String peerLogin,
  List<String> messageIds,
) async {
  for (final id in messageIds) {
    UploadCancelRegistry.cancel(id);
  }
  final all = await ChatStore.getMessages(peerLogin);
  final toPurge = all.where((m) => messageIds.contains(m.messageId)).toList();
  await ChatStore.deleteMessages(peerLogin, messageIds);
  await purgeAllMessageArtifacts(toPurge);
}
