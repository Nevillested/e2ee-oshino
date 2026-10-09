// Совместимость протокола с нативным Kotlin-клиентом (../client-kotlin).
//
// 1. Прогоняет НАСТОЯЩИЙ Dart-код (KeyStore, X3DH, RatchetState,
//    encryptMessage, InnerMessage, шифры файлов) на переписке двух
//    собеседников — с X3DH, ответами в обе стороны (смена эпох ratchet),
//    сообщениями не по порядку и дублем — и пишет стенограмму в
//    client-kotlin/core/src/test/resources/vectors/dart_transcript.json.
//    Kotlin-тест DartInteropTest обязан её расшифровать и получить то же
//    состояние ratchet после каждого шага.
// 2. Если рядом лежит kotlin_transcript.json (его пишет Kotlin-тест), — та
//    же проверка в обратную сторону: Dart расшифровывает то, что
//    зашифровал Kotlin.
//
// Запуск: flutter test test/kotlin_interop_test.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oshinobu_client/crypto/double_ratchet.dart';
import 'package:oshinobu_client/crypto/key_store.dart';
import 'package:oshinobu_client/crypto/media_cipher.dart';
import 'package:oshinobu_client/crypto/message_cipher.dart';
import 'package:oshinobu_client/crypto/message_envelope.dart';
import 'package:oshinobu_client/crypto/streaming_file_cipher.dart';
import 'package:oshinobu_client/crypto/x3dh.dart';

const _vectorsDir = '../client-kotlin/core/src/test/resources/vectors';

/// Выполняет [fn] "от имени" устройства с secure storage [store] — KeyStore
/// статический и один на процесс, поэтому двух собеседников изображаем,
/// подменяя содержимое мок-хранилища. Возвращает хранилище после [fn].
Future<Map<String, String>> _asParty(
  Map<String, String> store,
  Future<void> Function() fn,
) async {
  FlutterSecureStorage.setMockInitialValues(Map.of(store));
  await fn();
  return const FlutterSecureStorage().readAll();
}

Map<String, dynamic> _wire(Map<String, dynamic> m) =>
    jsonDecode(jsonEncode(m)) as Map<String, dynamic>;

Future<Map<String, dynamic>> _snapshot(RatchetState s) async =>
    _wire(await s.toJson());

Future<Map<String, dynamic>> _seal(
  RatchetState state,
  InnerMessage inner,
  String myDeviceId,
  Map<String, dynamic>? initHeader,
) async {
  // ровно как services/peer_messenger.dart
  final next = await state.nextSendingKey();
  final headerFields = <String, dynamic>{
    ...next.header,
    'sender_device_id': myDeviceId,
    if (initHeader != null) ...initHeader,
  };
  final encrypted = await encryptMessage(
    next.messageKey,
    inner.encode(),
    aad: headerFields,
  );
  return _wire({...encrypted, ...headerFields});
}

Future<RatchetState> _x3dhIncoming(
  Map<String, String> receiverStore,
  Map<String, dynamic> envelope,
) async {
  List<int>? root;
  await _asParty(receiverStore, () async {
    root = await establishIncomingSessionRaw(envelope);
  });
  expect(root, isNotNull, reason: 'X3DH-инициализация не принята');
  return RatchetState.initAsReceiver(
    rootKey: root!,
    remoteEphemeralPubkey: base64Decode(envelope['ephemeral_pubkey'] as String),
  );
}

Map<String, dynamic> _withoutSendingKeys(Map<String, dynamic> s) =>
    Map.of(s)
      ..remove('sending_ratchet_private')
      ..remove('sending_ratchet_public');

