import Testing

@testable import MaiCLI

@Test("Rejected submissions retain their original prompt and multiline draft")
func replRecoveredInput() {
  var recovery = REPLRecoveredInput()
  recovery.keep("yes", promptID: "old-approval")
  recovery.keep("first\nsecond", promptID: nil)
  #expect(recovery.entries[0].promptID == "old-approval")
  #expect(recovery.take(0) == nil)
  #expect(recovery.entries.count == 2)
  #expect(recovery.take(2) == "first\nsecond")
  #expect(recovery.take(1) == "yes")
  #expect(recovery.entries.isEmpty)
}
