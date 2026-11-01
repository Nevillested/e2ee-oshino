#include "service/Infra.h"

#include "net/WebSocketClient.h"

namespace osh {

AckRegistry::AckRegistry(WebSocketClient &ws, QObject *parent) : QObject(parent) {
    connect(&ws, &WebSocketClient::acked, this, [this](const QString &id) {
        if (auto it = waiters_.find(id); it != waiters_.end()) {
            it->resolve(true);
            waiters_.erase(it);
        }
    });
    connect(&ws, &WebSocketClient::rejected, this, [this](const QString &id, const QString &reason) {
        if (auto it = waiters_.find(id); it != waiters_.end()) {
            it->fail(std::make_exception_ptr(DeliveryRejectedError(reason)));
            waiters_.erase(it);
        }
    });
}

Deferred<bool> AckRegistry::waiter(const QString &deliveryId) {
    auto it = waiters_.find(deliveryId);
    if (it == waiters_.end()) it = waiters_.insert(deliveryId, Deferred<bool>());
    return *it;
}

} // namespace osh
