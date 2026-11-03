import Foundation

/// Stores mock runtime channels keyed by member and generic type specialization.
public final class GenericMockRegistry: @unchecked Sendable {
    private struct Key: Hashable {
        let key: String
        let types: [ObjectIdentifier]
    }

    private struct Entry {
        let value: AnyObject
        let type: ObjectIdentifier
        let reset: ([MockScope]) -> Void
        let invocations: () -> [_MocksmithInvocation]
        let unverifiedInvocations: () -> [_MocksmithInvocation]
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    public init() {}

    public func member<Arguments, Ephemeral, Output>(
        key: String,
        types: [Any.Type],
        make: () -> MockMember<Arguments, Ephemeral, Output>
    ) -> MockMember<Arguments, Ephemeral, Output> {
        member(key: key, typeIDs: types.map(ObjectIdentifier.init), make: make)
    }

    public func member<Arguments, Ephemeral, Output>(
        key: String,
        typeIDs: [ObjectIdentifier],
        make: () -> MockMember<Arguments, Ephemeral, Output>
    ) -> MockMember<Arguments, Ephemeral, Output> {
        let lookup = Key(key: key, types: typeIDs)
        let type = ObjectIdentifier(MockMember<Arguments, Ephemeral, Output>.self)
        if let (value, existingType) = lock.withLock({ entries[lookup].map { ($0.value, $0.type) } }) {
            guard existingType == type else {
                preconditionFailure("Generic mock member type changed for \(key)")
            }
            return unsafeDowncast(value, to: MockMember<Arguments, Ephemeral, Output>.self)
        }

        let candidate = make()
        return lock.withLock {
            if let existing = entries[lookup] {
                guard existing.type == type else {
                    preconditionFailure("Generic mock member type changed for \(key)")
                }
                return unsafeDowncast(existing.value, to: MockMember<Arguments, Ephemeral, Output>.self)
            }
            entries[lookup] = Entry(
                value: candidate,
                type: type,
                reset: candidate.reset,
                invocations: { candidate.orderedInvocations },
                unverifiedInvocations: { candidate._mocksmithUnverifiedInvocations }
            )
            return candidate
        }
    }

    public func member<Arguments: ~Copyable, Ephemeral: ~Copyable, Output: ~Copyable>(
        key: String,
        types: [Any.Type],
        make: () -> TransientMockMember<Arguments, Ephemeral, Output>
    ) -> TransientMockMember<Arguments, Ephemeral, Output> {
        member(key: key, typeIDs: types.map(ObjectIdentifier.init), make: make)
    }

    public func member<Arguments: ~Copyable, Ephemeral: ~Copyable, Output: ~Copyable>(
        key: String,
        typeIDs: [ObjectIdentifier],
        make: () -> TransientMockMember<Arguments, Ephemeral, Output>
    ) -> TransientMockMember<Arguments, Ephemeral, Output> {
        let lookup = Key(key: key, types: typeIDs)
        let type = ObjectIdentifier(TransientMockMember<Arguments, Ephemeral, Output>.self)
        if let (value, existingType) = lock.withLock({ entries[lookup].map { ($0.value, $0.type) } }) {
            guard existingType == type else {
                preconditionFailure("Generic mock member type changed for \(key)")
            }
            return unsafeDowncast(value, to: TransientMockMember<Arguments, Ephemeral, Output>.self)
        }

        let candidate = make()
        return lock.withLock {
            if let existing = entries[lookup] {
                guard existing.type == type else {
                    preconditionFailure("Generic mock member type changed for \(key)")
                }
                return unsafeDowncast(existing.value, to: TransientMockMember<Arguments, Ephemeral, Output>.self)
            }
            entries[lookup] = Entry(
                value: candidate,
                type: type,
                reset: candidate.reset,
                invocations: { candidate.orderedInvocations },
                unverifiedInvocations: { candidate._mocksmithUnverifiedInvocations }
            )
            return candidate
        }
    }

    public func reset(_ scopes: [MockScope] = Array(MockScope.all)) {
        let resets = lock.withLock { entries.values.map(\.reset) }
        resets.forEach { $0(scopes) }
    }

    public var orderedInvocations: [_MocksmithInvocation] {
        let snapshots = lock.withLock { entries.values.map(\.invocations) }
        return snapshots.flatMap { $0() }
    }

    public var unverifiedInvocations: [_MocksmithInvocation] {
        let snapshots = lock.withLock { entries.values.map(\.unverifiedInvocations) }
        return snapshots.flatMap { $0() }
    }
}
