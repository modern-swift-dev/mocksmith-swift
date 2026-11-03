import Mocksmith
import Testing

private enum IsolatedOwner {}

private func staticMember() -> MockMember<Void, Void, Int> {
    StaticMockRegistry.shared.member(owner: IsolatedOwner.self, key: "value") { MockMember(name: "value") }
}

@Test func isolatedScopesUseFreshNestedRegistries() async throws {
    let global = StaticMockRegistry.shared

    try await withIsolatedStaticMocks {
        let outer = StaticMockRegistry.shared
        #expect(outer !== global)
        staticMember().addStub(matching: { _ in true }, outcomes: [.returning(1)])

        try await withIsolatedStaticMocks {
            #expect(StaticMockRegistry.shared !== outer)
            #expect(StaticMockRegistry.shared !== global)
            #expect(throws: MockError.self) { try staticMember().invoke(()) }
            staticMember().addStub(matching: { _ in true }, outcomes: [.returning(2)])
            let inner = try staticMember().invoke(())
            #expect(inner == 2)
        }

        #expect(StaticMockRegistry.shared === outer)
        let outerValue = try staticMember().invoke(())
        #expect(outerValue == 1)
    }

    #expect(StaticMockRegistry.shared === global)
    #expect(global.orderedInvocations(owner: IsolatedOwner.self).isEmpty)
}

@Test func isolatedScopeCoversChildAndUnstructuredTasks() async {
    await withIsolatedStaticMocks {
        let isolated = StaticMockRegistry.shared
        async let child = StaticMockRegistry.shared
        let unstructured = await Task { StaticMockRegistry.shared }.value
        #expect(await child === isolated)
        #expect(unstructured === isolated)
    }
}

@Test func detachedTasksFallBackToGlobalRegistry() async {
    let global = StaticMockRegistry.shared

    await withIsolatedStaticMocks {
        let detached = await Task.detached { StaticMockRegistry.shared }.value
        #expect(detached === global)
        #expect(StaticMockRegistry.shared !== global)
    }
}
