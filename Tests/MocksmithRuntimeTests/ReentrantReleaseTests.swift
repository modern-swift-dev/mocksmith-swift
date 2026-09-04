import Foundation
import Mocksmith
import Testing

private final class ReleaseProbe: Sendable {
    private let onRelease: @Sendable () -> Void

    init(checkAccess: @escaping @Sendable () -> Void, released: DispatchSemaphore) {
        onRelease = {
            let accessed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                checkAccess()
                accessed.signal()
            }
            // Bound the check so a regression fails without hanging the suite.
            #expect(accessed.wait(timeout: .now() + 2) == .success)
            released.signal()
        }
    }

    deinit { onRelease() }
}

private func configureRelease(
    _ member: MockMember<ReleaseProbe, Void, Void>,
    scope: MockScope,
    probe: ReleaseProbe
) {
    switch scope {
        case .invocations:
            member.record(probe)
        case .stubs:
            member.addStub(matching: { _ in true }, outcomes: [.answer { _, _ in
                withExtendedLifetime(probe) {}
            }])
        case .actions:
            member.addAction(matching: { _ in true }, action: { _ in
                withExtendedLifetime(probe) {}
            })
    }
}

@Test(arguments: [MockScope.invocations, .stubs, .actions]) private func memberResetReleasesObjectsOutsideLock(scope: MockScope) {
    let member = MockMember<ReleaseProbe, Void, Void>()
    let released = DispatchSemaphore(value: 0)
    configureRelease(member, scope: scope, probe: ReleaseProbe(checkAccess: {
        #expect(member.invocationCount(matching: { _ in true }) == 0)
    }, released: released))

    member.reset([scope])
    #expect(released.wait(timeout: .now() + 2) == .success)
}

private func configureTransientRelease(
    _ member: TransientMockMember<Void, Void, Void>,
    scope: MockScope,
    probe: ReleaseProbe
) {
    if scope == .stubs {
        member.addStub(matching: { _ in true }, outcomes: [.producing {
            withExtendedLifetime(probe) {}
        }])
    } else {
        member.addAction(matching: { _ in true }, action: { _ in
            withExtendedLifetime(probe) {}
        })
    }
}

@Test(arguments: [MockScope.stubs, .actions]) private func transientResetReleasesObjectsOutsideLock(scope: MockScope) {
    let member = TransientMockMember<Void, Void, Void>()
    let released = DispatchSemaphore(value: 0)
    configureTransientRelease(member, scope: scope, probe: ReleaseProbe(checkAccess: {
        #expect(member.invocationCount == 0)
    }, released: released))

    member.reset([scope])
    #expect(released.wait(timeout: .now() + 2) == .success)
}

@Test private func captorResetReleasesObjectsOutsideLock() {
    let captor = ArgumentCaptor<ReleaseProbe>()
    let released = DispatchSemaphore(value: 0)
    _ = Parameter.capturing(captor).matches(ReleaseProbe(checkAccess: {
        #expect(captor.values.isEmpty)
    }, released: released))

    captor.reset()
    #expect(released.wait(timeout: .now() + 2) == .success)
}

private func configureCoupledRelease(
    _ member: MockMember<Void, Void, Void>,
    probe: ReleaseProbe
) {
    member.addAction(matching: { _ in true }, outcomes: [.returning(())], action: { _ in
        withExtendedLifetime(probe) {}
    })
}

@Test private func coupledResetReleasesObjectsOutsideLock() {
    let member = MockMember<Void, Void, Void>()
    let released = DispatchSemaphore(value: 0)
    configureCoupledRelease(member, probe: ReleaseProbe(checkAccess: {
        #expect(member.invocationCount(matching: { _ in true }) == 0)
    }, released: released))

    member.reset()
    #expect(released.wait(timeout: .now() + 2) == .success)
}

private func configureTransientCoupledRelease(
    _ member: TransientMockMember<Void, Void, Void>,
    probe: ReleaseProbe
) {
    member.addAction(matching: { _ in true }, outcomes: [.producing {}], action: { _ in
        withExtendedLifetime(probe) {}
    })
}

@Test private func transientCoupledResetReleasesObjectsOutsideLock() {
    let member = TransientMockMember<Void, Void, Void>()
    let released = DispatchSemaphore(value: 0)
    configureTransientCoupledRelease(member, probe: ReleaseProbe(checkAccess: {
        #expect(member.invocationCount == 0)
    }, released: released))

    member.reset()
    #expect(released.wait(timeout: .now() + 2) == .success)
}

@Test private func propertyReplacementReleasesObjectsOutsideLock() {
    let state = MockPropertyState<ReleaseProbe?, Never>(initial: nil)
    let released = DispatchSemaphore(value: 0)
    state.value = ReleaseProbe(checkAccess: {
        #expect(state.value == nil)
    }, released: released)

    state.value = nil
    #expect(released.wait(timeout: .now() + 2) == .success)
}

private enum RegistryOwner {}

@Test private func registryRemovalReleasesObjectsOutsideLock() {
    let registry = StaticMockRegistry()
    let released = DispatchSemaphore(value: 0)
    registry.member(owner: RegistryOwner.self, key: "release") {
        MockMember<ReleaseProbe, Void, Void>()
    }.record(ReleaseProbe(checkAccess: {
        #expect(registry.orderedInvocations(owner: RegistryOwner.self).isEmpty)
    }, released: released))

    registry.remove(owner: RegistryOwner.self, key: "release")
    #expect(released.wait(timeout: .now() + 2) == .success)
}
