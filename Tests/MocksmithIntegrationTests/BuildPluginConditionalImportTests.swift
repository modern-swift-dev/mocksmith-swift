import Mocksmith
import MocksmithTesting
import Testing

#if canImport(Foundation)
    #if true
        import Foundation
    #elseif false
        import Foundation
    #else
        import Foundation
    #endif

    enum BuildPluginConditionalImportMarker {}
#endif

@Mockable
protocol BuildPluginURLService {
    func destination() -> Foundation.URL
}

@Test private func buildPluginMockPreservesConditionalImports() {
    let mock = BuildPluginURLServiceMock()
    let destination = Foundation.URL(fileURLWithPath: "/mocksmith/fixture")
    Given(mock).destination().willReturn(destination)

    #expect(mock.destination() == destination)
    Verify(mock, 1).destination()
}
