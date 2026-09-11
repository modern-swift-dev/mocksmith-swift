import Mocksmith
import MocksmithTesting
import Testing

private enum CatalogFailure: Error, Equatable {
    case offline
    case timedOut
}

@Mockable(.macro) private protocol SequencedCatalogService {
    func item(id: Int) throws -> String
    func failingItem(id: Int) throws(CatalogFailure) -> String
    func refresh(_ category: String)
    func rank(for id: Int) -> Int
}

@Test private func returnAndThrowSequencesRepeatTheirLastOutcome() throws {
    let returning = SequencedCatalogServiceMock()

    // Variadic willReturn values are consumed in order. Once exhausted, the
    // final value repeats so callers can make more requests safely.
    Given(returning).item(id: .any).willReturn("first", "second")
    #expect(try returning.item(id: 1) == "first")
    #expect(try returning.item(id: 1) == "second")
    #expect(try returning.item(id: 1) == "second")

    let throwing = SequencedCatalogServiceMock()

    // willThrow has the same sequence behavior.
    Given(throwing).failingItem(id: .any).willThrow(.offline, .timedOut)
    #expect(throws: CatalogFailure.offline) { try throwing.failingItem(id: 1) }
    #expect(throws: CatalogFailure.timedOut) { try throwing.failingItem(id: 1) }
    #expect(throws: CatalogFailure.timedOut) { try throwing.failingItem(id: 1) }

    let mixed = SequencedCatalogServiceMock()

    // thenReturn and thenThrow append typed outcomes to one registration.
    Given(mixed).failingItem(id: .any)
        .willReturn("cached")
        .thenThrow(.offline)
        .thenReturn("fresh")
    #expect(try mixed.failingItem(id: 1) == "cached")
    #expect(throws: CatalogFailure.offline) { try mixed.failingItem(id: 1) }
    #expect(try mixed.failingItem(id: 1) == "fresh")
}

@Test private func performAddsSideEffectsAndSatisfiesVoidMembers() {
    let catalog = SequencedCatalogServiceMock()
    var refreshed: [String] = []

    // Perform runs a closure after a matching invocation. For a Void member it
    // also installs the required Void outcome, so a separate Given is needless.
    Perform(catalog).refresh(.any) { refreshed.append($0) }

    catalog.refresh("books")
    catalog.refresh("music")

    #expect(refreshed == ["books", "music"])
    Verify(catalog, 2).refresh(.any)
}

@Test private func specificMatchersWinAndNewestRegistrationBreaksTies() {
    let catalog = SequencedCatalogServiceMock()

    // Specific matchers beat `.any`, even when the broad registration is newer.
    Given(catalog).rank(for: .value(7)).willReturn(70)
    Given(catalog).rank(for: .any).willReturn(0)
    #expect(catalog.rank(for: 7) == 70)
    #expect(catalog.rank(for: 8) == 0)

    // Equal-specificity registrations use the newest matching registration.
    Given(catalog).rank(for: .value(7)).willReturn(71)
    #expect(catalog.rank(for: 7) == 71)
}

@Test private func untypedThrowingMembersReportSafeUnstubbedErrors() {
    let catalog = SequencedCatalogServiceMock()

    // Untyped `throws` can legally surface MockError, making strict behavior
    // testable without crashing the test process.
    #expect(throws: MockError.self) {
        try catalog.item(id: 404)
    }

    // Unstubbed nonthrowing members intentionally stop with a precondition
    // failure. See samples/README.md for that non-runnable example.
}