/// Проверка стенограммы (общий формат для Dart- и Kotlin-стороны).
Future<void> _verifyTranscript(Map<String, dynamic> t, String source) async {
  final bobStore = (t['bob_store'] as Map).cast<String, String>();
  final steps = t['steps'] as List<dynamic>;
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i] as Map<String, dynamic>;
    final env = step['envelope'] as Map<String, dynamic>;
    final before = step['state_before'] as Map<String, dynamic>?;
    final state = before == null
        ? await _x3dhIncoming(bobStore, env)
        : RatchetState.fromJson(before);

    if (step['expect'] == 'already_processed') {
      await expectLater(
        state.nextReceivingKey(env),
        throwsA(isA<AlreadyProcessedException>()),
        reason: '$source шаг $i: ожидался дубль',
      );
      continue;
    }

    final key = await state.nextReceivingKey(env);
    final raw = await decryptMessage(key, env);
    final got = InnerMessage.decode(raw);
    final want = InnerMessage.decode(step['inner'] as String);
    expect(got.encode(), want.encode(), reason: '$source шаг $i: текст');

    final after = await _snapshot(state);
    final wantAfter = step['state_after'] as Map<String, dynamic>;
    if (before == null) {
      // у новой входящей сессии своя случайная sending-пара — её не сравниваем
      expect(_withoutSendingKeys(after), _withoutSendingKeys(wantAfter),
          reason: '$source шаг $i: состояние после X3DH');
    } else {
      expect(after, wantAfter, reason: '$source шаг $i: состояние');
    }
  }

  for (final m in t['media'] as List<dynamic>) {
    final v = m as Map<String, dynamic>;
    final plain = await decryptFileBytes(
      key: base64Decode(v['key'] as String),
      nonce: base64Decode(v['nonce'] as String),
      mac: base64Decode(v['mac'] as String),
      ciphertext: base64Decode(v['ciphertext'] as String),
    );
    expect(base64Encode(plain), v['plain'], reason: '$source media');
  }

  final tmp = await Directory.systemTemp.createTemp('oshinobu_interop');
  try {
    var n = 0;
    for (final m in t['streaming'] as List<dynamic>) {
      final v = m as Map<String, dynamic>;
      final enc = File('${tmp.path}/s$n.enc')
        ..writeAsBytesSync(base64Decode(v['file'] as String));
      final out = File('${tmp.path}/s$n.out');
      await StreamingFileCipher.decryptFileToFile(
        inputFile: enc,
        outputFile: out,
        keyBytes: base64Decode(v['key'] as String),
      );
      expect(base64Encode(out.readAsBytesSync()), v['plain'],
          reason: '$source streaming $n');
      n++;
    }
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Dart → Kotlin: стенограмма из настоящего Dart-кода', () async {
    // --- Bob: полный набор ключей, как при регистрации устройства ---
    late Map<String, dynamic> bundle;
    final bobStore = await _asParty({}, () async {
      final id = await KeyStore.getOrCreateIdentityKeyPair();
      final dh = await KeyStore.getOrCreateIdentityDhKeyPair(id);
      final spk = await KeyStore.createSignedPrekey(id);
      final otps = await KeyStore.createOneTimePrekeys(2);
      await KeyStore.saveDeviceId('bob-device');
      bundle = {
        'identity_pubkey': base64Encode((await id.extractPublicKey()).bytes),
        'identity_dh_pubkey':
            base64Encode((await dh.keyPair.extractPublicKey()).bytes),
        'identity_dh_signature': base64Encode(dh.signature),
        'signed_prekey': base64Encode(spk.publicKey),
        'signature': base64Encode(spk.signature),
        'one_time_prekey': base64Encode(otps[0]),
      };
    });

    // --- Alice начинает сессию ---
    late X3dhOutgoing outgoing;
    await _asParty({}, () async {
      await KeyStore.saveDeviceId('alice-device');
      outgoing = await establishOutgoingRoot(
        bundle: bundle,
        myDeviceId: 'alice-device',
      );
    });
    final alice = await RatchetState.initAsSender(
      rootKey: outgoing.rootKey,
      ephemeralKeyPair: outgoing.ephemeralKeyPair,
    );

    final steps = <Map<String, dynamic>>[];
    late RatchetState bob;
    var bobStoreLive = Map.of(bobStore);

    Future<void> deliver(
      String receiver,
      Map<String, dynamic> env,
      InnerMessage inner,
    ) async {
      Map<String, dynamic>? before;
      if (receiver == 'bob' && env['ephemeral_pubkey'] != null) {
        List<int>? root;
        bobStoreLive = await _asParty(bobStoreLive, () async {
          root = await establishIncomingSessionRaw(env);
        });
        bob = await RatchetState.initAsReceiver(
          rootKey: root!,
          remoteEphemeralPubkey: base64Decode(env['ephemeral_pubkey'] as String),
        );
      } else {
        before = await _snapshot(receiver == 'bob' ? bob : alice);
      }
      final st = receiver == 'bob' ? bob : alice;
      final key = await st.nextReceivingKey(env);
      final raw = await decryptMessage(key, env);
      expect(raw, inner.encode());
      steps.add({
        'receiver': receiver,
        'state_before': before,
        'envelope': env,
        'inner': inner.encode(),
        'state_after': await _snapshot(st),
      });
    }

    final m1 = InnerMessage.text('Привет! 👋 первая весточка');
    final m2 = InnerMessage.reaction(targetMessageId: m1.messageId, emoji: '❤️');
    final m3 = InnerMessage.media(
      mediaId: '0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0',
      keyBase64: base64Encode(List.filled(32, 7)),
      nonceBase64: base64Encode(List.filled(12, 1)),
      macBase64: base64Encode(List.filled(16, 2)),
      fileName: 'фото.jpg',
      fileSize: 123456,
      spoiler: true,
    );
    final e1 = await _seal(alice, m1, 'alice-device', outgoing.initHeader);
    final e2 = await _seal(alice, m2, 'alice-device', null);
    final e3 = await _seal(alice, m3, 'alice-device', null);
    await deliver('bob', e1, m1);
    await deliver('bob', e3, m3); // не по порядку: e2 уходит в skipped
    await deliver('bob', e2, m2);
    // e3 ещё раз — дубль в той же эпохе
    steps.add({
      'receiver': 'bob',
      'state_before': await _snapshot(bob),
      'envelope': e3,
      'expect': 'already_processed',
    });

    final r1 = InnerMessage.readReceipt(targetMessageIds: [m1.messageId, m3.messageId]);
    final r2 = InnerMessage.text('ответ', replyToMessageId: m1.messageId, replyToPreview: 'Привет!');
    final f1 = await _seal(bob, r1, 'bob-device', null);
    final f2 = await _seal(bob, r2, 'bob-device', null);
    await deliver('alice', f2, r2);
    await deliver('alice', f1, r1);

    final m4 = InnerMessage.edit(targetMessageId: m1.messageId, newText: 'исправлено');
    await deliver('bob', await _seal(alice, m4, 'alice-device', null), m4);
    final r3 = InnerMessage.delete(targetMessageIds: [r2.messageId]);
    await deliver('alice', await _seal(bob, r3, 'bob-device', null), r3);

    // --- шифры файлов ---
    final media = <Map<String, dynamic>>[];
    for (final plain in [
      Uint8List.fromList(utf8.encode('hello')),
      Uint8List.fromList(List.generate(1000, (i) => (i * 31) & 0xFF)),
    ]) {
      final enc = await encryptFileBytes(plain);
      media.add({
        'plain': base64Encode(plain),
        'key': base64Encode(enc.key),
        'nonce': base64Encode(enc.nonce),
        'mac': base64Encode(enc.mac),
        'ciphertext': base64Encode(enc.ciphertext),
      });
    }
    final streaming = <Map<String, dynamic>>[];
    final tmp = await Directory.systemTemp.createTemp('oshinobu_interop');
    try {
      for (final size in [0, 100]) {
        final plain = Uint8List.fromList(List.generate(size, (i) => (i * 7) & 0xFF));
        final inFile = File('${tmp.path}/p$size')..writeAsBytesSync(plain);
        final outFile = File('${tmp.path}/e$size');
        final key = await StreamingFileCipher.encryptFileToFile(
          inputFile: inFile,
          outputFile: outFile,
        );
        streaming.add({
          'plain': base64Encode(plain),
          'key': base64Encode(key),
          'file': base64Encode(outFile.readAsBytesSync()),
        });
      }
    } finally {
      tmp.deleteSync(recursive: true);
    }

    final transcript = {
      'bob_store': bobStore,
      'bob_bundle': bundle,
      'steps': steps,
      'media': media,
      'streaming': streaming,
    };
    // сначала сами себя: формат стенограммы проверяем тем же верификатором
    await _verifyTranscript(_wire(transcript), 'dart');

    Directory(_vectorsDir).createSync(recursive: true);
    File('$_vectorsDir/dart_transcript.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(transcript),
    );
  });

  test('Kotlin → Dart: Dart расшифровывает то, что зашифровал Kotlin', () async {
    final file = File('$_vectorsDir/kotlin_transcript.json');
    if (!file.existsSync()) {
      markTestSkipped('нет kotlin_transcript.json — сначала запусти Kotlin-тесты');
      return;
    }
    final t = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    await _verifyTranscript(t, 'kotlin');
  });
}
