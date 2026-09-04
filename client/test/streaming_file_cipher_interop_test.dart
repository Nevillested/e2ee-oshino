// Кросс-проверка формата AES-GCM для файлов: то, что зашифровано чистым
// Dart (StreamingFileCipher), обязано читаться нативным путём
// (android/.../FileCipher.kt) и наоборот. Нативный код здесь представлен
// его точным портом на Java (тот же javax.crypto / JCA, что и на Android) —
// исходник встроен ниже и компилируется на лету.
//
// Требует `java` + `javac` в PATH; иначе тест помечается skipped.
// Запуск: flutter test test/streaming_file_cipher_interop_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:oshinobu_client/crypto/streaming_file_cipher.dart';

// Порт FileCipher.kt. ЛЮБАЯ правка формата в FileCipher.kt / streaming_file_cipher.dart
// должна быть отражена и здесь — тест тогда снова станет зелёным.
const _javaSource = r'''
import java.io.*;
import java.nio.ByteBuffer;
import java.security.SecureRandom;
import java.util.Base64;
import javax.crypto.*;
import javax.crypto.spec.*;

public class Fc {
    static final int CHUNK = 4 * 1024 * 1024;
    static final int TAG_BITS = 128, TAG_BYTES = 16;
    static final long MAX_BLOCK = 64L * 1024 * 1024 + 1024;

    static byte[] nonceFor(long i) { byte[] n = new byte[12]; ByteBuffer.wrap(n).putLong(4, i); return n; }
    static byte[] aadFor(long i, boolean last) {
        return (i + ":" + (last ? 1 : 0)).getBytes(java.nio.charset.StandardCharsets.UTF_8);
    }
    static int fill(InputStream in, byte[] buf) throws IOException {
        int t = 0; while (t < buf.length) { int r = in.read(buf, t, buf.length - t); if (r < 0) break; t += r; } return t;
    }
    static void wInt(OutputStream o, int v) throws IOException {
        o.write((v>>>24)&0xFF); o.write((v>>>16)&0xFF); o.write((v>>>8)&0xFF); o.write(v&0xFF);
    }

    public static void main(String[] a) throws Exception {
        if (a[0].equals("enc")) {
            byte[] key = new byte[32]; new SecureRandom().nextBytes(key);
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            try (InputStream in = new FileInputStream(a[1]);
                 OutputStream out = new BufferedOutputStream(new FileOutputStream(a[2]))) {
                byte[] buf = new byte[CHUNK]; long idx = 0;
                while (true) {
                    int n = fill(in, buf); boolean last = n < CHUNK;
                    c.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key,"AES"), new GCMParameterSpec(TAG_BITS, nonceFor(idx)));
                    c.updateAAD(aadFor(idx, last));
                    byte[] sealed = c.doFinal(buf, 0, n);
                    wInt(out, sealed.length); out.write(sealed);
                    idx++; if (last) break;
                }
            }
            System.out.println(Base64.getEncoder().encodeToString(key));
        } else {
            byte[] key = Base64.getDecoder().decode(a[3]);
            long total = new File(a[1]).length(); long off = 0, idx = 0; boolean sawLast = false;
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            try (DataInputStream in = new DataInputStream(new BufferedInputStream(new FileInputStream(a[1])));
                 OutputStream out = new BufferedOutputStream(new FileOutputStream(a[2]))) {
                while (off < total) {
                    int len = in.readInt(); off += 4;
                    if (len < TAG_BYTES || len > MAX_BLOCK) throw new IOException("bad len " + len);
                    byte[] p = new byte[len]; in.readFully(p); off += len;
                    byte[] plain = null; boolean last = false;
                    for (boolean tryLast : new boolean[]{false, true}) {
                        try {
                            c.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key,"AES"), new GCMParameterSpec(TAG_BITS, nonceFor(idx)));
                            c.updateAAD(aadFor(idx, tryLast));
                            plain = c.doFinal(p); last = tryLast; break;
                        } catch (AEADBadTagException e) {}
                    }
                    if (plain == null) throw new IOException("block " + idx + " undecryptable");
                    out.write(plain); sawLast = last; idx++;
                }
            }
            if (!sawLast) throw new IOException("truncated");
            System.out.println("OK");
        }
    }
}
''';

