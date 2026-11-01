#pragma once

// Корутины C++20 поверх цикла событий Qt — аналог suspend-функций Kotlin, на
// которых построено ядро Android: сервисы переносятся почти дословно.
//
// - Task<T> — ленивая корутина: стартует, когда её ждут через co_await;
//   исключение внутри пробрасывается ожидающему.
// - spawn(task) — запустить «в фоне» (как scope.launch); исключение — в журнал.
// - co_await delay(ms), co_await awaitReply(reply), co_await runInThread(fn),
//   Deferred<T> — одноразовое значение с ожиданием и таймаутом.
//
// Всё возобновляется в главном потоке (через очередь событий, без
// повторного входа в чужой код), поэтому состояние сервисов не требует
// блокировок. Тяжёлое (шифрование файлов) — runInThread.

#include <QCoreApplication>
#include <QMetaObject>
#include <QNetworkReply>
#include <QPointer>
#include <QThreadPool>
#include <QTimer>

#include <coroutine>
#include <exception>
#include <functional>
#include <memory>
#include <optional>
#include <algorithm>
#include <utility>
#include <vector>

namespace osh {

/// Возобновить корутину следующим проходом цикла событий главного потока.
inline void resumeLater(std::coroutine_handle<> h) {
    QMetaObject::invokeMethod(QCoreApplication::instance(), [h] { h.resume(); }, Qt::QueuedConnection);
}

template <typename T = void>
class Task;

namespace detail {

struct PromiseBase {
    std::coroutine_handle<> continuation;
    std::exception_ptr error;

    std::suspend_always initial_suspend() noexcept { return {}; }

    struct FinalAwaiter {
        bool await_ready() noexcept { return false; }
        template <typename P>
        std::coroutine_handle<> await_suspend(std::coroutine_handle<P> h) noexcept {
            auto c = h.promise().continuation;
            return c ? c : std::noop_coroutine();
        }
        void await_resume() noexcept {}
    };
    FinalAwaiter final_suspend() noexcept { return {}; }
    void unhandled_exception() noexcept { error = std::current_exception(); }
};

template <typename T>
struct Promise : PromiseBase {
    std::optional<T> value;
    Task<T> get_return_object() noexcept;
    template <typename U>
    void return_value(U &&v) {
        value.emplace(std::forward<U>(v));
    }
    T take() {
        if (error) std::rethrow_exception(error);
        return std::move(*value);
    }
};

template <>
struct Promise<void> : PromiseBase {
    Task<void> get_return_object() noexcept;
    void return_void() noexcept {}
    void take() {
        if (error) std::rethrow_exception(error);
    }
};

} // namespace detail

template <typename T>
class [[nodiscard]] Task {
public:
    using promise_type = detail::Promise<T>;
    using Handle = std::coroutine_handle<promise_type>;

    explicit Task(Handle h) noexcept : h_(h) {}
    Task(Task &&o) noexcept : h_(std::exchange(o.h_, {})) {}
    Task &operator=(Task &&o) noexcept {
        if (this != &o) {
            if (h_) h_.destroy();
            h_ = std::exchange(o.h_, {});
        }
        return *this;
    }
    Task(const Task &) = delete;
    ~Task() {
        if (h_) h_.destroy();
    }

