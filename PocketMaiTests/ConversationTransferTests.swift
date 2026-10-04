import Foundation
import MaiCore
import MaiDocuments
import XCTest

@testable import PocketMai

final class ConversationTransferTests: XCTestCase {
  func testDocumentExportsFilterTechnicalRowsAndKeepVisibleText() {
    var chat = Conversation()
    chat.messages = [
      ChatMessage(role: .user, text: "Question"),
      ChatMessage(role: .assistant, text: "<think>Thinking only</think>"),
      ChatMessage(role: .assistant, text: "<think>Mixed thought</think>\n\nAnswer"),
      ChatMessage(role: .tool, text: "Plain tool result"),
      ChatMessage(role: .tool, text: "<tool_run>Tool result</tool_run>"),
      ChatMessage(role: .assistant, text: "<tool_call>Tool call</tool_call>"),
    ]
    chat.showThinking = true
    let clean = ConversationExportContent.exportDocument(conversation: chat)
    XCTAssertEqual(clean.entries.map(\.body), ["Question", "Answer"])
    XCTAssertTrue(clean.entries.allSatisfy { $0.reasoning.isEmpty })
    XCTAssertEqual(clean.summary.messageCount, "2 messages")

    for tools in [false, true] {
      for thinking in [false, true] {
        let document = ConversationExportContent.exportDocument(
          conversation: chat, options: .init(includeToolCalls: tools, includeThinking: thinking))
        let markdown = MarkdownExport.text(for: document)
        XCTAssertTrue(markdown.contains("Answer"))
        XCTAssertEqual(markdown.contains("Thinking only"), thinking)
        XCTAssertEqual(markdown.contains("Mixed thought"), thinking)
        XCTAssertEqual(markdown.contains("Plain tool result"), tools)
        XCTAssertEqual(markdown.contains("Tool result"), tools)
        XCTAssertEqual(markdown.contains("Tool call"), tools)
      }
    }
  }

  func testDocumentExportSettingsDefaultOffForExistingSettingsAndRoundTrip() throws {
    var settings = try JSONDecoder().decode(AppSettings.self,
      from: Data(#"{"showThinkingByDefault":true}"#.utf8))
    XCTAssertFalse(settings.documentExport.includeToolCalls)
    XCTAssertFalse(settings.documentExport.includeThinking)
    settings.documentExport = .init(includeToolCalls: true, includeThinking: true)
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(restored.documentExport, settings.documentExport)
  }

  private func conversation(_ title: String, createdAt: TimeInterval) -> Conversation {
    let timestamp = Date(timeIntervalSince1970: createdAt)
    var conversation = Conversation()
    conversation.title = title
    conversation.createdAt = timestamp
    conversation.updatedAt = timestamp
    conversation.messages = [ChatMessage(role: .user, text: title, createdAt: timestamp)]
    return conversation
  }

  private func subagentRecord(
    pid: AgentPID,
    parent: AgentPID?,
    runID: UUID,
    parentRunID: UUID? = nil,
    text: String
  ) -> AgentProcessRecord {
    AgentProcessRecord(
      process: AgentProcessInfo(
        pid: pid,
        parent: parent,
        runID: runID,
        agentID: "helper",
        task: text,
        state: .completed,
        depth: parentRunID == nil ? 1 : 2,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        finishedAt: Date(timeIntervalSince1970: 1_700_000_001)),
      messages: [.user(text), .assistant("Done: \(text)")],
      parentRunID: parentRunID)
  }

  func testConversationExportsUsePocketMaiJSONSuffix() {
    XCTAssertEqual(ConversationExportFormat.json.fileExtension, "pocketmai.json")
    XCTAssertEqual(ConversationExportFormat.debug.fileExtension, "json")
    XCTAssertTrue(
      ConversationExportFiles.isConversationExport(filename: "Two Chats.POCKETMAI.JSON"))
    XCTAssertFalse(ConversationExportFiles.isConversationExport(filename: "ordinary.json"))
  }

  func testSingleConversationEnvelopeRemainsCompatible() throws {
    let original = conversation("Legacy chat", createdAt: 1_700_000_000)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let encoded = try encoder.encode(
      ConversationExportEnvelope(
        conversation: original,
        exportedAt: Date(timeIntervalSince1970: 1_700_000_100),
        pocketMaiVersion: "1.7.4"))
    let portable = try MaiArchive.decode(from: encoded)

    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "conversations")
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ConversationExportEnvelope.self, from: legacyData)

    XCTAssertEqual(decoded.conversation, original)
    XCTAssertEqual(decoded.exportedConversations, [original])
    XCTAssertEqual(portable.chats?.first?.id, original.id)
    XCTAssertEqual(portable.chats?.first?.messages.last?.text, original.messages.last?.text)
  }

