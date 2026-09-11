---
title: "Mocksmith"
description: "Strict, compile-time protocol mocks for Swift 6.3 tests."
---

<a id="content"></a>

Protocol mocks for Swift 6.3

# Strict mocks, checked by the compiler.

Mocksmith's build plugin generates protocol mocks from `@Mockable` declarations before compilation. There is no Sourcery phase and no generated source to commit.

[Get started](/docs/mocksmith-swift/documentation/getting-started/) [See compiled examples](/docs/mocksmith-swift/examples/)

## Latest release

{{version}}

Published {{releaseDate}}

[Release notes]({{releaseURL}})

Package version {{version}}

One typed workflow

## Stub, call, verify.

Attach `@Mockable` to a protocol and add `MocksmithBuildPlugin` to its declaring target. The generated mock keeps test setup tied to the protocol declaration.

WeatherServiceTests.swift

```swift
import Mocksmith
import MocksmithTesting

@Mockable
protocol WeatherService {
    func temperature(for city: String) async throws -> Double
}

let weather = WeatherServiceMock()
Given(weather).temperature(for: .value("Toronto")).willReturn(20)

let value = try await weather.temperature(for: "Toronto")
Verify(weather, 1).temperature(for: .value("Toronto"))
```

Capabilities

## Enough control for real test suites

### Typed from protocol to assertion

Mocksmith generates the mock and its Given, Perform, Calls, and Verify selectors. Swift checks member names, arguments, and result types.

### Strict until you say otherwise

An unstubbed call does not invent a result. Choose per-instance defaults only when a setup-heavy test needs them.

### Modern Swift requirements

Mock async and typed-throwing members, actors, generics, static members, subscripts, ownership modifiers, and noncopyable inputs.

### Control over time

Return sequences, compute answers from arguments, suspend async calls, capture values, and verify order across mocks.

Call comparison

## Assertions use recorded invocations

Every generated mock records its calls. `Verify` compares that history with typed matchers and a call count. Successful checks mark their calls, so `VerifyNoMoreInteractions` can catch anything left over.

### Recorded call compared with the expectation

<a id="expected-heading"></a>

#### Expected

temperature(for: "Toronto")

count: exactly 1

<a id="recorded-heading"></a>

#### Recorded

temperature(for: "Toronto")

1 matching call

Platform support

## Swift 6.3, across Apple and Linux

Apple platforms

iOS 17, macOS 13, tvOS 17, and watchOS 10 or newer

Linux

Supported with the Swift 6.3 toolchain

Swift Testing

Use the MocksmithTesting adapter

XCTest

Use the MocksmithXCTest adapter

Provenance you can inspect

## The examples are package tests

The repository's sample target compiles the same public API shown here. Macro tests cover generated declarations, while runtime and integration tests exercise call recording, stubbing, adapters, and inherited protocols.

### Read the guides

Start with installation, then move through the module reference.

[Read the guide](/docs/mocksmith-swift/documentation/)

### Open the source

Inspect the package, tests, and executable sample suite on GitHub.

[Browse GitHub](https://github.com/modern-swift-dev/mocksmith-swift)
