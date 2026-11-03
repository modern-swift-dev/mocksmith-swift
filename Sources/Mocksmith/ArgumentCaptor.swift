import Synchronization

/// Thread-safe collector for argument values matched by a capturing parameter.
public final class ArgumentCaptor<Value>: Sendable {
    private let storage = Mutex<[Value]>([])

    public init() {}
    public var values: [Value] {
        storage.withLock { $0 }
    }

    public var lastValue: Value? {
        storage.withLock { $0.last }
    }

    public func reset() {
        let retired = storage.withLock { state in
            let retired = state
            state.removeAll()
            return retired
        }
        withExtendedLifetime(retired) {}
    }

    func append(_ value: Value) {
        // Only the mutex touches the array; the argument itself reaches the test thread by design, as before.
        nonisolated(unsafe) let value = value
        let sent: () -> sending Value = { value }
        storage.withLock { $0.append(sent()) }
    }
}
