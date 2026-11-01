#pragma once

// Инфраструктура сервисов (как Infra.kt): асинхронный мьютекс по ключу (между
// точками co_await корутины чередуются — без него две отправки одному
// собеседнику продвинули бы ratchet вперемешку), реестр ack/rejected и повтор
// с нарастающей паузой.

#include "support/Task.h"

#include <QHash>
#include <QObject>
#include <deque>
#include <memory>

namespace osh {

class WebSocketClient;

/// Мьютекс для корутин: co_await m.lock() — и до конца области видимости.
class AsyncMutex {
public:
    class Guard {
    public:
        explicit Guard(AsyncMutex *m) : m_(m) {}
        Guard(Guard &&o) noexcept : m_(std::exchange(o.m_, nullptr)) {}
        Guard(const Guard &) = delete;
        ~Guard() {
            if (m_) m_->unlock();
        }

    private:
        AsyncMutex *m_;
    };

    struct LockAwaiter {
        AsyncMutex *m;
        bool await_ready() {
            if (m->locked_) return false;
            m->locked_ = true;
            return true;
        }
        void await_suspend(std::coroutine_handle<> h) { m->waiters_.push_back(h); }
        Guard await_resume() { return Guard(m); }
    };

    LockAwaiter lock() { return LockAwaiter{this}; }

private:
    void unlock() {
        if (waiters_.empty()) {
            locked_ = false;
            return;
        }
        // замок переходит следующему ожидающему, не освобождаясь
        resumeLater(waiters_.front());
        waiters_.pop_front();
    }

    bool locked_ = false;
    std::deque<std::coroutine_handle<>> waiters_;
};

class KeyedMutex {
public:
    AsyncMutex &operator[](const QString &key) {
        auto &m = locks_[key];
        if (!m) m = std::make_shared<AsyncMutex>();
        return *m;
    }

private:
    QHash<QString, std::shared_ptr<AsyncMutex>> locks_;
};

struct DeliveryRejectedError : std::runtime_error {
    QString reason;
    explicit DeliveryRejectedError(QString r) : std::runtime_error("доставка отклонена сервером: " + r.toStdString()), reason(std::move(r)) {}
};

/// Ожидание ack на конверт: waiter(id) → resolve по ack, fail(DeliveryRejectedError) по rejected.
class AckRegistry : public QObject {
    Q_OBJECT
public:
    explicit AckRegistry(WebSocketClient &ws, QObject *parent = nullptr);
    Deferred<bool> waiter(const QString &deliveryId);
    void cancel(const QString &deliveryId) { waiters_.remove(deliveryId); }

private:
    QHash<QString, Deferred<bool>> waiters_;
};

/// Повторять, пока не получится: 1 с → 30 с.
template <typename F>
Task<void> retryUntilSuccess(F action) {
    int delayMs = 1000;
    while (true) {
        bool ok = false;
        try {
            co_await action();
            ok = true;
        } catch (const std::exception &) {
        }
        if (ok) co_return;
        co_await delay{delayMs};
        delayMs = std::min(delayMs * 2, 30000);
    }
}

} // namespace osh
