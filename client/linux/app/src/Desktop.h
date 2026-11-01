#pragma once

// Интеграция с рабочим столом: уведомления org.freedesktop.Notifications (GNOME,
// KDE — без системного трея) и единственный экземпляр приложения (повторный
// запуск показывает уже открытое окно).

#include <QLocalServer>
#include <QObject>

class Notifier : public QObject {
    Q_OBJECT
public:
    explicit Notifier(QObject *parent = nullptr);
    /// Одно уведомление на чат: новое заменяет прежнее от того же собеседника.
    void show(const QString &key, const QString &title, const QString &body);

Q_SIGNALS:
    /// Нажали на уведомление.
    void activated(const QString &key);

private Q_SLOTS:
    void onActionInvoked(uint id, const QString &action);

private:
    QHash<QString, uint> ids_;
};

class SingleInstance : public QObject {
    Q_OBJECT
public:
    explicit SingleInstance(QObject *parent = nullptr);
    /// false — уже запущен другой экземпляр (ему отправлена просьба показать окно).
    bool claim(const QStringList &args);

Q_SIGNALS:
    void activationRequested(const QStringList &args);

private:
    QLocalServer server_;
};