    bool await_ready() const noexcept { return false; }
    std::coroutine_handle<> await_suspend(std::coroutine_handle<> awaiting) noexcept {
        h_.promise().continuation = awaiting;
        return h_;
    }
    T await_resume() { return h_.promise().take(); }

private:
    Handle h_;
};

namespace detail {
template <typename T>
Task<T> Promise<T>::get_return_object() noexcept {
    return Task<T>(std::coroutine_handle<Promise<T>>::from_promise(*this));
}
inline Task<void> Promise<void>::get_return_object() noexcept {
    return Task<void>(std::coroutine_handle<Promise<void>>::from_promise(*this));
}

/// Корутина-запускалка для spawn: стартует сразу и сама себя уничтожает.
struct Detached {
    struct promise_type {
        Detached get_return_object() noexcept { return {}; }
        std::suspend_never initial_suspend() noexcept { return {}; }
        std::suspend_never final_suspend() noexcept { return {}; }
        void return_void() noexcept {}
        void unhandled_exception() noexcept {}
    };
};

void logSpawnError(const char *what);
} // namespace detail

/// Запустить задачу «в фоне»; исключение не теряется — уходит в журнал (или [onError]).
inline detail::Detached spawn(Task<void> task, std::function<void(std::exception_ptr)> onError = {}) {
    try {
        co_await task;
    } catch (...) {
        if (onError) {
            onError(std::current_exception());
        } else {
            try {
                throw;
            } catch (const std::exception &e) {
                detail::logSpawnError(e.what());
            } catch (...) {
                detail::logSpawnError("неизвестная ошибка");
            }
        }
    }
}

/// co_await delay(ms) — пауза без блокировки цикла событий.
struct delay {
    int ms;
    bool await_ready() const noexcept { return ms <= 0; }
    void await_suspend(std::coroutine_handle<> h) const { QTimer::singleShot(ms, QCoreApplication::instance(), [h] { h.resume(); }); }
    void await_resume() const noexcept {}
};

/// co_await awaitReply(reply) — дождаться окончания сетевого запроса.
struct awaitReply {
    QNetworkReply *reply;
    bool await_ready() const noexcept { return reply->isFinished(); }
    void await_suspend(std::coroutine_handle<> h) const {
        QObject::connect(reply, &QNetworkReply::finished, QCoreApplication::instance(), [h] { resumeLater(h); }, Qt::SingleShotConnection);
    }
    void await_resume() const noexcept {}
};

/**
 * Одноразовое значение: кто-то ждёт (co_await wait() / waitFor(ms)), кто-то
 * выставляет (resolve / fail). Копии разделяют одно состояние.
 */
template <typename T>
class Deferred {
    struct Waiter {
        std::coroutine_handle<> handle;
        bool timedOut = false;
    };
    struct State {
        std::optional<T> value;
        std::exception_ptr error;
        std::vector<std::shared_ptr<Waiter>> waiters; // ждать могут несколько корутин
    };
    std::shared_ptr<State> s_ = std::make_shared<State>();

public:
    bool isSettled() const { return s_->value.has_value() || s_->error; }

    void resolve(T v) const {
        if (isSettled()) return;
        s_->value.emplace(std::move(v));
        wake();
    }
    void fail(std::exception_ptr e) const {
        if (isSettled()) return;
        s_->error = e;
        wake();
    }

    struct Awaiter {
        std::shared_ptr<State> s;
        int timeoutMs;
        std::shared_ptr<Waiter> w = std::make_shared<Waiter>();
        bool await_ready() const noexcept { return s->value.has_value() || s->error; }
        void await_suspend(std::coroutine_handle<> h) {
            w->handle = h;
            s->waiters.push_back(w);
            if (timeoutMs >= 0) {
                std::weak_ptr<State> weakState = s;
                std::weak_ptr<Waiter> weakWaiter = w;
                QTimer::singleShot(timeoutMs, QCoreApplication::instance(), [weakState, weakWaiter] {
                    auto st = weakState.lock();
                    auto wt = weakWaiter.lock();
                    if (!st || !wt || !wt->handle) return;
                    auto &ws = st->waiters;
                    ws.erase(std::remove(ws.begin(), ws.end(), wt), ws.end());
                    wt->timedOut = true;
                    std::exchange(wt->handle, {}).resume();
                });
            }
        }
        /// nullopt — истёк таймаут.
        std::optional<T> await_resume() const {
            if (w->timedOut) return std::nullopt;
            if (s->error) std::rethrow_exception(s->error);
            return s->value;
        }
    };

    /// Ждать без ограничения времени.
    Awaiter wait() const { return {s_, -1}; }
    /// Ждать не дольше ms; nullopt — не дождались.
    Awaiter waitFor(int ms) const { return {s_, ms}; }

private:
    void wake() const {
        for (auto &w : std::exchange(s_->waiters, {})) {
            if (auto h = std::exchange(w->handle, {})) resumeLater(h);
        }
    }
};

/// co_await runInThread(fn) — выполнить fn в пуле потоков и вернуться в главный поток с результатом.
template <typename F>
auto runInThread(F fn) -> Task<decltype(fn())> {
    using R = decltype(fn());
    struct Awaiter {
        F fn;
        std::optional<std::conditional_t<std::is_void_v<R>, bool, R>> result;
        std::exception_ptr error;
        bool await_ready() const noexcept { return false; }
        void await_suspend(std::coroutine_handle<> h) {
            QThreadPool::globalInstance()->start([this, h] {
                try {
                    if constexpr (std::is_void_v<R>) {
                        fn();
                        result.emplace(true);
                    } else {
                        result.emplace(fn());
                    }
                } catch (...) {
                    error = std::current_exception();
                }
                resumeLater(h);
            });
        }
        R await_resume() {
            if (error) std::rethrow_exception(error);
            if constexpr (!std::is_void_v<R>) return std::move(*result);
        }
    };
    // именованная переменная, не Awaiter{...} прямо в co_await: такой временный объект GCC 11
    // разрушает дважды — захваченные лямбдой строки освобождались раньше времени (порча кучи)
    Awaiter awaiter{std::move(fn), {}, {}};
    if constexpr (std::is_void_v<R>) {
        co_await awaiter;
    } else {
        co_return co_await awaiter;
    }
}

} // namespace osh
