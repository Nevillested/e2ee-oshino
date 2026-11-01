// Формат протокола на проводе и на диске зафиксирован: protocol_transcript.json —
// та же стенограмма, что в тестах Android (конверты, состояния ratchet до и после
// каждого шага, зашифрованные вложения). Если тест зелёный — Linux-клиент
// понимает Android и iOS байт в байт. Упал — формат поехал.

#include "crypto/FileCiphers.h"
#include "crypto/MessageCipher.h"
#include "crypto/StoredIdentity.h"
#include "protocol/PeerCipher.h"
#include "support/Json.h"

#include <QFile>
#include <QTemporaryDir>
#include <QtTest>

using namespace osh;

namespace {

QJsonObject withoutSendingKeys(QJsonObject s) {
    s.remove("sending_ratchet_private");
    s.remove("sending_ratchet_public");
    return s;
}

QMap<QString, QString> toStringMap(const QJsonObject &o) {
    QMap<QString, QString> m;
    for (auto it = o.begin(); it != o.end(); ++it) m[it.key()] = it.value().toString();
    return m;
}

QByteArray f(const QJsonObject &o, const char *name) { return unb64(json::string(o, name)); }

void verifyTranscript(const QJsonObject &t, const QString &source) {
    const auto bobStore = toStringMap(t.value("bob_store").toObject());
    const QJsonArray steps = t.value("steps").toArray();
    for (int i = 0; i < steps.size(); ++i) {
        const QJsonObject step = steps[i].toObject();
        const QJsonObject env = step.value("envelope").toObject();
        const QJsonValue beforeV = step.value("state_before");
        const QString where = QStringLiteral("%1 шаг %2").arg(source).arg(i);

        std::optional<RatchetState> state;
        if (beforeV.isNull() || beforeV.isUndefined()) {
            const auto me = StoredIdentity::fromStore(bobStore);
            QVERIFY2(me.has_value(), qPrintable(where));
            auto incoming = PeerCipher::startIncomingSession(env, *me);
            QVERIFY2(incoming.has_value(), qPrintable(where));
            state.emplace(std::move(incoming->first));
        } else {
            // формат состояния: JSON → объект → тот же JSON
            state.emplace(RatchetState::fromJson(beforeV.toObject()));
            QVERIFY2(state->toJson() == beforeV.toObject(), qPrintable(where + ": JSON состояния"));
        }

        if (step.value("expect").toString() == "already_processed") {
            QVERIFY_EXCEPTION_THROWN(state->nextReceivingKey(env), AlreadyProcessedError);
            continue;
        }

        const InnerMessage got = InnerMessage::decode(decryptMessage(state->nextReceivingKey(env), env));
        const InnerMessage want = InnerMessage::decode(json::string(step, "inner"));
        QVERIFY2(got == want, qPrintable(where + ": текст"));

        const QJsonObject after = state->toJson();
        const QJsonObject wantAfter = step.value("state_after").toObject();
        if (beforeV.isNull() || beforeV.isUndefined()) {
            QVERIFY2(withoutSendingKeys(after) == withoutSendingKeys(wantAfter), qPrintable(where + ": состояние после X3DH"));
        } else {
            QVERIFY2(after == wantAfter, qPrintable(where + ": состояние"));
        }
    }

    for (const QJsonValue &v : t.value("media").toArray()) {
        const QJsonObject m = v.toObject();
        QCOMPARE(MediaCipher::decrypt(f(m, "key"), f(m, "nonce"), f(m, "mac"), f(m, "ciphertext")), f(m, "plain"));
    }

    QTemporaryDir tmp;
    QVERIFY(tmp.isValid());
    const QJsonArray streaming = t.value("streaming").toArray();
    for (int n = 0; n < streaming.size(); ++n) {
        const QJsonObject s = streaming[n].toObject();
        const QString enc = tmp.filePath(QStringLiteral("s%1.enc").arg(n));
        const QString out = tmp.filePath(QStringLiteral("s%1.out").arg(n));
        QFile e(enc);
        QVERIFY(e.open(QIODevice::WriteOnly));
        e.write(f(s, "file"));
        e.close();
        StreamingFileCipher::decryptFile(enc, out, f(s, "key"));
        QFile o(out);
        QVERIFY(o.open(QIODevice::ReadOnly));
        QCOMPARE(o.readAll(), f(s, "plain"));
    }
}

} // namespace

