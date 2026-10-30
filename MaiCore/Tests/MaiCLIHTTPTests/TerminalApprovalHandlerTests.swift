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

@Test("Tool-specific yolo survives restart without approving other tools or paths")
func toolSpecificYoloApproval() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pmai-approval-\(UUID())")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let settings = directory.appendingPathComponent("settings.json")
  let handler = try TerminalApprovalHandler(configuration: .init(), projectSettingsURL: settings)
  let tool = ToolDefinition(name: "files_write", description: "Write a file")
  let other = ToolDefinition(name: "files_read", description: "Read a file")
  try await handler.saveToolYolo(tool.name)
  try await handler.saveDebugEnabled(true)
  let restarted = try TerminalApprovalHandler(configuration: .init(), projectSettingsURL: settings)
  await restarted.setPrompter { _ in .deny(reason: "Needs a person") }
  #expect(await restarted.currentApprovalMode() == .ask)
  #expect(await restarted.toolApprovalMode(for: tool) == .yolo)
  #expect(await restarted.toolApprovalMode(for: other) == .ask)
  #expect(await restarted.yoloTools() == ["files_write"])
  let request = ApprovalRequest(
    run: .init(runID: UUID(), parentRunID: nil, agentID: "main", depth: 0),
    tool: tool, call: .init(id: "write", name: tool.name, arguments: .object(["path": .string("new.txt")])))
  #expect(try await restarted.decide(request) == .approve(arguments: request.call.arguments))
  var otherRequest = request
  otherRequest.tool = other
  otherRequest.call.name = other.name
  #expect(!(await restarted.permitsUnattendedApproval(otherRequest)))
  #expect(try await restarted.decide(otherRequest) == .deny(reason: "Needs a person"))
  #expect(!(try await restarted.decidePromptPathAccess(
    directory.appendingPathComponent("secret.pem"), preparingTurn: false, forceConfirmation: true)))

  try await restarted.focusProject(directory.appendingPathComponent("other.json"))
  #expect(await restarted.toolApprovalMode(for: tool) == .ask)
  try await restarted.focusProject(settings)
  #expect(await restarted.toolApprovalMode(for: tool) == .yolo)
  try await restarted.saveApprovalMode(.ask)
  let revoked = try TerminalApprovalHandler(configuration: .init(), projectSettingsURL: settings)
  #expect(await revoked.toolApprovalMode(for: tool) == .ask)
  try await revoked.saveToolYolo(tool.name)
  try await revoked.resetSettings()
  #expect(await revoked.toolApprovalMode(for: tool) == .ask)
}
