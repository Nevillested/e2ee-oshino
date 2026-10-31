import Foundation

/// Диагностический журнал: [log] — хлебная крошка, [error] — настоящая ошибка
/// (будит отправку отчёта). НИКОГДА не писать сюда текст переписки и ключи.
public protocol Logger: Sendable {
    func log(_ message: String)
    func error(_ message: String)
}

public struct NoopLogger: Logger {
    public init() {}
    public func log(_ message: String) {}
    public func error(_ message: String) {}
}

/**
 * Последовательное выполнение по ключу. Ключ — device_id собеседника: входящая
 * расшифровка и исходящая отправка для ОДНОГО устройства не должны пересекаться —
 * у них общее состояние ratchet. Нереентерабельно, как и на Android.
 */
public actor KeyedMutex {
    private var busy: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    private func acquire(_ key: String) async {
        if busy.insert(key).inserted { return }
        await withCheckedContinuation { waiters[key, default: []].append($0) }
    }

    private func release(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue.isEmpty ? nil : queue
            next.resume() // ключ остаётся занятым — передаём следующему
        } else {
            busy.remove(key)
        }
    }

    public func run<T: Sendable>(_ key: String, _ action: @Sendable () async throws -> T) async rethrows -> T {
        await acquire(key)
        defer { release(key) }
        return try await action()
    }
}

/// Сервер отказался принять конверт насовсем ([reason] — unknown_device, blocked).
public struct DeliveryRejectedError: Error { public let reason: String }

/// Ожидание ack сервера по deliveryId.
public final class AckRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var early: [String: Result<Void, Error>] = [:]
    private var tasks: [Task<Void, Never>] = []

    public init(transport: Transport) {
        tasks.append(Task { [weak self] in for await id in transport.acks.stream() { self?.complete(id, .success(())) } })
        tasks.append(Task { [weak self] in
            for await r in transport.rejections.stream() { self?.complete(r.deliveryId, .failure(DeliveryRejectedError(reason: r.reason))) }
        })
    }

    deinit { tasks.forEach { $0.cancel() } }

    private func complete(_ id: String, _ result: Result<Void, Error>) {
        let waiter: CheckedContinuation<Void, Error>? = lock.sync {
            if let w = waiters.removeValue(forKey: id) { return w }
            early[id] = result // ack обогнал ожидание
            return nil
        }
        waiter?.resume(with: result)
    }

    /// Дождаться ack; бросает [DeliveryRejectedError] на отказ и CancellationError на отмену.
    public func wait(_ id: String) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let ready: Result<Void, Error>? = lock.sync {
                    if let r = early.removeValue(forKey: id) { return r }
                    waiters[id] = c
                    return nil
                }
                if let ready { c.resume(with: ready) }
            }
        } onCancel: {
            cancel(id)
        }
    }

    public func cancel(_ id: String) {
        let w = lock.sync { waiters.removeValue(forKey: id) }
        w?.resume(throwing: CancellationError())
    }
}

/// Повтор до успеха с нарастающей паузой 1 → 30 с.
public func retryWithBackoff<T>(maxAttempts: Int = .max, _ block: () async throws -> T) async throws -> T {
    var delay: UInt64 = 1
    var attempt = 0
    while true {
        attempt += 1
        do { return try await block() }
        catch is CancellationError { throw CancellationError() }
        catch {
            if attempt >= maxAttempts { throw error }
            try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay = min(delay * 2, 30)
        }
    }
}