class ProtocolVectorsTest : public QObject {
    Q_OBJECT

private Q_SLOTS:
    void fixedTranscriptDecryptsStepByStep() {
        QFile file(QStringLiteral(VECTORS_DIR "/protocol_transcript.json"));
        QVERIFY(file.open(QIODevice::ReadOnly));
        verifyTranscript(json::parseObject(file.readAll()), "vectors");
    }

    /// Своя стенограмма (Linux ↔ Linux) проходит ту же проверку.
    void ownTranscriptPassesSameChecks() {
        StoredIdentity bob = StoredIdentity::generate(QStringLiteral("bob-device"), 2);
        const auto bobStore = bob.toStore();
        const QJsonObject bundle = bob.bundle();
        const StoredIdentity aliceId = StoredIdentity::generate(QStringLiteral("alice-device"));

        auto [alice, initHeader] = PeerCipher::startOutgoingSession(bundle, "alice-device", aliceId.identityDh());
        std::optional<RatchetState> bobState;
        StoredIdentity bobLive = *StoredIdentity::fromStore(bobStore);
        QJsonArray steps;

        auto deliver = [&](const QString &receiver, const QJsonObject &env, const InnerMessage &inner) {
            QJsonValue before = QJsonValue::Null;
            if (receiver == "bob" && env.contains("ephemeral_pubkey")) {
                auto incoming = PeerCipher::startIncomingSession(env, bobLive);
                QVERIFY(incoming.has_value());
                if (incoming->second.consumedOneTimePrekey) bobLive.deleteOneTimePrekey(*incoming->second.consumedOneTimePrekey);
                bobState.emplace(std::move(incoming->first));
            } else {
                before = (receiver == "bob" ? *bobState : alice).toJson();
            }
            RatchetState &st = receiver == "bob" ? *bobState : alice;
            QVERIFY(PeerCipher::open(st, env) == inner);
            steps.append(QJsonObject{{"receiver", receiver}, {"state_before", before}, {"envelope", env}, {"inner", inner.encode()},
                                     {"state_after", st.toJson()}});
        };

        const InnerMessage m1 = InnerMessage::text(QStringLiteral("Привет из Linux! 🐧"));
        const InnerMessage m2 = InnerMessage::reaction(m1.messageId, QStringLiteral("👍"));
        const InnerMessage m3 = InnerMessage::media(MediaRef{"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", b64(QByteArray(32, 9)), b64(QByteArray(12, 3)),
                                                             b64(QByteArray(16, 4)), 4242, false},
                                                    QStringLiteral("документ.pdf"), true);
        const QJsonObject e1 = PeerCipher::seal(alice, m1, "alice-device", initHeader);
        const QJsonObject e2 = PeerCipher::seal(alice, m2, "alice-device");
        const QJsonObject e3 = PeerCipher::seal(alice, m3, "alice-device");
        deliver("bob", e1, m1);
        deliver("bob", e3, m3);
        deliver("bob", e2, m2);
        steps.append(QJsonObject{{"receiver", "bob"}, {"state_before", bobState->toJson()}, {"envelope", e3}, {"expect", "already_processed"}});

        const InnerMessage r1 = InnerMessage::readReceipt({m1.messageId, m3.messageId});
        const InnerMessage r2 = InnerMessage::text(QStringLiteral("ответ"), m1.messageId, QStringLiteral("Привет"));
        const QJsonObject f1 = PeerCipher::seal(*bobState, r1, "bob-device");
        const QJsonObject f2 = PeerCipher::seal(*bobState, r2, "bob-device");
        deliver("alice", f2, r2);
        deliver("alice", f1, r1);

        const InnerMessage m4 = InnerMessage::edit(m1.messageId, QStringLiteral("исправлено"));
        deliver("bob", PeerCipher::seal(alice, m4, "alice-device"), m4);
        const InnerMessage r3 = InnerMessage::remove({r2.messageId});
        deliver("alice", PeerCipher::seal(*bobState, r3, "bob-device"), r3);

        QJsonArray media;
        for (const QByteArray &plain : {QByteArray("hello"), QByteArray(1000, 'x')}) {
            const EncryptedFile enc = MediaCipher::encrypt(plain);
            media.append(QJsonObject{{"plain", b64(plain)}, {"key", b64(enc.key)}, {"nonce", b64(enc.nonce)}, {"mac", b64(enc.mac)},
                                     {"ciphertext", b64(enc.ciphertext)}});
        }

        QTemporaryDir tmp;
        QJsonArray streaming;
        // 0 байт, 100 байт и ровно 4 МБ (кратный файл — с пустым завершающим блоком)
        for (qint64 size : {qint64(0), qint64(100), StreamingFileCipher::ChunkSize}) {
            QByteArray plain(size, '\0');
            for (qint64 i = 0; i < size; ++i) plain[i] = char(i * 7);
            const QString in = tmp.filePath(QStringLiteral("p%1").arg(size));
            const QString out = tmp.filePath(QStringLiteral("e%1").arg(size));
            QFile p(in);
            QVERIFY(p.open(QIODevice::WriteOnly));
            p.write(plain);
            p.close();
            const QByteArray key = StreamingFileCipher::encryptFile(in, out);
            QFile e(out);
            QVERIFY(e.open(QIODevice::ReadOnly));
            streaming.append(QJsonObject{{"plain", b64(plain)}, {"key", b64(key)}, {"file", b64(e.readAll())}});
        }

        QJsonObject storeJson;
        for (auto it = bobStore.begin(); it != bobStore.end(); ++it) storeJson.insert(it.key(), it.value());
        const QJsonObject transcript{{"bob_store", storeJson}, {"bob_bundle", bundle}, {"steps", steps}, {"media", media}, {"streaming", streaming}};
        verifyTranscript(json::parseObject(json::compact(transcript)), "self");
    }

