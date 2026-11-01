#include "support/Log.h"

#include "support/Task.h"

#include <QDateTime>
#include <QFile>
#include <QMutex>
#include <cstdio>

namespace osh {

namespace {

constexpr qint64 MaxLogBytes = 2 * 1024 * 1024;

QMutex &mutex() {
    static QMutex m;
    return m;
}

QString &path() {
    static QString p;
    return p;
}

void write(const QString &level, const QString &line) {
    const QString text = QDateTime::currentDateTime().toString(Qt::ISODateWithMs) + u' ' + level + line + u'\n';
    const QByteArray bytes = text.toUtf8();
    QMutexLocker lock(&mutex());
    std::fwrite(bytes.constData(), 1, size_t(bytes.size()), stderr);
    if (path().isEmpty()) return;
    QFile f(path());
    // разросся — оставляем вторую половину, чтобы хвост для отчётов не терялся
    if (f.size() > MaxLogBytes && f.open(QIODevice::ReadOnly)) {
        f.seek(f.size() - MaxLogBytes / 2);
        const QByteArray keep = f.readAll();
        f.close();
        if (f.open(QIODevice::WriteOnly | QIODevice::Truncate)) f.write(keep);
        f.close();
    }
    if (f.open(QIODevice::Append)) f.write(bytes);
}

} // namespace

void log(const QString &line) { write(QString(), line); }
void logError(const QString &line) { write(QStringLiteral("ERROR "), line); }

void setLogFile(const QString &p) {
    QMutexLocker lock(&mutex());
    path() = p;
}

QString logFilePath() {
    QMutexLocker lock(&mutex());
    return path();
}

QString logTail(qint64 maxBytes) {
    QMutexLocker lock(&mutex());
    QFile f(path());
    if (path().isEmpty() || !f.open(QIODevice::ReadOnly)) return {};
    if (f.size() > maxBytes) f.seek(f.size() - maxBytes);
    return QString::fromUtf8(f.readAll());
}

namespace detail {
void logSpawnError(const char *what) { logError(QStringLiteral("фоновая задача упала: ") + QString::fromUtf8(what)); }
} // namespace detail

} // namespace osh
