// Совместимость ЛОКАЛЬНОГО ХРАНИЛИЩА с нативным Kotlin-клиентом
// (../client-kotlin). Kotlin-сборка ставится поверх Flutter с тем же
// applicationId и работает прямо с теми же записями secure storage — значит,
// обе стороны обязаны читать то, что пишет другая.
//
// 1. Настоящий Dart-код (ChatStore, KeyStore, SessionStore, AppLockStore,
//    SendQueueStore) заполняет мок secure storage; дамп + то, как его видит
//    Dart, пишется в vectors/storage_dart.json — Kotlin-тест сверяет.
// 2. Если есть vectors/storage_kotlin.json (его пишет Kotlin), Dart читает
//    его своими классами и сверяет с тем, что ожидал Kotlin.
//
// Запуск: flutter test test/kotlin_storage_interop_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oshinobu_client/crypto/double_ratchet.dart';
import 'package:oshinobu_client/crypto/key_store.dart';
import 'package:oshinobu_client/crypto/session_store.dart';
import 'package:oshinobu_client/services/app_lock_store.dart';
import 'package:oshinobu_client/storage/chat_store.dart';
import 'package:oshinobu_client/storage/send_queue_store.dart';
import 'package:cryptography/cryptography.dart';

const _vectorsDir = '../client-kotlin/core/src/test/resources/vectors';

Map<String, dynamic> _peerJson(ChatSummary p) => {
  'login': p.peerLogin,
  'account_id': p.lastKnownAccountId,
  'device_id': p.lastKnownDeviceId,
  'last_message': p.lastMessage,
  'last_ts': p.lastTimestamp,
  'is_deleted': p.isDeleted,
  'unread': p.unreadCount,
  'pinned_message_id': p.pinnedMessageId,
  'chat_pinned_at': p.chatPinnedAt,
  'muted': p.muted,
  'blocked_by_me': p.blockedByMe,
  'blocking_me': p.blockingMe,
  'last_is_mine': p.lastMessageIsMine,
  'last_is_read': p.lastMessageIsRead,
};

/// Как Dart видит хранилище: список чатов и история каждого чата.
Future<Map<String, dynamic>> _view() async {
  final peers = await ChatStore.getKnownPeers();
  return {
    'peers': [for (final p in peers) _peerJson(p)],
    'messages': {
      for (final p in peers)
        p.peerLogin: [
          for (final m in await ChatStore.getMessages(p.peerLogin)) m.toJson(),
        ],
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Flutter-хранилище → Kotlin', () async {
    FlutterSecureStorage.setMockInitialValues({});

    // ключи устройства — как при регистрации
    final id = await KeyStore.getOrCreateIdentityKeyPair();
    await KeyStore.getOrCreateIdentityDhKeyPair(id);
    await KeyStore.createSignedPrekey(id);
    await KeyStore.createOneTimePrekeys(3);
    await KeyStore.saveDeviceId('my-device');

    // переписка
    await ChatStore.addMessage(
      'bob',
      StoredMessage('m1', 'Привет 👋', false, 1000),
      accountId: 'acc-bob',
      incrementUnread: true,
    );
    await ChatStore.addMessage(
      'bob',
      StoredMessage(
        'm2',
        '',
        true,
        2000,
        isMedia: true,
        isFile: true,
        fileSize: 12345,
        mediaId: 'media-1',
        mediaKeyBase64: 'a2V5',
        fileName: 'отчёт.pdf',
        status: 'sending',
        processingStep: 'шифрование',
        groupId: 'g1',
      ),
    );
    await ChatStore.updateMessageStatus('bob', 'm2', 'sent');
    await ChatStore.setReaction('bob', 'm1', isMine: true, emoji: '❤️');
    await ChatStore.editMessageText('bob', 'm1', 'Привет! (изм.)');
    await ChatStore.addCallLog(
      'bob',
      direction: 'incoming',
      outcome: 'missed',
      timestamp: 3000,
      callId: 'call-1',
    );
    await ChatStore.addUndecryptableNotice('bob', id: 'undecryptable_x', timestamp: 3500);
    await ChatStore.addMessage('bob', StoredMessage('m3', 'удалю', true, 4000));
    await ChatStore.deleteMessages('bob', ['m3', 'ghost']); // ghost → надгробие
    await ChatStore.setPinned('bob', 'm1');
    await ChatStore.markMessagesRead('bob', ['m2']);

    await ChatStore.addMessage('carol', StoredMessage('c1', 'hi', true, 500, status: 'read'));
    await ChatStore.setChatPinned('carol', true);
    await ChatStore.setChatMuted('carol', true);
    // чат «Заметки» Flutter-сборки — Kotlin обязан его скрыть
    await ChatStore.addMessage(notesPeerLogin, StoredMessage('n1', 'заметка', true, 9000));

    // прочее
    final ratchet = await RatchetState.initAsSender(
      rootKey: List.filled(32, 5),
      ephemeralKeyPair: await X25519().newKeyPair(),
    );
    await ratchet.nextSendingKey();
    await SessionStore.saveState('peer-device', ratchet);
    await AppLockStore.setPin('2580');
    await SendQueueStore.add(
      id: 'q1',
      toDeviceId: 'peer-device',
      envelope: {'nonce': 'n', 'message_number': 1},
      messageId: 'm2',
      peerLogin: 'bob',
    );

    final dump = await const FlutterSecureStorage().readAll();
    final out = {
      'secure': dump,
      'view': await _view(),
      'ratchet_json': await ratchet.toJson(),
      'pin': '2580',
    };
    Directory(_vectorsDir).createSync(recursive: true);
    File('$_vectorsDir/storage_dart.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
  });

  test('Kotlin-хранилище → Flutter', () async {
    final file = File('$_vectorsDir/storage_kotlin.json');
    if (!file.existsSync()) {
      markTestSkipped('нет storage_kotlin.json — сначала запусти Kotlin-тесты');
      return;
    }
    final t = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    FlutterSecureStorage.setMockInitialValues(
      (t['secure'] as Map).cast<String, String>(),
    );
    final view = await _view();
    expect(view, t['view'], reason: 'Dart видит хранилище Kotlin иначе');
    expect(await AppLockStore.verifyPin(t['pin'] as String), isTrue);
    expect(await AppLockStore.verifyPin('0000'), isFalse);
    expect(await KeyStore.getStoredDeviceId(), t['device_id']);
    final spk = await KeyStore.getStoredSignedPrekeyPair();
    expect(spk, isNotNull);
    final state = await SessionStore.getState('peer-device');
    expect(await state!.toJson(), t['ratchet_json']);
    final queue = await SendQueueStore.getAll();
    expect(queue.map((e) => e['id']).toList(), ['q1']);
  });
}
