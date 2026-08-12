import 'dart:async';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class NoteMessage {
  final String id;
  final String text;
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
  final String? groupId;

  NoteMessage(
    this.id,
    this.text,
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
    this.groupId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
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
        'group_id': groupId,
      };

  static NoteMessage fromJson(Map<String, dynamic> j) => NoteMessage(
        j['id'] as String,
        j['text'] as String,
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
        groupId: j['group_id'] as String?,
      );
}

/// Заметки — локальный "чат с самим собой". Текст хранится ТОЛЬКО
/// локально, шифрованный собственным ключом в flutter_secure_storage —
/// это постоянное хранилище (не кэш), обычная очистка кэша Android его
/// не трогает. Медиафайлы дополнительно грузятся на сервер (получатель —
/// сам владелец аккаунта, без какой-либо сетевой доставки/уведомления) —
/// это именно бэкап на случай очистки кэша: если MediaCache сотрут,
/// файл всё равно можно скачать с сервера заново, точно так же, как
/// большие файлы в обычных чатах.
class NotesStore {
  static const _storage = FlutterSecureStorage();
  static const _notesKey = 'notes_encrypted';
  static const _notesKeyKeyName = 'notes_encryption_key';
  static final _aesGcm = AesGcm.with256bits();
  static final _changesController = StreamController<void>.broadcast();
  static Stream<void> get changes => _changesController.stream;

  static Future<List<int>> _getOrCreateKey() async {
    final stored = await _storage.read(key: _notesKeyKeyName);
    if (stored != null) return base64Decode(stored);
    final key = await _aesGcm.newSecretKey();
    final bytes = await key.extractBytes();
    await _storage.write(key: _notesKeyKeyName, value: base64Encode(bytes));
    return bytes;
  }

  static Future<List<NoteMessage>> getAll() async {
    final stored = await _storage.read(key: _notesKey);
    if (stored == null) return [];

    final key = await _getOrCreateKey();
    final envelope = jsonDecode(stored) as Map<String, dynamic>;
    final secretBox = SecretBox(
      base64Decode(envelope['ciphertext'] as String),
      nonce: base64Decode(envelope['nonce'] as String),
      mac: Mac(base64Decode(envelope['mac'] as String)),
    );
    final plainBytes = await _aesGcm.decrypt(secretBox, secretKey: SecretKey(key));
    final list = jsonDecode(utf8.decode(plainBytes)) as List<dynamic>;
    return list.map((e) => NoteMessage.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<void> _saveAll(List<NoteMessage> notes) async {
    final key = await _getOrCreateKey();
    final plainBytes = utf8.encode(jsonEncode(notes.map((n) => n.toJson()).toList()));
    final secretBox = await _aesGcm.encrypt(plainBytes, secretKey: SecretKey(key));

    await _storage.write(
      key: _notesKey,
      value: jsonEncode({
        'nonce': base64Encode(secretBox.nonce),
        'ciphertext': base64Encode(secretBox.cipherText),
        'mac': base64Encode(secretBox.mac.bytes),
      }),
    );
    _changesController.add(null);
  }

  static Future<({String lastMessage, int lastTimestamp})> getSummary() async {
    final notes = await getAll();
    if (notes.isEmpty) return (lastMessage: '', lastTimestamp: 0);
    final last = notes.last;
    return (
      lastMessage: last.isMedia ? (last.isFile ? (last.fileName ?? '📎 Файл') : '📷 Фото') : last.text,
      lastTimestamp: last.timestamp,
    );
  }

  static Future<void> addText(String text, {String? groupId}) async {
    final notes = await getAll();
    notes.add(NoteMessage(
      DateTime.now().microsecondsSinceEpoch.toString(),
      text,
      DateTime.now().millisecondsSinceEpoch,
      groupId: groupId,
    ));
    await _saveAll(notes);
  }

  /// Добавляет заметку с медиа СРАЗУ, со статусом 'sending' и локальным
  /// превью — реальная загрузка на сервер происходит отдельно, позже.
  static Future<void> addPendingMedia(NoteMessage note) async {
    final notes = await getAll();
    notes.add(note);
    await _saveAll(notes);
  }

  static Future<void> _replace(String id, NoteMessage Function(NoteMessage old) update) async {
    final notes = await getAll();
    final index = notes.indexWhere((n) => n.id == id);
    if (index == -1) return;
    notes[index] = update(notes[index]);
    await _saveAll(notes);
  }

  static Future<void> updateStatus(String id, String newStatus) {
    return _replace(id, (old) => NoteMessage(
          old.id, old.text, old.timestamp,
          isMedia: old.isMedia, isFile: old.isFile, fileSize: old.fileSize, chunked: old.chunked,
          mediaId: old.mediaId, mediaKeyBase64: old.mediaKeyBase64, mediaNonceBase64: old.mediaNonceBase64,
          mediaMacBase64: old.mediaMacBase64, fileName: old.fileName, status: newStatus,
          processingStep: (newStatus == 'sent' || newStatus == 'failed') ? null : old.processingStep,
          localPreviewPath: old.localPreviewPath,
          groupId: old.groupId,
        ));
  }

  static Future<void> updateProcessingStep(String id, String step) {
    return _replace(id, (old) => NoteMessage(
          old.id, old.text, old.timestamp,
          isMedia: old.isMedia, isFile: old.isFile, fileSize: old.fileSize, chunked: old.chunked,
          mediaId: old.mediaId, mediaKeyBase64: old.mediaKeyBase64, mediaNonceBase64: old.mediaNonceBase64,
          mediaMacBase64: old.mediaMacBase64, fileName: old.fileName, status: old.status,
          processingStep: step,
          localPreviewPath: old.localPreviewPath,
          groupId: old.groupId,
        ));
  }

  static Future<void> updateMediaInfo(
    String id, {
    required String mediaId,
    required String keyBase64,
    String? nonceBase64,
    String? macBase64,
  }) {
    return _replace(id, (old) => NoteMessage(
          old.id, old.text, old.timestamp,
          isMedia: old.isMedia, isFile: old.isFile, fileSize: old.fileSize, chunked: old.chunked,
          mediaId: mediaId, mediaKeyBase64: keyBase64, mediaNonceBase64: nonceBase64,
          mediaMacBase64: macBase64, fileName: old.fileName, status: old.status,
          processingStep: old.processingStep,
          localPreviewPath: old.localPreviewPath,
          groupId: old.groupId,
        ));
  }
}