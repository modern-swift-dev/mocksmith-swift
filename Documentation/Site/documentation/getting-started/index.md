---
title: "Getting started | Mocksmith"
description: "Install Mocksmith and write a first strict protocol mock."
---

<a id="content"></a>

Getting started

# Your first recorded call

Create a generated mock, register one result, call the original protocol member, then compare the recorded invocation with a typed expectation.

On this page

- [Requirements](/docs/mocksmith-swift/documentation/getting-started/#requirements)

- [Installation](/docs/mocksmith-swift/documentation/getting-started/#installation)

- [First call snapshot](/docs/mocksmith-swift/documentation/getting-started/#first-call-snapshot)

- [Recording](/docs/mocksmith-swift/documentation/getting-started/#recording)

- [Comparison workflow](/docs/mocksmith-swift/documentation/getting-started/#comparison)

## Requirements

Use Swift 6.3 or newer. Mocksmith supports Linux, iOS 17, macOS 13, tvOS 17, and watchOS 10 or newer.

## Installation

Add the current release to your package dependencies.

Package.swift

```swift
.package(
    url: "https://github.com/modern-swift-dev/mocksmith-swift.git",
    exact: "{{version}}"
)
```

Add `Mocksmith`, exactly one runner adapter, and the build plugin to your test target. This example uses Swift Testing. Choose `MocksmithXCTest` instead for XCTest.

Package.swift

```swift
.testTarget(
    name: "AppTests",
    dependencies: [
        .product(name: "Mocksmith", package: "mocksmith-swift"),
        .product(name: "MocksmithTesting", package: "mocksmith-swift")
    ],
    plugins: [
        .plugin(name: "MocksmithBuildPlugin", package: "mocksmith-swift")
    ]
)
```

The plugin resolves inherited protocols and composition aliases in the test target's reachable SwiftPM source dependencies. A direct protocol can use the macro without plugin work, but attaching the plugin to the test target keeps both cases covered.

## First call snapshot

Mocksmith does not write snapshot files. Its snapshot of test behavior is the typed invocation history held by each mock. The test below registers a result, makes one call, and verifies the recorded argument.

WeatherServiceTests.swift

```swift
import Mocksmith
import MocksmithTesting
import Testing

@Mockable
protocol WeatherService {
    func temperature(for city: String) async throws -> Double
}

@Test func readsTheTemperature() async throws {
    let weather = WeatherServiceMock()
    Given(weather).temperature(for: .value("Toronto")).willReturn(20)

    let result = try await weather.temperature(for: "Toronto")

    #expect(result == 20)
    Verify(weather, 1).temperature(for: .value("Toronto"))
}
```

## Recording

`Calls` reads a member's invocation history without marking calls as verified. Use it when a test must wait for an async call or inspect captured arguments before the final assertion.

Inspecting call history

```swift
let calls = Calls(weather).temperature(for: .value("Toronto"))
try await calls.waitForCount(1, timeout: .seconds(1))

let city = try calls.onlyArgument
Verify(weather, 1).temperature(for: .value(city))
VerifyNoMoreInteractions(weather)
```

<a id="comparison"></a>

## Comparison workflow

- Use `Given` to register the outcome required by the test.

- Call the mock through the protocol API.

- Use `Verify` with a matcher and count. Add `VerifyNoMoreInteractions` when every call should be accounted for.

### Recorded call compared with the expectation

<a id="expected-heading"></a>

#### Expected

temperature(for: "Toronto")

count: exactly 1

<a id="recorded-heading"></a>

#### Recorded

temperature(for: "Toronto")

1 matching call

Mocks are strict by default. An unstubbed throwing member reports `MockError.unstubbed`. Nonthrowing members stop because their signatures have no legal error result. For setup-heavy tests, pass `defaults: .voidAndOptional` to relax only unstubbed nonthrowing `Void` and optional results.

[Continue to the examples](/docs/mocksmith-swift/examples/) for matchers, call sequences, and property state.
