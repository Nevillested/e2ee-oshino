// Хранилища: правила ChatStore (дубли, надгробия, превью, порядок чатов), архив
// сессий, очередь отправки, зашифрованный файл секретов.

#include "crypto/RatchetState.h"
#include "storage/ChatStore.h"
#include "storage/Stores.h"

#include <QTemporaryDir>
#include <QtTest>

using namespace osh;

namespace {
StoredMessage msg(const QString &id, qint64 ts, const QString &text = "x", bool mine = false) {
    StoredMessage m;
    m.messageId = id;
    m.timestamp = ts;
    m.text = text;
    m.isMine = mine;
    return m;
}
} // namespace

class StorageTest : public QObject {
    Q_OBJECT

private Q_SLOTS:
    void duplicatesIgnoredAndOrderedByTime() {
        ChatStore chats({}, randomBytes(32));
        chats.addMessage("bob", msg("b", 2000));
        chats.addMessage("bob", msg("a", 1000));
        chats.addMessage("bob", msg("a", 1000, "дубль"));
        const auto list = chats.messages("bob");
        QCOMPARE(list.size(), 2);
        QCOMPARE(list[0].messageId, QString("a"));
        QCOMPARE(list[0].text, QString("x"));
    }

    void deletedMessageDoesNotResurrect() {
        ChatStore chats({}, randomBytes(32));
        chats.addMessage("bob", msg("a", 1000));
        chats.deleteMessages("bob", {"a"});
        chats.addMessage("bob", msg("a", 1000));
        QVERIFY(chats.messages("bob").isEmpty());
        // надгробие израсходовано — следующее сообщение с этим id уже добавится
        chats.addMessage("bob", msg("a", 1000));
        QCOMPARE(chats.messages("bob").size(), 1);
    }

    void persistsEncryptedAcrossReopen() {
        QTemporaryDir dir;
        const QByteArray key = randomBytes(32);
        {
            ChatStore chats(dir.filePath("c.db"), key);
            chats.addMessage("bob", msg("a", 1000, "секрет"), QString("acc-1"), true);
        }
        ChatStore again(dir.filePath("c.db"), key);
        QCOMPARE(again.messages("bob").first().text, QString("секрет"));
        QCOMPARE(again.peer("bob")->unreadCount, 1);
        QCOMPARE(again.peer("bob")->lastKnownAccountId, std::optional<QString>("acc-1"));
        // на диске текста нет — записи зашифрованы
        QFile f(dir.filePath("c.db"));
        QVERIFY(f.open(QIODevice::ReadOnly));
        QVERIFY(!f.readAll().contains(QString("секрет").toUtf8()));
    }

    void previewMarkerAndDecode() {
        StoredMessage photo = msg("p", 1, "");
        photo.isMedia = true;
        QCOMPARE(ChatStore::previewMarker(photo), ChatStore::PreviewMark + "photo");
        const QString text = ChatStore::decodePreview(ChatStore::previewMarker(photo), [](const QString &k) { return "[" + k + "]"; });
        QCOMPARE(text, QString("📷 [media.photo]"));
        QCOMPARE(ChatStore::decodePreview("привет", [](const QString &k) { return k; }), QString("привет"));
    }

    void pinnedChatsFirstThenRecent() {
        ChatStore chats({}, randomBytes(32));
        chats.addMessage("old", msg("1", 1000));
        chats.addMessage("new", msg("2", 3000));
        chats.addMessage("pinned", msg("3", 500));
        chats.setChatPinned("pinned", true);
        const auto peers = chats.knownPeers();
        QCOMPARE(peers[0].peerLogin, QString("pinned"));
        QCOMPARE(peers[1].peerLogin, QString("new"));
        QCOMPARE(peers[2].peerLogin, QString("old"));
    }

    void sessionArchiveRetireAndPromote() {
        InMemorySecureStore secure;
        SessionStore sessions(secure);
        const auto a = RatchetState::initAsSender(randomBytes(32), X25519KeyPair::generate());
        const auto b = RatchetState::initAsSender(randomBytes(32), X25519KeyPair::generate());
        sessions.save("dev", a);
        sessions.replace("dev", b);
        QCOMPARE(sessions.archived("dev").size(), 1);
        QCOMPARE(sessions.get("dev")->rootKey, b.rootKey);
        sessions.promote("dev", 0, sessions.archived("dev").first());
        QCOMPARE(sessions.get("dev")->rootKey, a.rootKey);
        QCOMPARE(sessions.archived("dev").first().rootKey, b.rootKey);
    }

    void sendQueuePutAndRemove() {
        InMemorySecureStore secure;
        SendQueueStore queue(secure);
        queue.add("d1", "dev", QJsonObject{{"x", 1}}, false, QString("m1"), QString("bob"));
        queue.add("d2", "dev", QJsonObject{{"x", 2}});
        queue.remove("d1");
        const auto all = queue.getAll();
        QCOMPARE(all.size(), 1);
        QCOMPARE(all.first().value("id").toString(), QString("d2"));
    }

    void encryptedSecureStoreRoundTrip() {
        QTemporaryDir dir;
        {
            EncryptedFileSecureStore s(dir.path());
            s.write("k", "значение");
        }
        EncryptedFileSecureStore again(dir.path());
        QCOMPARE(again.read("k"), std::optional<QString>("значение"));
        QFile f(dir.filePath("secure.bin"));
        QVERIFY(f.open(QIODevice::ReadOnly));
        QVERIFY(!f.readAll().contains(QString("значение").toUtf8()));
    }
};

QTEST_GUILESS_MAIN(StorageTest)
#include "StorageTest.moc"
