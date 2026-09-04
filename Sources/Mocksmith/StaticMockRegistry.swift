import Foundation

/// Stores static mock runtime channels keyed by owner, member, and type specialization.
public final class StaticMockRegistry: @unchecked Sendable {
    private struct Key: Hashable {
        let owner: ObjectIdentifier
        let key: String
        let types: [ObjectIdentifier]
    }

    private struct Entry {
        let value: Any
        let reset: ([MockScope]) -> Void
        let invocations: () -> [_MocksmithInvocation]
        let unverifiedInvocations: () -> [_MocksmithInvocation]
    }

    private struct TransientEntry {
        // `Any`/`AnyObject` erasure of a class specialized with noncopyable
        // arguments requires a newer runtime than the package's iOS 17 floor.
        let pointer: UnsafeMutableRawPointer
        let type: ObjectIdentifier
        let reset: ([MockScope]) -> Void
        let invocations: () -> [_MocksmithInvocation]
        let unverifiedInvocations: () -> [_MocksmithInvocation]
        let release: () -> Void
    }

    public static let shared = StaticMockRegistry()

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var transientEntries: [Key: TransientEntry] = [:]

    public init() {}

    deinit {
        let releases = lock.withLock { Array(transientEntries.values.map(\.release)) }
        releases.forEach { $0() }
    }

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
        precondition(lock.withLock { transientEntries[lookup] == nil }, "Static mock member type changed for \(key)")
        if let existing = lock.withLock({ entries[lookup] }) {
            guard let member = existing.value as? MockMember<Arguments, Ephemeral, Output> else {
                preconditionFailure("Static mock member type changed for \(key)")
            }
            return member
        }

        let candidate = make()
        return lock.withLock {
            precondition(transientEntries[lookup] == nil, "Static mock member type changed for \(key)")
            if let existing = entries[lookup] {
                guard let member = existing.value as? MockMember<Arguments, Ephemeral, Output> else {
                    preconditionFailure("Static mock member type changed for \(key)")
                }
                return member
            }
            entries[lookup] = Entry(
                value: candidate,
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
        precondition(lock.withLock { entries[lookup] == nil }, "Static mock member type changed for \(key)")
        if let existing = lock.withLock({ transientEntries[lookup] }) {
            guard existing.type == type else {
                preconditionFailure("Static mock member type changed for \(key)")
            }
            return Unmanaged<TransientMockMember<Arguments, Ephemeral, Output>>.fromOpaque(existing.pointer).takeUnretainedValue()
        }

        let candidate = make()
        return lock.withLock {
            precondition(entries[lookup] == nil, "Static mock member type changed for \(key)")
            if let existing = transientEntries[lookup] {
                guard existing.type == type else {
                    preconditionFailure("Static mock member type changed for \(key)")
                }
                return Unmanaged<TransientMockMember<Arguments, Ephemeral, Output>>.fromOpaque(existing.pointer).takeUnretainedValue()
            }
            let retained = Unmanaged.passRetained(candidate)
            transientEntries[lookup] = TransientEntry(
                pointer: retained.toOpaque(),
                type: type,
                reset: candidate.reset,
                invocations: { candidate.orderedInvocations },
                unverifiedInvocations: { candidate._mocksmithUnverifiedInvocations },
                release: retained.release
            )
            return candidate
        }
    }

    public func reset(owner: Any.Type, scopes: [MockScope] = Array(MockScope.all)) {
        let identifier = ObjectIdentifier(owner)
        let resets = lock.withLock {
            entries.compactMap { $0.key.owner == identifier ? $0.value.reset : nil }
                + transientEntries.compactMap { $0.key.owner == identifier ? $0.value.reset : nil }
        }
        resets.forEach { $0(scopes) }
    }

    public func orderedInvocations(owner: Any.Type) -> [_MocksmithInvocation] {
        let identifier = ObjectIdentifier(owner)
        let snapshots = lock.withLock {
            entries.compactMap { $0.key.owner == identifier ? $0.value.invocations : nil }
                + transientEntries.compactMap { $0.key.owner == identifier ? $0.value.invocations : nil }
        }
        return snapshots.flatMap { $0() }
    }

    public func unverifiedInvocations(owner: Any.Type) -> [_MocksmithInvocation] {
        let identifier = ObjectIdentifier(owner)
        let snapshots = lock.withLock {
            entries.compactMap { $0.key.owner == identifier ? $0.value.unverifiedInvocations : nil }
                + transientEntries.compactMap { $0.key.owner == identifier ? $0.value.unverifiedInvocations : nil }
        }
        return snapshots.flatMap { $0() }
    }

    public func remove(owner: Any.Type, key: String) {
        let identifier = ObjectIdentifier(owner)
        let retired = lock.withLock {
            let keys = entries.keys.filter { $0.owner == identifier && $0.key == key }
            let removed = keys.compactMap { entries.removeValue(forKey: $0) }
            let transientKeys = transientEntries.keys.filter { $0.owner == identifier && $0.key == key }
            return (removed, transientKeys.compactMap { transientEntries.removeValue(forKey: $0) })
        }
        retired.1.forEach { $0.release() }
        withExtendedLifetime(retired) {}
    }
}
