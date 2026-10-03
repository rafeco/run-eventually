import Testing
@testable import RunEventuallyCore

@Test func modelSmoke() {
    #expect(RunState.pending.rawValue == "pending")
}