void main() {
  final hasJava = Process.runSync('sh', ['-c', 'command -v java && command -v javac']).exitCode == 0;

  late Directory javaDir;

  setUpAll(() {
    if (!hasJava) return;
    javaDir = Directory.systemTemp.createTempSync('fc_java');
    File('${javaDir.path}/Fc.java').writeAsStringSync(_javaSource);
    final r = Process.runSync('javac', ['${javaDir.path}/Fc.java']);
    if (r.exitCode != 0) fail('javac Fc.java: ${r.stderr}');
  });

  tearDownAll(() {
    if (hasJava) javaDir.deleteSync(recursive: true);
  });

  String javaRun(List<String> args) {
    final r = Process.runSync('java', ['-cp', javaDir.path, 'Fc', ...args]);
    if (r.exitCode != 0) fail('java Fc ${args.first} -> ${r.exitCode}\n${r.stderr}');
    return (r.stdout as String).trim();
  }

  int javaExit(List<String> args) =>
      Process.runSync('java', ['-cp', javaDir.path, 'Fc', ...args]).exitCode;

  test('Dart <-> native(Java) AES-GCM file format interop, both directions', () async {
    if (!hasJava) {
      markTestSkipped('нет java/javac');
      return;
    }
    final tmp = Directory.systemTemp.createTempSync('fc_interop');
    addTearDown(() => tmp.deleteSync(recursive: true));

    // 2.x блока по 4 МБ — полный + полный + неполный последний
    final plain = File('${tmp.path}/plain.bin')
      ..writeAsBytesSync(
        List<int>.generate(9 * 1024 * 1024 + 123456, (i) => (i * 2654435761) & 0xFF),
      );

    // Dart шифрует -> Java читает
    final encDart = File('${tmp.path}/enc_dart.bin');
    final keyDart = await StreamingFileCipher.encryptFileToFile(
      inputFile: plain,
      outputFile: encDart,
    );
    final decByJava = File('${tmp.path}/dec_by_java.bin');
    javaRun(['dec', encDart.path, decByJava.path, base64Encode(keyDart)]);
    expect(decByJava.readAsBytesSync(), equals(plain.readAsBytesSync()),
        reason: 'Java не прочитал файл, зашифрованный Dart');

    // Java шифрует -> Dart читает
    final encJava = File('${tmp.path}/enc_java.bin');
    final keyJava = javaRun(['enc', plain.path, encJava.path]);
    final decByDart = File('${tmp.path}/dec_by_dart.bin');
    await StreamingFileCipher.decryptFileToFile(
      inputFile: encJava,
      outputFile: decByDart,
      keyBytes: base64Decode(keyJava),
    );
    expect(decByDart.readAsBytesSync(), equals(plain.readAsBytesSync()),
        reason: 'Dart не прочитал файл, зашифрованный Java');

    // обрезанный файл отвергают обе стороны
    final trunc = File('${tmp.path}/trunc.bin')
      ..writeAsBytesSync(
        encDart.readAsBytesSync().sublist(0, encDart.lengthSync() - 100),
      );
    await expectLater(
      StreamingFileCipher.decryptFileToFile(
        inputFile: trunc,
        outputFile: File('${tmp.path}/x.bin'),
        keyBytes: keyDart,
      ),
      throwsA(anything),
    );
    expect(javaExit(['dec', trunc.path, '${tmp.path}/y.bin', base64Encode(keyDart)]),
        isNot(0));
  });

  test('размер, кратный блоку -> завершающий пустой блок читается обеими сторонами', () async {
    if (!hasJava) {
      markTestSkipped('нет java/javac');
      return;
    }
    final tmp = Directory.systemTemp.createTempSync('fc_exact');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final plain = File('${tmp.path}/plain.bin')
      ..writeAsBytesSync(List<int>.filled(4 * 1024 * 1024, 7));
    final encDart = File('${tmp.path}/e.bin');
    final key = await StreamingFileCipher.encryptFileToFile(
      inputFile: plain,
      outputFile: encDart,
    );
    final decJava = File('${tmp.path}/d.bin');
    javaRun(['dec', encDart.path, decJava.path, base64Encode(key)]);
    expect(decJava.readAsBytesSync(), equals(plain.readAsBytesSync()));
  });
}
