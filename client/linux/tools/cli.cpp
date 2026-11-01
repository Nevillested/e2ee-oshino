// Консольный клиент для проверки ядра на живом сервере (без интерфейса):
//   oshinobu-cli <data-dir> register <login> <password> <invite>   → секрет TOTP
//   oshinobu-cli <data-dir> login <login> <password> <totp-secret>
//   oshinobu-cli <data-dir> send <peer-login> <text>
//   oshinobu-cli <data-dir> listen <seconds>
// Код TOTP утилита считает сама (RFC 6238) — для тестового аккаунта.

#include "Core.h"
#include "support/Log.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QSettings>
#include <QUrlQuery>
#include <QtEndian>

#include <openssl/hmac.h>

#include <cstdio>

using namespace osh;

namespace {

QByteArray base32Decode(const QString &s) {
    const QString alphabet = QStringLiteral("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567");
    QByteArray out;
    quint32 buffer = 0;
    int bits = 0;
    for (QChar c : s.toUpper()) {
        const int v = alphabet.indexOf(c);
        if (v < 0) continue;
        buffer = (buffer << 5) | quint32(v);
        bits += 5;
        if (bits >= 8) {
            out.append(char((buffer >> (bits - 8)) & 0xFF));
            bits -= 8;
        }
    }
    return out;
}

/// RFC 6238: SHA-1, 6 цифр, шаг 30 с (как pquerna/otp на сервере).
QString totp(const QString &secretB32) {
    const QByteArray key = base32Decode(secretB32);
    QByteArray counter(8, '\0');
    qToBigEndian<quint64>(quint64(QDateTime::currentSecsSinceEpoch() / 30), counter.data());
    unsigned char mac[20];
    unsigned int len = 20;
    HMAC(EVP_sha1(), key.constData(), key.size(), reinterpret_cast<const unsigned char *>(counter.constData()), 8, mac, &len);
    const int offset = mac[19] & 0x0F;
    const quint32 code = (quint32(mac[offset] & 0x7F) << 24 | quint32(mac[offset + 1]) << 16 | quint32(mac[offset + 2]) << 8 | mac[offset + 3]) % 1000000;
    return QStringLiteral("%1").arg(code, 6, 10, QLatin1Char('0'));
}

class CliHost : public RouterHost {
public:
    QString openChatPeerLogin() const override { return {}; }
    bool isAppInForeground() const override { return true; }
    void playMessageSound() override {}
    void showMessageNotification(const QString &, const QString &) override {}
};

void out(const QString &s) {
    std::fputs((s + "\n").toUtf8().constData(), stdout);
    std::fflush(stdout);
}

Task<void> run(Core &core, QStringList args) {
    const QString cmd = args.value(0);
    if (cmd == "register") {
        const QString login = args.value(1), password = args.value(2), invite = args.value(3);
        const QString url = co_await core.registerAccount(login, password, invite);
        const QString secret = QUrlQuery(QUrl(url).query()).queryItemValue("secret");
        out("TOTP_SECRET " + secret);
        co_await core.api.verifyTotp(login, totp(secret));
        out("verified");
        co_await core.login(login, password, totp(secret));
        out("logged in, device " + core.keys.deviceId().value_or("?"));
    } else if (cmd == "login") {
        co_await core.login(args.value(1), args.value(2), totp(args.value(3)));
        out("logged in, device " + core.keys.deviceId().value_or("?"));
    } else if (cmd == "send") {
        if (!(co_await core.resumeSession())) throw std::runtime_error("нет входа");
        const ChatSummary chat = co_await core.openChat(args.value(1));
        Deferred<bool> connected;
        QObject::connect(&core.ws, &WebSocketClient::statusChanged, &core, [connected](ConnectionStatus s) {
            if (s == ConnectionStatus::Connected) connected.resolve(true);
        });
        std::optional<bool> up;
        if (!core.ws.isConnected()) up = co_await connected.waitFor(15000); // не внутри && (GCC 11)
        if (!core.ws.isConnected() && !up) throw std::runtime_error("нет соединения WebSocket");
        co_await core.sendText(core.peerOf(chat), args.mid(2).join(' '));
        // ждём ack сервера
        for (int i = 0; i < 40; ++i) {
            const auto msgs = core.chats.messages(chat.peerLogin);
            if (!msgs.isEmpty() && msgs.last().status != MessageStatus::Sending) {
                out("status " + msgs.last().status);
                break;
            }
            co_await delay{250};
        }
    } else if (cmd == "listen") {
        if (!(co_await core.resumeSession())) throw std::runtime_error("нет входа");
        QObject::connect(&core.chats, &ChatStore::changed, &core, [&core](const QString &peer) {
            if (peer.isEmpty()) return;
            const auto msgs = core.chats.messages(peer);
            if (!msgs.isEmpty() && !msgs.last().isMine) out("<" + peer + "> " + msgs.last().text);
        });
        co_await delay{args.value(1).toInt() * 1000};
    } else {
        out("команды: register | login | send | listen");
    }
}

} // namespace

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    QStringList args = app.arguments().mid(1);
    if (args.size() < 2) {
        out("oshinobu-cli <data-dir> <command> ...");
        return 2;
    }
    const AppDirs dirs = AppDirs::under(args.takeFirst());
    CliHost host;
    auto prefs = std::make_unique<Prefs>(std::make_unique<QSettings>(dirs.data + "/prefs.ini", QSettings::IniFormat));
    Core core(dirs, std::make_unique<EncryptedFileSecureStore>(dirs.data), std::move(prefs), host);
    spawn([](Core &c, QStringList a) -> Task<void> {
        int code = 0;
        try {
            co_await run(c, a);
        } catch (const ApiError &err) {
            out("ОШИБКА " + err.key + (err.status ? QStringLiteral(" (%1)").arg(*err.status) : QString()));
            code = 1;
        } catch (const std::exception &err) {
            out(QStringLiteral("ОШИБКА ") + QString::fromUtf8(err.what()));
            code = 1;
        }
        QCoreApplication::exit(code);
    }(core, args));
    return app.exec();
}
