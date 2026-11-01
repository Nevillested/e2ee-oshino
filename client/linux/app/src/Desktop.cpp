#include "Desktop.h"

#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusReply>
#include <QLocalSocket>
#include <QVariantMap>

namespace {
const char *Service = "org.freedesktop.Notifications";
const char *Path = "/org/freedesktop/Notifications";
const char *ServerName = "space.oshino.Oshinobu.instance";
} // namespace

Notifier::Notifier(QObject *parent) : QObject(parent) {
    QDBusConnection::sessionBus().connect(Service, Path, Service, "ActionInvoked", this, SLOT(onActionInvoked(uint, QString)));
}

void Notifier::show(const QString &key, const QString &title, const QString &body) {
    QDBusInterface iface(Service, Path, Service, QDBusConnection::sessionBus());
    if (!iface.isValid()) return;
    const QVariantMap hints{{"desktop-entry", "space.oshino.Oshinobu"}, {"category", "im.received"}};
    const QDBusReply<uint> reply = iface.call("Notify", "Oshinobu", ids_.value(key, 0u), "space.oshino.Oshinobu", title, body,
                                              QStringList{"default", title}, hints, 5000);
    if (reply.isValid()) ids_[key] = reply.value();
}

void Notifier::onActionInvoked(uint id, const QString &action) {
    Q_UNUSED(action)
    for (auto it = ids_.begin(); it != ids_.end(); ++it) {
        if (it.value() == id) {
            Q_EMIT activated(it.key());
            return;
        }
    }
}

SingleInstance::SingleInstance(QObject *parent) : QObject(parent) {
    connect(&server_, &QLocalServer::newConnection, this, [this] {
        while (QLocalSocket *s = server_.nextPendingConnection()) {
            connect(s, &QLocalSocket::readyRead, this, [this, s] {
                const QStringList args = QString::fromUtf8(s->readAll()).split('\n', Qt::SkipEmptyParts);
                Q_EMIT activationRequested(args);
                s->disconnectFromServer();
                s->deleteLater();
            });
        }
    });
}

bool SingleInstance::claim(const QStringList &args) {
    QLocalSocket probe;
    probe.connectToServer(ServerName);
    if (probe.waitForConnected(300)) {
        probe.write(args.join('\n').toUtf8() + "\n");
        probe.waitForBytesWritten(500);
        probe.disconnectFromServer();
        return false;
    }
    // прежний экземпляр упал и оставил сокет — убрать
    QLocalServer::removeServer(ServerName);
    server_.listen(ServerName);
    return true;
}
