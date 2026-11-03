import Synchronization

/// Thread-safe mutable storage installed as the outcome of a mock property getter.
public final class MockPropertyState<Value, Failure: Error>: Sendable {
    private let storedResult: Mutex<Result<Value, Failure>>

    public init(initial result: Result<Value, Failure>) {
        // Nothing else can reach the new mutex yet; the value is shared across threads by design, as before.
        nonisolated(unsafe) let result = result
        storedResult = Mutex(result)
    }

    /// The outcome returned by the controlled property getter.
    public var result: Result<Value, Failure> {
        get { storedResult.withLock { $0 } }
        set {
            // Only the mutex touches the stored result; the value reaches the reading thread by design, as before.
            nonisolated(unsafe) let newValue = newValue
            let sent: () -> sending Result<Value, Failure> = { newValue }
            let retired = storedResult.withLock { state in
                let retired = state
                state = sent()
                return retired
            }
            withExtendedLifetime(retired) {}
        }
    }

    public func succeed(with value: Value) {
        result = .success(value)
    }

    public func fail(with failure: Failure) {
        result = .failure(failure)
    }

    /// Resolves the current outcome using the property's declared failure type.
    public func get() throws(Failure) -> Value {
        try result.get()
    }
}

public extension MockPropertyState where Failure == Never {
    convenience init(initial value: Value) {
        self.init(initial: .success(value))
    }

    /// The value returned by a controlled nonthrowing property getter.
    var value: Value {
        get { result.get() }
        set { result = .success(newValue) }
    }
}
