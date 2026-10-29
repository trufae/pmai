import Foundation
import MaiCore
import Testing

@testable import MaiCLI

@Test("Session yolo approves path asks without changing project or global defaults")
func sessionYoloApproval() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pmai-approval-\(UUID())")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let settings = directory.appendingPathComponent("settings.json")
  let saved = Data(#"{"approvalMode":"ask"}"#.utf8)
  try saved.write(to: settings)
  let handler = try TerminalApprovalHandler(configuration: .init(mode: .smart), projectSettingsURL: settings)
  await handler.setPrompter { _ in .deny(reason: "Needs a person") }
  let path = directory.appendingPathComponent("secret.pem")
  #expect(!(try await handler.decidePromptPathAccess(path, preparingTurn: false, forceConfirmation: true)))
  await handler.setApprovalMode(.yolo)
  #expect(await handler.currentApprovalMode() == .yolo)
  #expect(try await handler.decidePromptPathAccess(path, preparingTurn: false, forceConfirmation: true))
  #expect(try await handler.decidePromptPathAccess(path, preparingTurn: true, forceConfirmation: true))
  // Other saved settings must not accidentally persist the session override.
  try await handler.saveDebugEnabled(true)
  let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: settings))
  #expect(value.objectValue?["approvalMode"] == .string("ask"))
  let restarted = try TerminalApprovalHandler(configuration: .init(mode: .smart), projectSettingsURL: settings)
  #expect(await restarted.currentApprovalMode() == .ask)
  await handler.setApprovalMode(.ask)
  #expect(!(try await handler.decidePromptPathAccess(path, preparingTurn: false, forceConfirmation: true)))
  try await handler.saveApprovalMode(.yolo)
  #expect(await handler.currentApprovalMode() == .yolo)
  #expect(!(try await handler.decidePromptPathAccess(path, preparingTurn: false, forceConfirmation: true)))
}

@Test("Always yolo persists path approvals for one project and session ask overrides it")
func persistentYoloApproval() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pmai-approval-\(UUID())")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let settings = directory.appendingPathComponent("settings.json")
  let handler = try TerminalApprovalHandler(configuration: .init(), projectSettingsURL: settings)
  try await handler.saveApprovalMode(.yolo, includingPaths: true)
  let restarted = try TerminalApprovalHandler(configuration: .init(), projectSettingsURL: settings)
  #expect(await restarted.permitsUnattendedPathAccess())
  let other = try TerminalApprovalHandler(
    configuration: .init(), projectSettingsURL: directory.appendingPathComponent("other.json"))
  #expect(await other.currentApprovalMode() == .ask)
  #expect(!(await other.permitsUnattendedPathAccess()))
  await restarted.setApprovalMode(.ask)
  #expect(!(await restarted.permitsUnattendedPathAccess()))
  let again = try TerminalApprovalHandler(configuration: .init(), projectSettingsURL: settings)
  #expect(await again.permitsUnattendedPathAccess())
  try await again.saveApprovalMode(.ask)
  let disabled = try TerminalApprovalHandler(configuration: .init(), projectSettingsURL: settings)
  #expect(!(await disabled.permitsUnattendedPathAccess()))
}
