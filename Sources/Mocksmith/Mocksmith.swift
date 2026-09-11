import Foundation

/// Selects how a protocol's mock is generated.
public enum MockGeneration {
    /// Uses compiler macro expansion for direct protocols.
    /// Protocols with custom inheritance still require the build plugin.
    case macro

    /// Generates Swift source with `MocksmithBuildPlugin` before compilation.
    /// Attach the plugin to the target that declares the protocol. The protocol
    /// must be unconditional, top-level, and internal, package, or public, with
    /// requirement types accessible from the generated source file.
    case buildPlugin
}

/// Generates a strict mock for a protocol.
/// The default requires `MocksmithBuildPlugin` on the declaring target.
/// Use `.macro` for private, fileprivate, nested, or conditional direct protocols.
@attached(peer, names: suffixed(Mock))
public macro Mockable(_ generation: MockGeneration = .buildPlugin) = #externalMacro(module: "MocksmithMacros", type: "MockableMacro")

/// Implementation detail used by `MocksmithBuildPlugin`.
public enum _MocksmithAccess {
    case `internal`
    case package
    case `public`
}

/// Marks a requirement whose named argument or result types are noncopyable.
/// Generated mocks use a transient, count-only channel for the requirement.
@attached(peer, names: arbitrary)
public macro MockNoncopyable() = #externalMacro(module: "MocksmithMacros", type: "MockNoncopyableMacro")

public func Given<M: Mock>(_ mock: M) -> M.Given {
    mock.given()
}

public func Given<M: StaticMock>(_ type: M.Type) -> M.StaticGiven {
    type.given()
}

public func Calls<M: _MocksmithCallInspectable>(_ mock: M) -> M.Calls {
    mock._mocksmithCalls()
}

public func Calls<M: _MocksmithStaticCallInspectable>(_ type: M.Type) -> M.StaticCalls {
    type._mocksmithStaticCalls()
}

public func MockState<M: _MocksmithStateControllable>(_ mock: M) -> M.MockState {
    mock._mocksmithState()
}

public func MockState<M: _MocksmithStaticStateControllable>(_ type: M.Type) -> M.StaticMockState {
    type._mocksmithStaticState()
}

public func Perform<M: Mock>(_ mock: M) -> M.Perform {
    mock.perform()
}

public func Perform<M: StaticMock>(_ type: M.Type) -> M.StaticPerform {
    type.perform()
}

public func resetMock(_ mock: some Mock, scopes: [MockScope] = Array(MockScope.all)) {
    for scope in scopes {
        mock.resetMock(scope)
    }
}

public func resetMock(_ type: (some StaticMock).Type, scopes: [MockScope] = Array(MockScope.all)) {
    for scope in scopes {
        type.resetMock(scope)
    }
}
