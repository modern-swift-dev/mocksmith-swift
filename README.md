# Mocksmith

`Mocksmith` creates strict protocol mocks at compile time with Swift 6.3. Annotate protocols with `@Mockable`; the build plugin generates their implementations before compilation. It takes inspiration from [SwiftyMocky](https://github.com/MakeAWishFoundation/SwiftyMocky), without Sourcery or checked-in generated source files.

Source code, issues, and releases live in the canonical [modern-swift-dev/mocksmith-swift repository](https://github.com/modern-swift-dev/mocksmith-swift).

## Installation

Add the latest stable release of the package to a Swift 6.3 project:

```swift
dependencies: [
    .package(
        url: "https://github.com/modern-swift-dev/mocksmith-swift.git",
        from: "1.0.0"
    )
]
```

Then add `Mocksmith`, exactly one runner adapter, and the build plugin. Attach the plugin to every target that uses the default `@Mockable`:

```swift
.testTarget(
    name: "AppTests",
    dependencies: [
        .product(name: "Mocksmith", package: "mocksmith-swift"),
        .product(name: "MocksmithTesting", package: "mocksmith-swift"),
        // or: .product(name: "MocksmithXCTest", package: "mocksmith-swift")
    ],
    plugins: [
        .plugin(name: "MocksmithBuildPlugin", package: "mocksmith-swift"),
    ]
)
```

`@Mockable` defaults to `.buildPlugin`. The plugin generates complete mocks as Swift source before compilation, avoiding repeated compiler macro expansion of their implementations. It also resolves inherited protocols and composition aliases from the target and its reachable SwiftPM source dependencies.

The plugin must be attached to the target that declares each protocol, including SwiftPM dependency targets built from an Xcode app. The default requires unconditional, top-level `internal`, `package`, or `public` protocols whose requirement types are accessible from the generated source file.

When migrating existing direct mocks, add the plugin to their declaring targets. For `private`, `fileprivate`, nested, or conditional direct protocols, explicitly opt into compiler macro expansion with `@Mockable(.macro)`:

```swift
@Mockable(.macro)
private protocol WeatherService {
    func temperature(for city: String) async throws -> Double
}
```

Direct protocols using `.macro` do not require the plugin. Protocols with custom inheritance still require it.

Incremental builds cache import discovery during plugin setup and compare declaration source snapshots before invoking the Swift parser. Both caches check source contents, including additions and removals, and invalidate when the build tool changes. Unchanged mocks retain their output timestamp. The caches live in the plugin work directory; removing build artifacts triggers a fresh scan. Implementation edits in files that also contain declarations may still require parsing, even when the generated mocks stay the same.

The package supports Swift 6.3 on Linux and iOS 17, macOS 13, tvOS 17, and watchOS 10 or newer.

## Documentation

Guides and examples live in [Documentation/Site](Documentation/Site). The [central documentation repository](https://github.com/modern-swift-dev/docs) owns the shared Astro theme, builds the guides and DocC API reference, and publishes them daily. For local builds and previews, follow the [docs README](https://github.com/modern-swift-dev/docs/blob/main/README.md).

The [Mocksmith documentation site](https://modern-swift-dev.github.io/docs/mocksmith-swift/) has the
[documentation hub](https://modern-swift-dev.github.io/docs/mocksmith-swift/documentation/),
[getting-started guide](https://modern-swift-dev.github.io/docs/mocksmith-swift/documentation/getting-started/),
and [code examples](https://modern-swift-dev.github.io/docs/mocksmith-swift/examples/). The generated API
documentation is available by module: [Mocksmith](https://modern-swift-dev.github.io/docs/mocksmith-swift/documentation/api/mocksmith/documentation/mocksmith/),
[MocksmithCombine](https://modern-swift-dev.github.io/docs/mocksmith-swift/documentation/api/mocksmithcombine/documentation/mocksmithcombine/),
[MocksmithTesting](https://modern-swift-dev.github.io/docs/mocksmith-swift/documentation/api/mocksmithtesting/documentation/mocksmithtesting/),
and [MocksmithXCTest](https://modern-swift-dev.github.io/docs/mocksmith-swift/documentation/api/mocksmithxctest/documentation/mocksmithxctest/).

The shared documentation theme is maintained in the central documentation repository. The generated DocC pages use
Swift DocC's standard JavaScript and automatic color-scheme behavior.

Build an importable DocC bundle locally with a stable release version:

```sh
make docs-release VERSION=1.0.1
```

This creates `build/Mocksmith-Documentation-1.0.1.zip`. New GitHub releases include the same ZIP, containing `Mocksmith.doccarchive`, `MocksmithCombine.doccarchive`, `MocksmithTesting.doccarchive`, and `MocksmithXCTest.doccarchive` beneath a versioned top-level folder. Download and unzip the release asset, then open any `.doccarchive` in Xcode; it appears in Xcode's Imported Documentation browser.

For progressive, runnable examples covering basic through advanced mocking, see the
[samples guide](samples/README.md) or the site's [examples](https://modern-swift-dev.github.io/docs/mocksmith-swift/examples/).

## Basic usage

```swift
import Mocksmith
import MocksmithTesting

@Mockable
protocol WeatherService {
    var unit: String { get set }
    func temperature(for city: String) async throws -> Double
}

let weather = WeatherServiceMock()

Given(weather).temperature(for: .value("Toronto")).willReturn(20, 21)
Given(weather).unit.willReturn("C")
Given(weather).unit(set: .any)
Perform(weather).temperature(for: .any) { city in print(city) }

let value = try await weather.temperature(for: "Toronto")
weather.unit = "F"

Verify(weather, 1).temperature(for: .value("Toronto"))
Verify(weather, 1).unit(set: .value("F"))
```

Mocks are strict by default. For setup-oriented tests, opt into per-instance
defaults for unstubbed nonthrowing `Void` members, and optionally optional
results. Calls are still recorded and verified normally; throwing and static
requirements always remain strict.

```swift
let relaxed = WeatherServiceMock(defaults: .voidAndOptional)
```

Mocks can be configured inline. Required initializer calls are recorded before
the synchronous configuration closure runs:

```swift
let service = ServiceMock(seed: seed) {
    Given($0).load().willReturn(value)
}
```

Return sequences and throw sequences each consume values in order, then repeat the final outcome. Throwing members can mix typed outcomes in one registration:

```swift
Given(service).load(.any)
    .willReturn(cached)
    .thenThrow(.offline)
    .thenReturn(fresh)
```

Throwing `Void` members use `willSucceed`/`thenSucceed`; transient noncopyable members use `willProduce`/`thenProduce`. When registrations overlap, the matcher with the most non-`.any` parameters wins; the newest registration wins a tie.

Answers compute each outcome from the current invocation arguments and can be mixed with fixed outcomes:

```swift
Given(service).lookup(.any)
    .willAnswer { key in cache[key] }
    .thenReturn(fallback)
    .thenAnswer { key in refresh(key) }

Given(service).fetch(.any).willAnswer { key in
    await remote.fetch(key)
}
```

Synchronous answers receive normal arguments plus any nonescaping callbacks. Async answers receive only recordable arguments, and execute outside the mock's lock. Throwing answers use Swift's ordinary `throws` closure type; typed-throws witnesses still reject errors outside their declared failure type. `willAnswer` is available for property getters and argumentless members, including throwing `Void` methods; it is omitted for `rethrows` members and parameter packs. Noncopyable answer arguments are borrowed.

Retained async methods, getters, and subscripts can defer completion with `willSuspend()`. The returned controller records calls and resumes them FIFO:

```swift
let pending = Given(service).fetch(.any).willSuspend()
let control = pending.control
let task = Task { try await service.fetch("key") }

try await control.waitUntilCalled(timeout: .seconds(1))
control.resume(returning: "value")
let value = try await task.value
```

`control` is a public `PendingCall<Arguments, Output, Failure>` that can be stored without naming the underscored fluent sequence type. Cancellation is ignored by default, leaving the call pending for explicit resumption. Throwing requirements can instead use `willSuspend(cancellation: .fail(with: failure))`. Deferred outcomes compose with `thenReturn`, `thenSucceed`, `thenThrow`, `thenAnswer`, `thenResolve`, and `thenSuspend`; the final deferred outcome repeats and concurrent calls remain FIFO. Resetting stubs prevents future selection without invalidating calls that are already pending. Transient noncopyable members do not retain values and therefore do not offer suspension controllers.

Throwing retained members can consume `Result` values directly, including suspended calls:

```swift
Given(service).fetch(.any)
    .willResolve(.success("cached"))
    .thenResolve(.failure(.unavailable))

control.resume(with: result)
```

The runtime channel types now include ephemeral arguments: `MockMember<Arguments, Ephemeral, Output>` and `TransientMockMember<Arguments, Ephemeral, Output>`. Direct runtime users should pass `Void` when no nonescaping callback payload exists.

## Matching, capture, and reset

`Parameter<Value>` provides `.any`, `.value(_:)` for equatable values, `.value(_:by:)`, `.matching(_:)`, `.sameInstance(_:)`, and `.capturing(_:)`:

```swift
let cities = ArgumentCaptor<String>()
Verify(weather, .atLeast(1)).temperature(for: .capturing(cities))
let lastCity = cities.lastValue
VerifyNoMoreInteractions(weather)

resetMock(weather)                         // all state
resetMock(weather, scopes: [.invocations]) // selected state
resetMock(ServiceMock.self, scopes: [.stubs, .actions])
```

Verification counts include integer literals, `.never`, `.exactly`, `.atLeast`, `.atMost`, and `.between`.
Successful verification marks matching calls; `VerifyNoMoreInteractions` reports any calls not covered by successful verification.

`Calls` provides an observational typed history without marking invocations as verified. Use it for synchronization or argument inspection, then verify separately:

```swift
let calls = Calls(weather).temperature(for: .value("Toronto"))
try await calls.waitForCount(1, timeout: .seconds(1))
let city = try calls.onlyArgument
Verify(weather, 1).temperature(for: .value(city))
```

Histories also provide optional `firstArgument`, `lastArgument`, and `argument(at:)` access. `waitForCount` requires an explicit timeout and throws `MockWaitError.timedOut` if the count is not reached.

When importing a runner adapter, waits and required arguments can report directly at the caller:

```swift
await calls.expectCount(2, timeout: .seconds(1))
let latest = try calls.requireLastArgument()
await control.expectCalled(count: 1, timeout: .seconds(1))
```

## Property state

Generated mocks expose controllers for retained properties. Get-only properties remain test-mutable through their controller, while assignments to get/set mock properties update the same state:

```swift
let token = MockState(keychain).token(initial: nil)
token.value = "new-token"

let status = MockState(repository).status(initial: .success(.ready))
status.fail(with: .unavailable)

let shared = MockState(ServiceMock.self).sharedValue(initial: 1)
```

Property state supports synchronous, async, throwing, instance, and static getters. Transient noncopyable properties are excluded because their values cannot be retained. Resetting invocations preserves controller values; stub and action resets disconnect the corresponding property behavior.

## Combine publishers

Apple clients can add the optional `MocksmithCombine` product to replace `CurrentValueSubject` setup for requirements returning `AnyPublisher`:

```swift
import MocksmithCombine

let snapshots = Given(repository).snapshots.willPublish(current: initial)
snapshots.send(next)
snapshots.finish()
```

`PublisherControl` also supports typed failures with `fail(_:)` or `send(completion:)`. The v1 helper intentionally targets synchronous, nonthrowing retained stubs returning `AnyPublisher`.

Strict in-order verification can span instance and static mocks:

```swift
VerifyInOrder { order in
    order.expect(repository).load(.value(id))
    order.expect(cache).save(.value(item))
    order.expect(NotifierMock.self).notify()
}
```

The first expectation may match anywhere in participating mocks' history. Each later expectation must match the immediate next participating invocation; calls before the first, after the last, and on mocks without expectations are ignored.

## Static members and subscripts

```swift
Given(ServiceMock.self).make(.value(2)).willReturn("two")
Given(mock).subscriptGet(.value("answer")).willReturn(42)
Given(mock).subscriptSet(.value("answer"), value: .value(43))

Verify(ServiceMock.self, 1).make(.value(2))
Verify(mock, 1).subscriptGet(.value("answer"))
```

Static state is isolated by concrete mock metatype and generic specialization. Required initializers construct without stubbing, record their arguments, and can be checked with `Verify(mock).initializer(...)`. Generic initializers and value-pack initializers use the same typed verification selector.

## Noncopyable requirements

Use `@MockNoncopyable` when a requirement mentions a named noncopyable type. Requirements that syntactically use `~Copyable` are selected automatically:

```swift
struct Token: ~Copyable { let raw: Int }

@Mockable
protocol TokenService: ~Copyable {
    @MockNoncopyable
    func inspect(_ token: borrowing Token) -> Int
}

let mock = TokenServiceMock()
Given(mock).inspect(.matching { $0.raw == 7 }).willProduce({ 1 })
Verify(mock, 1).inspect()
```

These members use a transient channel: arguments are borrowed and never retained, `.any` and `.matching` select a producer, and `willProduce` sequences repeat their final producer. `Perform` receives borrowed arguments. Post-call verification is count-only, so `.inspect()` takes no argument matchers. `Parameter<Value>` supports noncopyable values; `.value` and captors remain copyable-only.

## Supported protocol syntax

`@Mockable` supports:

- instance and static methods, properties, and subscripts;
- read-only/read-write properties and subscripts, including async, untyped/typed-throwing getters and static or generic subscripts;
- sync/async methods, untyped throws, typed throws, and `rethrows`;
- generic methods, initializers, and subscripts with constraints;
- standard value packs, plus `some Protocol` input parameters;
- associated and primary associated types with constraints;
- overloads, variadics, `inout` snapshots, and copyable ownership modifiers;
- `Self` inputs/results and dependent `Self.Associated` paths;
- `AnyObject`, `Sendable`, `Actor`, `~Copyable`, protocol/member availability, and global-actor isolation.

Nonescaping callback values are forwarded synchronously to `Perform` and are never retained; remaining arguments stay matchable and verifiable:

```swift
Perform(mock).load(.value(4)) { key, completion in completion(key + 1) }
mock.load(4) { value in print(value) }
```

This applies to `rethrows` too. Multiple ordinary nonescaping closure parameters are supported. Nonescaping initializer closures remain unsupported because an initializer cannot safely retain or replay them.

## Inherited protocols and composition aliases

Attach `@Mockable` to the child protocol. The build plugin recursively collects requirements from parent protocols in the same package or a reachable SwiftPM source dependency and emits the complete mock directly as Swift source:

```swift
protocol Parent {
    func inherited(_ value: Int) -> String
}

@Mockable
protocol Child: Parent {
    init(seed: Int)
    func own() -> Int
}
```

`ChildMock` includes parent and child methods, properties, subscripts, initializers, typed DSL builders, channels, and resets. Composition aliases work through an annotated protocol:

```swift
typealias Combined = ParentA & ParentB

@Mockable
protocol CombinedService: Combined {}
```

External parents need no extra macro arguments:

```swift
import ExternalServices

@Mockable
protocol LocalService: ExternalServices.Service {}
```

Inherited mocks must be unconditional, top-level `internal`, `package`, or `public` protocols, and their requirement types must be visible from generated source. Parent protocols from another package must be `public`. Use `@Mockable(.macro)` for `private`, `fileprivate`, nested, or conditional direct protocols.

## Objective-C protocols

On Apple platforms, `@Mockable` supports `@objc` protocols inheriting `NSObjectProtocol`, including optional methods and properties. Generated mocks subclass `NSObject`, preserve Objective-C attributes/selectors, and provide the normal strict typed DSL. This support is unavailable on Linux.

## Strict behavior

Generated mocks are strict unless constructed with `defaults: .void` or `.voidAndOptional`. Those opt-in policies supply only unstubbed, nonthrowing instance `Void` members and, for `.voidAndOptional`, optional results; properties, setters, and subscripts follow the same rule. Calls still record normally. Value-returning members otherwise need a matching `Given`; `Perform` also satisfies `Void` members because it installs the required `Void` outcome. Throwing and static members always remain strict. Untyped throwing members throw `MockError.unstubbed`. Nonthrowing, `rethrows`, and incompatible typed-throws members stop with a precise precondition failure because they cannot legally throw a framework error. Required initializers are the only unstubbed exception.

Use `.void` for setup mocks whose unstubbed nonthrowing `Void` requirements should be no-ops, and `.voidAndOptional` when unstubbed optional results should additionally return `nil`. Strict remains the default for behavior under test.

## Test runners

`MocksmithTesting.Verify` records a failed `VerificationResult` with `Testing.Issue.record` and the caller's `SourceLocation`. `MocksmithXCTest.Verify` uses `XCTFail(_:file:line:)`. Their call-history and pending-call assertion extensions use the same reporting mechanism. If both adapters are imported, qualify `Verify` with the module name and keep identically named assertion extensions in files that import only one runner adapter.

## Swift 6.3 limits

Distributed actors are unsupported. Protocol requirements cannot use opaque `some` results in Swift; `some` input parameters are supported. Swift 6.3 rejects noncopyable associated types, so Mocksmith diagnoses them precisely. Parameter packs currently require one pack parameter, and named noncopyable types require `@MockNoncopyable`.

Inherited protocol resolution requires ordinary, unconditional top-level Swift source reachable through the target's SwiftPM dependency graph. Binary XCFrameworks, SDK and precompiled modules, conditional declarations, macro-synthesized declarations, and dependency plugin-generated source are unsupported. Generic requirements with several noncopyable arguments require a named wrapper parameter. Transient requirements with nonescaping callbacks, nonescaping initializer closures, and settable parameter-pack subscripts remain excluded with targeted diagnostics.
