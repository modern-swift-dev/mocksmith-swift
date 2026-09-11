import Mocksmith
import MocksmithTesting
import Testing

@Mockable
protocol BuildPluginService {
    init(seed: Int)
    var title: String { get set }
    func value(for key: String) -> Int
    func echo<Value: Equatable>(_ value: Value) -> Value
}

@Test private func buildPluginMockSupportsStubbingAndVerification() {
    let mock = BuildPluginServiceMock(seed: 7)

    Given(mock).title.willReturn("ready")
    Given(mock).title(set: .any)
    Given(mock).value(for: .value("key")).willReturn(42)
    Given(mock).echo(.value("input")).willReturn("output")
    Given(mock).echo(.value(1)).willReturn(2)

    #expect(mock.title == "ready")
    mock.title = "updated"
    #expect(mock.value(for: "key") == 42)
    #expect(mock.echo("input") == "output")
    #expect(mock.echo(1) == 2)

    Verify(mock, 1).initializer(seed: .value(7))
    Verify(mock, 1).title()
    Verify(mock, 1).title(set: .value("updated"))
    Verify(mock, 1).value(for: .value("key"))
    Verify(mock, 1).echo(.value("input"))
    Verify(mock, 1).echo(.value(1))
    VerifyNoMoreInteractions(mock)
}
