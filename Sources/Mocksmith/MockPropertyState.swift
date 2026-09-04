import Foundation

/// Thread-safe mutable storage installed as the outcome of a mock property getter.
public final class MockPropertyState<Value, Failure: Error>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<Value, Failure>

    public init(initial result: Result<Value, Failure>) {
        storedResult = result
    }

    /// The outcome returned by the controlled property getter.
    public var result: Result<Value, Failure> {
        get { lock.withLock { storedResult } }
        set {
            let retired = lock.withLock {
                let retired = storedResult
                storedResult = newValue
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
