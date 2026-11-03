#if canImport(ExternalChildProtocols)
    import ExternalChildProtocols
#endif
import Mocksmith
import MocksmithTesting
import Testing

/// `ExternalBaseProtocol` is declared in ExternalBaseProtocols, which this file
/// reaches only through a conditional import of ExternalChildProtocols and its
/// `@_exported import`.
@Mockable protocol ReexportedExternalChild: ExternalBaseProtocol {
    func ownValue() -> Int
}

@Test private func inheritedProtocolResolvesThroughConditionalReexport() {
    let mock = ReexportedExternalChildMock()
    Given(mock).baseValue(.value(1)).willReturn("one")
    Given(mock).ownValue().willReturn(2)

    #expect(mock.baseValue(1) == "one")
    #expect(mock.ownValue() == 2)

    Verify(mock, 1).baseValue(.value(1))
    Verify(mock, 1).ownValue()
}
