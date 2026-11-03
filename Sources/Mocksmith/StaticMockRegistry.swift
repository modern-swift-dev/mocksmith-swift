import Foundation

/// Stores static mock runtime channels keyed by owner, member, and type specialization.
public final class StaticMockRegistry: @unchecked Sendable {
    private struct Key: Hashable {
        let owner: ObjectIdentifier
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

    /// The registry generated static mocks use: the one ``withIsolatedStaticMocks(isolation:_:)`` installed
    /// for the current task, or else the process-wide default registry.
    public static var shared: StaticMockRegistry {
        isolated ?? global
    }

    @TaskLocal static var isolated: StaticMockRegistry?
    private static let global = StaticMockRegistry()

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    public init() {}

    public func member<Arguments, Ephemeral, Output>(
        owner: Any.Type,
        key: String,
        types: [Any.Type] = [],
        make: () -> MockMember<Arguments, Ephemeral, Output>
    ) -> MockMember<Arguments, Ephemeral, Output> {
        member(owner: owner, key: key, typeIDs: types.map(ObjectIdentifier.init), make: make)
    }

    public func member<Arguments, Ephemeral, Output>(
        owner: Any.Type,
        key: String,
        typeIDs: [ObjectIdentifier],
        make: () -> MockMember<Arguments, Ephemeral, Output>
    ) -> MockMember<Arguments, Ephemeral, Output> {
        let lookup = Key(owner: ObjectIdentifier(owner), key: key, types: typeIDs)
        let type = ObjectIdentifier(MockMember<Arguments, Ephemeral, Output>.self)
        if let (value, existingType) = lock.withLock({ entries[lookup].map { ($0.value, $0.type) } }) {
            guard existingType == type else {
                preconditionFailure("Static mock member type changed for \(key)")
            }
            return unsafeDowncast(value, to: MockMember<Arguments, Ephemeral, Output>.self)
        }

        let candidate = make()
        return lock.withLock {
            if let existing = entries[lookup] {
                guard existing.type == type else {
                    preconditionFailure("Static mock member type changed for \(key)")
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
        owner: Any.Type,
        key: String,
        types: [Any.Type] = [],
        make: () -> TransientMockMember<Arguments, Ephemeral, Output>
    ) -> TransientMockMember<Arguments, Ephemeral, Output> {
        member(owner: owner, key: key, typeIDs: types.map(ObjectIdentifier.init), make: make)
    }

    public func member<Arguments: ~Copyable, Ephemeral: ~Copyable, Output: ~Copyable>(
        owner: Any.Type,
        key: String,
        typeIDs: [ObjectIdentifier],
        make: () -> TransientMockMember<Arguments, Ephemeral, Output>
    ) -> TransientMockMember<Arguments, Ephemeral, Output> {
        let lookup = Key(owner: ObjectIdentifier(owner), key: key, types: typeIDs)
        let type = ObjectIdentifier(TransientMockMember<Arguments, Ephemeral, Output>.self)
        if let (value, existingType) = lock.withLock({ entries[lookup].map { ($0.value, $0.type) } }) {
            guard existingType == type else {
                preconditionFailure("Static mock member type changed for \(key)")
            }
            return unsafeDowncast(value, to: TransientMockMember<Arguments, Ephemeral, Output>.self)
        }

        let candidate = make()
        return lock.withLock {
            if let existing = entries[lookup] {
                guard existing.type == type else {
                    preconditionFailure("Static mock member type changed for \(key)")
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

    public func reset(owner: Any.Type, scopes: [MockScope] = Array(MockScope.all)) {
        let identifier = ObjectIdentifier(owner)
        let resets = lock.withLock {
            entries.compactMap { $0.key.owner == identifier ? $0.value.reset : nil }
        }
        resets.forEach { $0(scopes) }
    }

    public func orderedInvocations(owner: Any.Type) -> [_MocksmithInvocation] {
        let identifier = ObjectIdentifier(owner)
        let snapshots = lock.withLock {
            entries.compactMap { $0.key.owner == identifier ? $0.value.invocations : nil }
        }
        return snapshots.flatMap { $0() }
    }

    public func unverifiedInvocations(owner: Any.Type) -> [_MocksmithInvocation] {
        let identifier = ObjectIdentifier(owner)
        let snapshots = lock.withLock {
            entries.compactMap { $0.key.owner == identifier ? $0.value.unverifiedInvocations : nil }
        }
        return snapshots.flatMap { $0() }
    }

    public func remove(owner: Any.Type, key: String) {
        let identifier = ObjectIdentifier(owner)
        let retired = lock.withLock {
            let keys = entries.keys.filter { $0.owner == identifier && $0.key == key }
            return keys.compactMap { entries.removeValue(forKey: $0) }
        }
        withExtendedLifetime(retired) {}
    }
}