    void aadIsFixedFormat() {
        const QByteArray aad = buildAad(QJsonObject{
            {"ratchet_pubkey", "UFVC"},
            {"message_number", 7},
            {"sender_device_id", "dev"},
            {"used_one_time_prekey", QJsonValue::Null},
        });
        QCOMPARE(QString::fromUtf8(aad), QStringLiteral("sender_device_id=dev|ratchet_pubkey=UFVC|message_number=7|ephemeral_pubkey=null|"
                                                        "sender_identity_dh_pubkey=null|used_one_time_prekey=null"));
    }

    void x25519AgreesAndDerivesPublic() {
        const X25519KeyPair a = X25519KeyPair::generate();
        const X25519KeyPair b = X25519KeyPair::generate();
        QCOMPARE(a.sharedSecret(b.publicKey), b.sharedSecret(a.publicKey));
        QCOMPARE(X25519KeyPair::fromPrivate(a.privateKey).publicKey, a.publicKey);
    }

    void lowOrderPublicKeyRejected() {
        const X25519KeyPair a = X25519KeyPair::generate();
        QVERIFY_EXCEPTION_THROWN(a.sharedSecret(QByteArray(32, '\0')), SecurityError);
    }

    void tamperedStreamingFileFails() {
        QTemporaryDir tmp;
        const QString in = tmp.filePath("p"), enc = tmp.filePath("e"), out = tmp.filePath("o");
        QFile p(in);
        QVERIFY(p.open(QIODevice::WriteOnly));
        p.write(QByteArray(5000, 'a'));
        p.close();
        const QByteArray key = StreamingFileCipher::encryptFile(in, enc);
        QFile e(enc);
        QVERIFY(e.open(QIODevice::ReadWrite));
        QByteArray data = e.readAll();
        data[10] = char(data[10] ^ 1);
        e.seek(0);
        e.write(data);
        e.close();
        QVERIFY_EXCEPTION_THROWN(StreamingFileCipher::decryptFile(enc, out, key), FileCipherError);
        QVERIFY(!QFile::exists(out));
    }
};

QTEST_GUILESS_MAIN(ProtocolVectorsTest)
#include "ProtocolVectorsTest.moc"