  func testPackedEnvelopeKeepsLegacyConversationAndAllConversations() throws {
    let first = conversation("First", createdAt: 1_700_000_200)
    let second = conversation("Second", createdAt: 1_700_000_100)
    let envelope = ConversationExportEnvelope(
      conversations: [first, second],
      exportedAt: Date(timeIntervalSince1970: 1_700_000_300),
      pocketMaiVersion: "1.7.4")

    XCTAssertEqual(envelope.conversation, first)
    XCTAssertEqual(envelope.exportedConversations, [first, second])
    XCTAssertEqual(envelope.createdAt, second.createdAt)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(envelope)
    let portable = try MaiArchive.decode(from: data)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ConversationExportEnvelope.self, from: data)

    XCTAssertEqual(decoded.conversation, first)
    XCTAssertEqual(decoded.exportedConversations, [first, second])
    XCTAssertEqual(portable.chats?.map(\.id), [first.id, second.id])
  }

  func testConversationEnvelopeEmbedsPortableChatWithoutChangingLegacyPayload() throws {
    struct LegacyEnvelope: Decodable {
      var format: String
      var conversation: Conversation
    }

    let original = conversation("Shared chat", createdAt: 1_700_000_400)
    var envelope = ConversationExportEnvelope(
      conversation: original,
      exportedAt: Date(timeIntervalSince1970: 1_700_000_500),
      pocketMaiVersion: "1.7.4")
    envelope.portable = MaiArchive(
      generator: "PocketMai tests",
      chats: [AgentChat(pocketMai: original, settings: AppSettings())])

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(envelope)
    let portable = try MaiArchive.decode(from: data)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let legacy = try decoder.decode(LegacyEnvelope.self, from: data)

    XCTAssertEqual(envelope.conversation, original)
    XCTAssertEqual(legacy.format, ConversationExportEnvelope.format)
    XCTAssertEqual(legacy.conversation, original)
    XCTAssertEqual(portable.chats?.first?.id, original.id)
    XCTAssertEqual(portable.chats?.first?.title, original.title)
  }

  func testPortableConversationKeepsEveryReasoningLevel() {
    let settings = AppSettings()
    for level in ReasoningLevel.allCases {
      var original = conversation("Reasoning", createdAt: 1_700_000_400)
      original.reasoningLevel = level
      let portable = AgentChat(pocketMai: original, settings: settings)
      XCTAssertEqual(portable.primaryAgent.options.reasoningEffort, level.optionValue)
      XCTAssertEqual(Conversation(archive: portable, settings: settings).reasoningLevel, level)
    }
    var legacy = AgentChat(pocketMai: conversation("Legacy", createdAt: 1_700_000_400), settings: settings)
    legacy.primaryAgent.options.reasoningEffort = "none"
    XCTAssertEqual(Conversation(archive: legacy, settings: settings).reasoningLevel, .disabled)
  }

  func testPortableConversationRoundTripKeepsNestedSubagentChats() throws {
    let childRunID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    var original = conversation("Delegated chat", createdAt: 1_700_000_400)
    original.subagents = [
      subagentRecord(
        pid: 2, parent: 1, runID: childRunID, text: "Research the question"),
      subagentRecord(
        pid: 3, parent: 2, runID: UUID(), parentRunID: childRunID,
        text: "Read the source"),
    ]

    let settings = AppSettings()
    let portable = AgentChat(pocketMai: original, settings: settings)
    XCTAssertEqual(portable.subagents, original.subagents)
    XCTAssertEqual(portable.subagents[1].parentRunID, childRunID)
    XCTAssertEqual(portable.subagents[0].messages.last?.text, "Done: Research the question")

    let restored = Conversation(archive: portable, settings: settings)
    XCTAssertEqual(restored.subagents, original.subagents)

    let legacyEnvelope = ConversationExportEnvelope(conversation: original)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let legacyDecoded = try MaiArchive.decode(from: encoder.encode(legacyEnvelope))
    XCTAssertEqual(legacyDecoded.chats?.first?.subagents, original.subagents)

    var envelope = legacyEnvelope
    envelope.portable = MaiArchive(generator: "PocketMai tests", chats: [portable])
    let decoded = try MaiArchive.decode(from: encoder.encode(envelope))
    XCTAssertEqual(decoded.chats?.first?.subagents, original.subagents)
  }

  func testStructuredAgentTranscriptUsesRegularReasoningAndToolRows() throws {
    let call = ToolCall(
      id: "call-1",
      name: "github_search",
      arguments: .object(["query": .string("radare2")]))
    let messages = [
      AgentMessage(
        id: "11111111-1111-1111-1111-111111111111",
        role: .assistant,
        content: [.reasoning("Find the repository."), .toolCall(call)]),
      AgentMessage(
        id: "22222222-2222-2222-2222-222222222222",
        role: .tool,
        content: [.toolResult(ToolResult(callID: call.id, text: "Found trufae/radare2"))]),
      AgentMessage(
        id: "33333333-3333-3333-3333-333333333333",
        role: .assistant,
        content: [.text("Done.")]),
    ]

    let rendered = ChatMessage.conversationMessages(from: messages)

    XCTAssertEqual(rendered.map(\.role), [.assistant, .tool, .assistant])
    XCTAssertEqual(
      MessageContentFilter.render(rendered[0].text).hiddenSections.map(\.tag), ["think"])
    let toolSection = try XCTUnwrap(
      MessageContentFilter.render(rendered[1].text).hiddenSections.first)
    let toolRow = try XCTUnwrap(ToolCallParser.parse(toolSection.content).first)
    XCTAssertEqual(toolRow.name, call.name)
    XCTAssertEqual(toolRow.params, #"{"query":"radare2"}"#)
    XCTAssertEqual(toolRow.body, "Found trufae/radare2")
    XCTAssertEqual(rendered[2].text, "Done.")
  }

  func testPortableProviderAndMCPAdaptersPreserveSharedSettings() throws {
    let expiry = Date(timeIntervalSince1970: 1_700_000_600)
    let endpoint = OpenAIEndpoint(
      name: "Remote",
      baseURL: "https://models.example/v1",
      apiKey: "token",
      defaultModel: "example-model",
      defaultReasoningLevel: .high,
      authMethod: .oauth,
      oauthClientID: "client",
      oauthRefreshToken: "refresh",
      oauthAccessTokenExpiresAt: expiry,
      headers: ["X-Test": "yes"])
    let restoredEndpoint = try XCTUnwrap(OpenAIEndpoint(archive: ConfiguredProvider(pocketMai: endpoint)))
    XCTAssertEqual(restoredEndpoint, endpoint)

    let namedProvider = ConfiguredProvider(
      id: "openrouter", kind: .openAICompatible, displayName: "OpenRouter",
      baseURL: URL(string: "https://openrouter.ai/api/v1"))
    let namedEndpoint = try XCTUnwrap(OpenAIEndpoint(archive: namedProvider))
    XCTAssertEqual(namedEndpoint.portableID, "openrouter")
    XCTAssertEqual(ConfiguredProvider(pocketMai: namedEndpoint).id, "openrouter")

    var authentication = MCPAuthentication()
    authentication.method = .oauth
    authentication.oauthAccessToken = "access"
    authentication.oauthRefreshToken = "refresh"
    authentication.oauthAccessTokenExpiresAt = expiry
    authentication.oauthClientID = "client"
    let server = MCPServer(
      name: "Tools", baseURL: "https://mcp.example", isEnabled: false,
      transport: .streamableHTTP, authentication: authentication)
    let restoredServer = try XCTUnwrap(MCPServer(archive: ConfiguredMCPServer(pocketMai: server)))
    XCTAssertEqual(restoredServer, server)

    let namedMCP = ConfiguredMCPServer(
      id: "search", enabled: true, url: URL(string: "https://mcp.example/search"))
    let namedServer = try XCTUnwrap(MCPServer(archive: namedMCP))
    XCTAssertEqual(namedServer.portableID, "search")
    XCTAssertEqual(ConfiguredMCPServer(pocketMai: namedServer).id, "search")
  }
}
