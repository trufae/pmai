import Testing

@testable import MaiCore

@Test("Repeated awake toggles release the inhibitor without acquiring extra locks")
@MainActor func awakeReleasesInhibitor() throws {
  var held = 0
  let controller = AwakeController(acquire: {
    held += 1
    return { held -= 1 }
  })
  try controller.setEnabled(true)
  try controller.setEnabled(true)
  #expect(controller.isEnabled)
  #expect(held == 1)
  try controller.setEnabled(false)
  try controller.setEnabled(false)
  #expect(!controller.isEnabled)
  #expect(held == 0)
  try controller.setEnabled(true)
  try controller.setEnabled(false)
  #expect(held == 0)
}

@Test("Failed awake requests remain off and can be retried")
@MainActor func awakeFailureDoesNotEnable() throws {
  var unavailable = true
  let controller = AwakeController(acquire: {
    if unavailable { throw AwakeError.unavailable("No power manager") }
    return {}
  })
  #expect(throws: AwakeError.self) { try controller.setEnabled(true) }
  #expect(!controller.isEnabled)
  unavailable = false
  try controller.setEnabled(true)
  #expect(controller.isEnabled)
  try controller.setEnabled(false)
}
