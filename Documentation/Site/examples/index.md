---
title: "Examples | Mocksmith"
description: "Focused Mocksmith examples based on the compiled sample suite."
---

<a id="content"></a>

Examples

# Public API, in focused tests

These examples use the same APIs as the repository's `MocksmithSamples` test target. Copy the shape, then replace the protocols and values with your own.

## Stub and verify a method

`.value` matches one equatable argument. The generated selector keeps the return type and thrown error behavior aligned with the protocol.

Basic stubbing

```swift
@Mockable
protocol Store {
    func value(for key: String) throws -> Int
}

let store = StoreMock()
Given(store).value(for: .value("answer")).willReturn(42)

let value = try store.value(for: "answer")
Verify(store, 1).value(for: .value("answer"))
```

## Mix results and errors

Outcome sequences consume entries in order, then repeat the last one. Throwing members can mix values and typed errors in a single registration.

A three-step outcome sequence

```swift
Given(service).load(.any)
    .willReturn(cached)
    .thenThrow(.offline)
    .thenReturn(fresh)

let first = try service.load("key")
#expect(throws: NetworkError.offline) {
    try service.load("key")
}
let third = try service.load("key")
```

## Capture arguments

A capturing matcher collects recorded arguments while `Verify` scans call history. It works with the same count forms as other matchers.

Argument capture

```swift
let cities = ArgumentCaptor<String>()
Given(weather).temperature(for: .any).willReturn(20)

_ = try await weather.temperature(for: "Toronto")
_ = try await weather.temperature(for: "Montreal")

Verify(weather, 2).temperature(for: .capturing(cities))
#expect(cities.values == ["Toronto", "Montreal"])
VerifyNoMoreInteractions(weather)
```

## Control property state

`MockState` gives tests direct control over retained generated properties. Assignments to a get-set mock property update the same state.

Property state

```swift
let token = MockState(keychain).token(initial: nil)
token.value = "new-token"

#expect(keychain.token == "new-token")
Verify(keychain, 1).token()
```

## Suspend an async call

`willSuspend` returns a controller for deterministic async tests. The controller observes calls and resumes them in first-in, first-out order.

Deferred completion

```swift
let pending = Given(service).fetch(.any).willSuspend()
let control = pending.control
let task = Task { try await service.fetch("key") }

try await control.waitUntilCalled(timeout: .seconds(1))
control.resume(returning: "value")
#expect(try await task.value == "value")
```

## Run the complete samples

The repository covers callbacks, generics, actors, inherited protocols, noncopyable inputs, XCTest, and strict-order verification.

[Open the sample suite](https://github.com/modern-swift-dev/mocksmith-swift/tree/main/samples) [API reference](/docs/mocksmith-swift/documentation/)
