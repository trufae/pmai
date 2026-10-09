import Foundation
import MaiCore
import XCTest

@testable import PocketMai

@MainActor
final class SkillToolsTests: XCTestCase {
  private var store: AppStore!
  private var temporaryDirectory: URL!
  private var skills: [AgentSkill] = []

  override func setUp() async throws {
    try await super.setUp()
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ios-skills-\(UUID().uuidString)")
    store = AppStore(persistence: PersistenceStore(localBaseURL: temporaryDirectory))
    try await waitUntil { self.store.hasLoadedPersistedSettings }
    for label in ["review", "fix"] {
      let name = "\(label)-\(UUID().uuidString)"
      let folder = temporaryDirectory.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try
        "---\nname: \(name)\ndescription: Apply \(label) to the task.\n---\n\(label) instructions: $ARGUMENTS"
        .write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
      try "Supporting reference".write(
        to: folder.appendingPathComponent("reference.txt"), atomically: true, encoding: .utf8)
      try SkillTools.importFolder(folder)
      skills.append(
        try XCTUnwrap(
          AgentSkill.load(directory: SkillTools.directoryURL.appendingPathComponent(name))))
    }
  }

  override func tearDown() async throws {
    for request in store.toolCallApprovalRequests {
      store.interruptToolCallApproval(id: request.id)
    }
    for skill in skills { try? FileManager.default.removeItem(at: skill.directoryURL) }
    skills = []
    store = nil
    try? FileManager.default.removeItem(at: temporaryDirectory)
    StubChatEndpoint.uninstall()
    try await super.tearDown()
  }

  func testSkillsUseTheToolCatalogAndRecheckAvailabilityAtDispatch() async throws {
    let skill = skills[0]
    var settings = AppSettings()
    settings.airplaneModeEnabled = true
    var conversation = Conversation()
    conversation.enabledTools = []
    conversation.enabledMCPServers = []
    XCTAssertTrue(SkillTools.definitions(for: conversation, settings: settings).isEmpty)
    settings.enabledSkillTools = [skill.toolName]
    let definitions = ToolAgentRegistry.definitions(for: conversation, settings: settings)
    XCTAssertTrue(definitions.contains { $0.name == skill.toolName })
    let call = ParsedToolCall(
      name: skill.toolName, arguments: ["arguments": "parser.swift"], rawBlock: "")
    let output = await ToolAgentRegistry.execute(
      call: call, conversation: conversation, settings: settings, store: store)
    XCTAssertTrue(output.contains("review instructions: parser.swift"))
    XCTAssertEqual(
      try String(
        contentsOf: skill.directoryURL.appendingPathComponent("reference.txt"),
        encoding: .utf8), "Supporting reference")

    settings.useToolProxy = true
    let proxy = ToolAgentRegistry.visibleDefinitions(for: conversation, settings: settings)
    XCTAssertTrue(
      proxy.first { $0.name == ToolProxy.listName }?.description.contains(skill.toolName) == true)
    settings.useSystemOne = true
    let selectedOutput = await ToolAgentRegistry.execute(
      call: call, conversation: conversation, settings: settings, store: store)
    XCTAssertTrue(selectedOutput.contains("review instructions: parser.swift"))
    settings.useToolProxy = false
    settings.enabledSkillTools = []
    let disabled = await ToolAgentRegistry.execute(
      call: call, conversation: conversation, settings: settings, store: store)
    XCTAssertTrue(disabled.hasPrefix("Error:"))
    XCTAssertFalse(disabled.contains("review instructions"))

    settings.enabledSkillTools = [skill.toolName]
    try "---\nname: \(skill.name)\ndisable-model-invocation: true\n---\nPrivate instructions"
      .write(to: skill.fileURL, atomically: true, encoding: .utf8)
    XCTAssertTrue(SkillTools.definitions(for: conversation, settings: settings).isEmpty)
    let removed = SkillTools.execute(call: call, conversation: conversation, settings: settings)
    XCTAssertTrue(removed.hasPrefix("Error:"))
    XCTAssertFalse(removed.contains("Private instructions"))
  }

  func testSkillSettingsAndFilesSurviveBackupAndPortableImport() async throws {
    let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    XCTAssertTrue(legacy.enabledSkillTools.isEmpty)
    XCTAssertNil(legacy.skillApprovalMode)
    store.settings.enabledSkillTools = [skills[0].toolName]
    store.settings.skillApprovalMode = .ask
    store.saveSettings()
    let saved = try JSONDecoder().decode(
      AppSettings.self, from: JSONEncoder().encode(store.settings))
    XCTAssertEqual(saved.enabledSkillTools, [skills[0].toolName])
    XCTAssertEqual(saved.selectedAgent.settings.skillApprovalMode, .ask)

    let exportedFile = await store.exportSettingsBackupFile(selection: .init(tools: true))
    let file = try XCTUnwrap(exportedFile)
    defer { try? FileManager.default.removeItem(at: file) }
    let archive = try MaiArchive.decode(from: Data(contentsOf: file))
    let exported = try XCTUnwrap(
      archive.skills?.first { $0.name == skills[0].directoryURL.lastPathComponent })
    XCTAssertTrue(exported.files.contains { $0.path == "reference.txt" })
    try FileManager.default.removeItem(at: skills[0].directoryURL)
    let result = try store.importPortableArchive(
      MaiArchive(generator: "test", skills: [exported]), selection: .init(tools: true))
    XCTAssertTrue(result.contains("1 skill"))
    XCTAssertNotNil(AgentSkill.load(directory: skills[0].directoryURL))
  }

