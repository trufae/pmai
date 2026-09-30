import Foundation
import MaiCore
import XCTest

@testable import PocketMai

/// Agents are named snapshots of the agent-scoped settings. The live fields on
/// `AppSettings` always belong to the selected agent; switching stores them on
/// the agent being left and loads the one being entered.
final class AgentProfileTests: XCTestCase {
  private let endpointID = UUID()
  private let promptID = UUID()
  private let mcpServerID = UUID()

  /// Every agent-scoped field set away from its default, so a field missing
  /// from either side of the snapshot shows up as a mismatch.
  private func customAgentSettings() -> AgentSettings {
    var custom = AgentSettings()
    custom.defaultProvider = .openAICompatible
    custom.appleModelID = "apple-model"
    custom.localMLXModelID = "local/model"
    custom.selectedEndpointID = endpointID
    custom.openAIModelID = "agent-specific-model"
    custom.defaultReasoningLevel = ReasoningLevel.allCases.last ?? .automatic
    custom.streamByDefault = false
    custom.showThinkingByDefault = true
    custom.defaultSystemPromptID = promptID
    custom.defaultEnabledTools = Set(BuiltInToolID.allCases.prefix(2))
    custom.defaultEnabledMCPServers = [mcpServerID]
    custom.defaultEnabledMCPTools = ["server:tool"]
    custom.mcpRequestTimeoutSeconds = 45
    custom.llmRequestTimeoutSeconds = 180
    custom.toolCallingMode = ToolCallingMode.allCases.first { $0 != .text } ?? .text
    custom.maxToolCallsPerTurn = 3
    custom.toolApprovalMode = .ask
    custom.useToolProxy = true
    custom.useSystemOne = true
    custom.contextWindowMode = ContextWindowMode.allCases.first { $0 != .full } ?? .full
    custom.includeAssistantResponsesInContext = false
    custom.includeReasoningContentInContext = true
    custom.mlxMaxKVSize = MLXKVCacheSize.allCases.first { $0 != .auto } ?? .auto
    custom.mlxAutoCompact = true
    XCTAssertNotEqual(custom, AgentSettings())
    return custom
  }

