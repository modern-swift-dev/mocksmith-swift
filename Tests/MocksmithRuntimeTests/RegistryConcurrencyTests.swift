import Dispatch
import Foundation
import Mocksmith
import Testing

/// Collects the identities of members returned from concurrent registry lookups.
private final class Identities: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ObjectIdentifier] = []

    var unique: Set<ObjectIdentifier> {
        lock.withLock { Set(values) }
    }

    var count: Int {
        lock.withLock { values.count }
    }

    func append(_ object: AnyObject) {
        lock.withLock { values.append(ObjectIdentifier(object)) }
    }
}

private enum Owner {}

private let threads = 32

@Test func genericRegistryConcurrentFirstAccessSharesOneMember() {
    let registry = GenericMockRegistry()
    let members = Identities()
    let transients = Identities()
    let types = [ObjectIdentifier(Int.self)]
    DispatchQueue.concurrentPerform(iterations: threads) { _ in
        members.append(registry.member(key: "value", typeIDs: types) { MockMember<Int, Void, Int>(name: "value") })
        transients.append(registry.member(key: "transient", typeIDs: types) { TransientMockMember<Int, Void, Int>(name: "transient") })
    }

    #expect(members.count == threads && members.unique.count == 1)
    #expect(transients.count == threads && transients.unique.count == 1)
}

@Test func staticRegistryConcurrentFirstAccessSharesOneMember() {
    let registry = StaticMockRegistry()
    let members = Identities()
    let transients = Identities()
    DispatchQueue.concurrentPerform(iterations: threads) { _ in
        members.append(registry.member(owner: Owner.self, key: "value") { MockMember<Int, Void, Int>(name: "value") })
        transients.append(registry.member(owner: Owner.self, key: "transient") { TransientMockMember<Int, Void, Int>(name: "transient") })
    }

    #expect(members.count == threads && members.unique.count == 1)
    #expect(transients.count == threads && transients.unique.count == 1)
}

@Test func registriesKeepConcurrentSpecializationsSeparate() {
    let generic = GenericMockRegistry()
    let staticRegistry = StaticMockRegistry()
    let strings = Identities()
    let integers = Identities()
    DispatchQueue.concurrentPerform(iterations: threads) { index in
        if index.isMultiple(of: 2) {
            strings.append(generic.member(key: "echo", typeIDs: [ObjectIdentifier(String.self)]) { MockMember<String, Void, String>(name: "echo") })
            strings.append(staticRegistry.member(owner: Owner.self, key: "echo", typeIDs: [ObjectIdentifier(String.self)]) {
                MockMember<String, Void, String>(name: "echo")
            })
        } else {
            integers.append(generic.member(key: "echo", typeIDs: [ObjectIdentifier(Int.self)]) { MockMember<Int, Void, Int>(name: "echo") })
            integers.append(staticRegistry.member(owner: Owner.self, key: "echo", typeIDs: [ObjectIdentifier(Int.self)]) {
                MockMember<Int, Void, Int>(name: "echo")
            })
        }
    }

    // One member per registry and specialization.
    #expect(strings.unique.count == 2)
    #expect(integers.unique.count == 2)
    #expect(strings.unique.isDisjoint(with: integers.unique))
}
