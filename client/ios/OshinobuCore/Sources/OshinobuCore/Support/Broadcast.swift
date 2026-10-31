import Foundation

/// Рассылка событий нескольким подписчикам (аналог SharedFlow в Kotlin):
/// каждый `stream()` — свой AsyncStream, отписка — когда перебор закончился.
public final class Broadcast<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private let bufferLimit: Int

    public init(bufferLimit: Int = 1024) { self.bufferLimit = bufferLimit }

    public func stream() -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: .bufferingNewest(bufferLimit)) { continuation in
            let id = UUID()
            lock.sync { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.sync { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    public func emit(_ value: Element) {
        let targets = lock.sync { Array(continuations.values) }
        for c in targets { c.yield(value) }
    }
}

/// Текущее значение + рассылка изменений (аналог StateFlow).
public final class StateValue<Value: Sendable & Equatable>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Value
    private let changes = Broadcast<Value>(bufferLimit: 1)

    public init(_ initial: Value) { current = initial }

    public var value: Value {
        get { lock.sync { current } }
        set {
            let changed: Bool = lock.sync {
                guard current != newValue else { return false }
                current = newValue
                return true
            }
            if changed { changes.emit(newValue) }
        }
    }

    /// Сначала текущее значение, потом каждое изменение.
    public func stream() -> AsyncStream<Value> {
        let upstream = changes.stream()
        let first = value
        return AsyncStream { continuation in
            continuation.yield(first)
            let task = Task {
                for await v in upstream { continuation.yield(v) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Дождаться значения, удовлетворяющего условию; nil — не дождались за [timeout].
    public func first(where predicate: @escaping @Sendable (Value) -> Bool, timeout: Duration) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { [self] in
                for await v in stream() where predicate(v) { return v }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

extension NSLock {
    /// Выполнить под блокировкой (свой вариант — `withLock` из Foundation есть не на всех iOS).
    @inline(__always)
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