  func testSystemOneDefaultsAndProviderRoundTrip() throws {
    XCTAssertFalse(try JSONDecoder().decode(AgentSettings.self, from: Data("{}".utf8)).useSystemOne)
    XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).useSystemOne)
    let endpoint = OpenAIEndpoint(
      name: "Decisions", baseURL: "http://localhost:11434",
      defaultModel: "tev1", kind: .systemOne)
    let restored = try JSONDecoder().decode(
      OpenAIEndpoint.self, from: JSONEncoder().encode(endpoint))
    XCTAssertEqual(restored, endpoint)
    let portable = ConfiguredProvider(pocketMai: endpoint)
    XCTAssertEqual(portable.kind, .systemOne)
    XCTAssertEqual(OpenAIEndpoint(archive: portable)?.kind, .systemOne)
    var legacy = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(endpoint)) as? [String: Any])
    legacy.removeValue(forKey: "kind")
    let old = try JSONDecoder().decode(
      OpenAIEndpoint.self, from: JSONSerialization.data(withJSONObject: legacy))
    XCTAssertEqual(old.kind, .openAICompatible)
    XCTAssertNotEqual(old.connectionSignature, endpoint.connectionSignature)
  }

  func testApprovalModesMigrateAndOnlyEncodeTheNewSetting() throws {
    let decoder = JSONDecoder()
    for (json, expected) in [
      ("{}", ToolApprovalMode.yolo),
      (#"{"yoloModeEnabled":false}"#, .ask),
      (#"{"yoloModeEnabled":true}"#, .yolo),
      (#"{"yoloModeEnabled":true,"toolApprovalMode":"smart"}"#, .smart),
    ] {
      let data = Data(json.utf8)
      let agent = try decoder.decode(AgentSettings.self, from: data)
      let settings = try decoder.decode(AppSettings.self, from: data)
      XCTAssertEqual(agent.toolApprovalMode, expected)
      XCTAssertEqual(settings.toolApprovalMode, expected)
      XCTAssertEqual(settings.agents[0].settings.toolApprovalMode, expected)
      let encoded = try JSONEncoder().encode(settings)
      XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("yoloModeEnabled"))
      XCTAssertEqual(try decoder.decode(AppSettings.self, from: encoded).toolApprovalMode, expected)
    }
    let backup = try decoder.decode(
      SettingsToolsBackup.self,
      from: Data(#"{"toolSettings":{},"mcpServers":[],"yoloModeEnabled":false}"#.utf8))
    XCTAssertEqual(backup.toolApprovalMode, .ask)
    let encoded = try JSONEncoder().encode(backup)
    XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("yoloModeEnabled"))
    XCTAssertEqual(
      try decoder.decode(SettingsToolsBackup.self, from: encoded).toolApprovalMode, .ask)
  }

  func testDefaultsStartWithTheStockAgentSelected() {
    let settings = AppSettings.defaults
    XCTAssertEqual(settings.agents.map(\.id), [AgentProfile.stockID])
    XCTAssertEqual(settings.selectedAgentID, AgentProfile.stockID)
    XCTAssertEqual(settings.selectedAgent.name, AgentProfile.stockName)
    XCTAssertEqual(settings.agentSettings, AgentSettings())
    XCTAssertEqual(settings.agents[0].settings, AgentSettings())
  }

  func testToolCallLimitDefaultsAndBoundsApplyToEveryAgent() throws {
    XCTAssertEqual(AppSettings.defaultMaxToolCallsPerTurn, 50)
    XCTAssertEqual(AgentSettings().maxToolCallsPerTurn, 50)
    XCTAssertEqual(AppSettings().maxToolCallsPerTurn, 50)
    XCTAssertEqual(AppSettings.clampedMaxToolCallsPerTurn(0), 1)
    XCTAssertEqual(AppSettings.clampedMaxToolCallsPerTurn(100), 100)
    XCTAssertEqual(AppSettings.clampedMaxToolCallsPerTurn(101), 100)

    let decodedAgent = try JSONDecoder().decode(
      AgentSettings.self, from: Data(#"{"maxToolCallsPerTurn":101}"#.utf8))
    XCTAssertEqual(decodedAgent.maxToolCallsPerTurn, 100)

    let decodedSettings = try JSONDecoder().decode(
      AppSettings.self, from: Data(#"{"maxToolCallsPerTurn":101}"#.utf8))
    XCTAssertEqual(decodedSettings.maxToolCallsPerTurn, 100)
    XCTAssertEqual(decodedSettings.agents[0].settings.maxToolCallsPerTurn, 100)
  }

  func testAgentSettingsRoundTripThroughTheLiveFields() {
    var settings = AppSettings.defaults
    let custom = customAgentSettings()
    settings.agentSettings = custom
    XCTAssertEqual(settings.agentSettings, custom)
    XCTAssertEqual(settings.defaultProvider, .openAICompatible)
    XCTAssertEqual(settings.selectedEndpointID, endpointID)
    XCTAssertEqual(settings.defaultSystemPromptID, promptID)
    XCTAssertTrue(settings.useToolProxy)
  }

  func testSwitchingAgentsSwapsSettingsAndKeepsTheOnesLeftBehind() {
    var settings = AppSettings.defaults
    settings.agentSettings = customAgentSettings()
    let coder = settings.addAgent(named: "  Coder ")
    XCTAssertEqual(coder.name, "Coder")
    XCTAssertEqual(coder.settings, customAgentSettings(), "a new agent copies the selected one")

    XCTAssertTrue(settings.selectAgent(coder.id))
    settings.maxToolCallsPerTurn = 12
    settings.useToolProxy = false

    XCTAssertTrue(settings.selectAgent(AgentProfile.stockID))
    XCTAssertEqual(settings.agentSettings, customAgentSettings())
    XCTAssertEqual(settings.agents.first { $0.id == coder.id }?.settings.maxToolCallsPerTurn, 12)
    XCTAssertEqual(settings.agents.first { $0.id == coder.id }?.settings.useToolProxy, false)

    XCTAssertTrue(settings.selectAgent(coder.id))
    XCTAssertEqual(settings.maxToolCallsPerTurn, 12)
    XCTAssertFalse(settings.useToolProxy)
    XCTAssertFalse(settings.selectAgent(UUID()), "an unknown id changes nothing")
    XCTAssertEqual(settings.selectedAgentID, coder.id)
  }

  func testRemovingTheSelectedAgentFallsBackToStock() {
    var settings = AppSettings.defaults
    let stockSettings = customAgentSettings()
    settings.agentSettings = stockSettings
    let extra = settings.addAgent(named: "Extra")
    settings.selectAgent(extra.id)
    settings.toolApprovalMode = .yolo

    XCTAssertFalse(settings.removeAgent(AgentProfile.stockID), "the stock agent stays")
    XCTAssertTrue(settings.removeAgent(extra.id))
    XCTAssertEqual(settings.agents.map(\.id), [AgentProfile.stockID])
    XCTAssertEqual(settings.selectedAgentID, AgentProfile.stockID)
    XCTAssertEqual(settings.agentSettings, stockSettings)
    XCTAssertFalse(settings.removeAgent(extra.id), "removing twice is a no-op")
  }

  func testUpdatingAnAgentKeepsANameWhenTheNewOneIsBlank() {
    var settings = AppSettings.defaults
    let agent = settings.addAgent(named: "", description: " Finds papers ", canSpawnSubagents: true)
    XCTAssertEqual(agent.name, "Agent 2")
    XCTAssertEqual(agent.description, "Finds papers")
    XCTAssertTrue(agent.canSpawnSubagents)
    settings.updateAgent(
      agent.id, name: " Research ", description: "", canSpawnSubagents: false)
    XCTAssertEqual(settings.agents.last?.name, "Research")
    XCTAssertEqual(settings.agents.last?.description, "")
    XCTAssertEqual(settings.agents.last?.canSpawnSubagents, false)
    settings.updateAgent(agent.id, name: "   ", description: "Reads", canSpawnSubagents: true)
    XCTAssertEqual(settings.agents.last?.name, "Research")
    XCTAssertEqual(settings.agents.last?.description, "Reads")
    XCTAssertEqual(settings.agents.last?.canSpawnSubagents, true)
  }

  func testSettingsFromBeforeAgentsGetAStockAgentHoldingThem() throws {
    let legacy = """
      {"defaultProvider":"openAICompatible","selectedEndpointID":"\(endpointID.uuidString)","maxToolCallsPerTurn":5,"useToolProxy":true}
      """
    let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
    XCTAssertEqual(decoded.agents.map(\.id), [AgentProfile.stockID])
    XCTAssertEqual(decoded.selectedAgentID, AgentProfile.stockID)
    XCTAssertEqual(decoded.agents[0].name, AgentProfile.stockName)
    XCTAssertEqual(decoded.agents[0].settings.defaultProvider, .openAICompatible)
    XCTAssertEqual(decoded.agents[0].settings.selectedEndpointID, endpointID)
    XCTAssertEqual(decoded.agents[0].settings.maxToolCallsPerTurn, 5)
    XCTAssertTrue(decoded.agents[0].settings.useToolProxy)
  }

  func testAgentsSurviveEncodingAndStaleSelectionsAreRepaired() throws {
    var settings = AppSettings.defaults
    settings.agentSettings = customAgentSettings()
    let coder = settings.addAgent(
      named: "Coder", description: "Writes Swift", canSpawnSubagents: true)
    settings.selectAgent(coder.id)
    settings.maxToolCallsPerTurn = 9

    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    XCTAssertEqual(decoded.agents.map(\.name), [AgentProfile.stockName, "Coder"])
    XCTAssertEqual(decoded.agents[1].description, "Writes Swift")
    XCTAssertTrue(decoded.agents[1].canSpawnSubagents)
    XCTAssertEqual(decoded.agents[0].description, "")
    XCTAssertFalse(decoded.agents[0].canSpawnSubagents)
    XCTAssertEqual(decoded.selectedAgentID, coder.id)
    XCTAssertEqual(decoded.maxToolCallsPerTurn, 9)
    XCTAssertEqual(decoded.agents[1].settings.maxToolCallsPerTurn, 9)
    XCTAssertEqual(decoded.agents[0].settings, customAgentSettings())

    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["selectedAgentID"] = UUID().uuidString
    object["agents"] = [["id": coder.id.uuidString, "name": "", "settings": [String: Any]()]]
    let repaired = try JSONDecoder().decode(
      AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(repaired.selectedAgentID, AgentProfile.stockID)
    XCTAssertEqual(repaired.agents.map(\.name), [AgentProfile.stockName, "Agent 1"])
    XCTAssertEqual(
      repaired.agents[0].settings.maxToolCallsPerTurn, 9,
      "the stock agent is rebuilt from the live fields")
  }
  func testTaskAssignmentsAndIndependentRemoteModelsSurviveRestart() throws {
    var settings = AppSettings()
    settings.openAIEndpoints = [
      OpenAIEndpoint(
        id: endpointID, name: "Local", baseURL: "http://localhost:11434/v1",
        defaultModel: "provider-default")
    ]
    settings.agentSettings = customAgentSettings()
    let fast = settings.addAgent(named: "Fast")
    settings.selectAgent(fast.id)
    settings.openAIModelID = "small"
    settings.defaultReasoningLevel = .disabled
    settings.syncSelectedAgent()
    settings.selectAgent(AgentProfile.stockID)
    settings.taskAgents = .init(
      compact: fast.id.uuidString.lowercased(), tool: fast.id.uuidString.lowercased(),
      approval: fast.id.uuidString.lowercased())
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(restored.defaultProviderConfiguration.modelID, "agent-specific-model")
    XCTAssertEqual(restored.taskAgent(.tool)?.settings.openAIModelID, "small")
    XCTAssertEqual(restored.taskAgent(.approval)?.settings.openAIModelID, "small")
    XCTAssertEqual(restored.taskAgent(.compact)?.settings.defaultReasoningLevel, .disabled)
    XCTAssertEqual(restored.openAIEndpoints[0].defaultModel, "provider-default")
    var cleaned = restored
    cleaned.removeAgent(fast.id)
    XCTAssertEqual(cleaned.taskAgents, TaskAgentAssignments())
  }

  func testTaskRoutingPreservesConversationPermissionsAndMainModel() {
    var settings = AppSettings()
    settings.agentSettings = customAgentSettings()
    settings.openAIEndpoints = [
      OpenAIEndpoint(
        id: endpointID, name: "Local", baseURL: "http://localhost:11434/v1",
        defaultModel: "fallback")
    ]
    let fast = settings.addAgent(named: "Fast")
    settings.taskAgents.tool = fast.id.uuidString.lowercased()
    var conversation = Conversation()
    conversation.provider = .apple
    conversation.modelID = "primary"
    conversation.enabledTools = []
    conversation.enabledMCPServers = []
    conversation.reasoningLevel = .high
    conversation.messages = [ChatMessage(role: .user, text: "find it")]
    let routed = settings.taskConversation(.tool, from: conversation)
    XCTAssertEqual(routed.provider, .openAICompatible)
    XCTAssertEqual(routed.modelID, "agent-specific-model")
    XCTAssertEqual(routed.endpointID, endpointID)
    XCTAssertEqual(routed.enabledTools, [])
    XCTAssertEqual(routed.enabledMCPServers, [])
    XCTAssertEqual(routed.messages, conversation.messages)
    XCTAssertEqual(conversation.modelID, "primary")
    settings.taskAgents.tool = nil
    XCTAssertEqual(settings.taskConversation(.tool, from: conversation), conversation)
  }

  func testCompactionUsesAssignedAgentAndFallsBackToConversation() async throws {
    var settings = AppSettings()
    var conversation = Conversation()
    conversation.provider = .apple
    conversation.modelID = "primary"
    conversation.reasoningLevel = .high
    conversation.messages = [
      ChatMessage(role: .user, text: "Keep this path: /tmp/file"),
      ChatMessage(role: .assistant, text: "done"),
    ]
    let fallbackValue = await ConversationPromptBuilder.compactRequest(
      conversation: conversation, settings: settings)
    let fallback = try XCTUnwrap(fallbackValue)
    XCTAssertEqual(fallback.oneShot.modelID, "primary")
    XCTAssertEqual(fallback.oneShot.reasoningLevel, .high)
    settings.agentSettings = customAgentSettings()
    let compact = settings.addAgent(named: "Compact")
    settings.taskAgents.compact = compact.id.uuidString.lowercased()
    let requestValue = await ConversationPromptBuilder.compactRequest(
      conversation: conversation, settings: settings)
    let request = try XCTUnwrap(requestValue)
    XCTAssertEqual(request.oneShot.provider, .openAICompatible)
    XCTAssertEqual(request.oneShot.modelID, "agent-specific-model")
    XCTAssertEqual(request.oneShot.endpointID, endpointID)
    XCTAssertEqual(request.oneShot.systemPromptID, promptID)
    XCTAssertTrue(request.oneShot.prompt.contains("/tmp/file"))
  }

}