  func testLiveSkillPolicyFollowsTheOwningAgent() {
    var live = AppSettings()
    live.enabledSkillTools = [skills[0].toolName]
    live.skillApprovalMode = .ask
    let child = live
    let other = live.addAgent(named: "Other")
    XCTAssertTrue(live.selectAgent(other.id))
    live.enabledSkillTools = []
    XCTAssertEqual(
      SkillTools.applyingLiveSettings(to: child, from: live).enabledSkillTools,
      [skills[0].toolName])
    XCTAssertTrue(live.selectAgent(child.selectedAgentID))
    live.enabledSkillTools = []
    XCTAssertTrue(SkillTools.applyingLiveSettings(to: child, from: live).enabledSkillTools.isEmpty)
  }

  func testSkillApprovalCanReplaceOrCancelDirectAndProxiedCalls() async throws {
    for proxy in [false, true] {
      for decision in ["replace", "cancel", "disable", "yolo"] {
        StubChatEndpoint.install()
        let conversation = configureConversation(proxy: proxy)
        let proposedName = skills[0].toolName
        let chosen = skills[1]
        if decision == "yolo" { store.settings.skillApprovalMode = .yolo }
        let apiName = AgentToolNameResolver(tools: ToolProxy.definitions).apiName(
          for: ToolProxy.callName)
        StubChatEndpoint.script = { request in
          let messages = request["messages"] as? [[String: Any]] ?? []
          if messages.contains(where: { $0["role"] as? String == "tool" }) {
            return (StubChatEndpoint.completion(content: "Finished"), 0)
          }
          let arguments: [String: Any] =
            proxy
            ? ["name": proposedName, "arguments": ["arguments": "parser.swift"]]
            : ["arguments": "parser.swift"]
          let json = String(
            decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
          return (
            [
              "choices": [
                [
                  "finish_reason": "tool_calls",
                  "message": [
                    "role": "assistant", "content": "",
                    "tool_calls": [
                      [
                        "id": "skill-call", "type": "function",
                        "function": ["name": proxy ? apiName : proposedName, "arguments": json],
                      ]
                    ],
                  ],
                ]
              ]
            ], 0
          )
        }
        let task = Task {
          try await AssistantToolLoop.runIsolated(
            conversation: conversation, settings: store.settings, baseContext: "", store: store)
        }
        defer { task.cancel() }
        if decision != "yolo" {
          try await waitUntil { self.store.activeToolCallApprovalRequest != nil }
          let approval = try XCTUnwrap(store.activeToolCallApprovalRequest)
          XCTAssertEqual(approval.skillSelection?.proposed.name, proposedName)
          XCTAssertEqual(approval.skillSelection?.skills.count, 2)
          if decision == "cancel" {
            store.cancelToolCallApproval(id: approval.id)
          } else {
            if decision == "disable" { store.settings.enabledSkillTools.remove(chosen.toolName) }
            XCTAssertNil(store.approveSkill(id: approval.id, toolName: chosen.toolName))
          }
        }
        let output = try await task.value
        let rejected = decision == "cancel" || decision == "disable"
        XCTAssertEqual(output.toolRuns.count, 1)
        XCTAssertEqual(output.toolRuns[0].isError, rejected)
        XCTAssertEqual(
          output.toolRuns[0].result.contains("fix instructions: parser.swift"),
          decision == "replace")
        XCTAssertEqual(
          output.toolRuns[0].result.contains("review instructions"), decision == "yolo")
        let messages = try XCTUnwrap(
          StubChatEndpoint.requests.last?["messages"] as? [[String: Any]])
        XCTAssertTrue(messages.contains { $0["tool_call_id"] as? String == "skill-call" })
        if !rejected {
          let expected = decision == "yolo" ? "review" : "fix"
          XCTAssertTrue(
            messages.contains {
              $0["role"] as? String == "system"
                && ($0["content"] as? String ?? "").contains(
                  "\(expected) instructions: parser.swift")
            })
        }
      }
    }
  }

  private func configureConversation(proxy: Bool) -> Conversation {
    let endpoint = OpenAIEndpoint(
      name: "Stub", baseURL: "https://\(StubChatEndpoint.host)/v1",
      apiKey: "stub", defaultModel: "stub", isEnabled: true)
    store.settings.openAIEndpoints = [endpoint]
    store.settings.toolCallingMode = .native
    store.settings.toolApprovalMode = .yolo
    store.settings.skillApprovalMode = .ask
    store.settings.useToolProxy = proxy
    store.settings.enabledSkillTools = Set(skills.map(\.toolName))
    var conversation = Conversation()
    conversation.provider = .openAICompatible
    conversation.endpointID = endpoint.id
    conversation.modelID = "stub"
    conversation.usesStreaming = false
    conversation.enabledTools = []
    conversation.enabledMCPServers = []
    conversation.messages = [ChatMessage(role: .user, text: "Review parser.swift")]
    return conversation
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !condition() {
      guard Date() < deadline else {
        throw NSError(
          domain: "SkillToolsTests", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the skill approval flow"])
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
