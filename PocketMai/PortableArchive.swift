import Foundation
import MaiCore

// The interchange adapters stay at the host boundary. MaiCore owns the
// archive and its canonical models; PocketMai only translates the additional
// state its long-lived models carry.

extension ConfiguredProvider {
  init(pocketMai endpoint: OpenAIEndpoint) {
    var options: [String: JSONValue] = [
      "pocketmai.enabled": .bool(endpoint.isEnabled),
      "pocketmai.defaultModel": .string(endpoint.defaultModel),
      "pocketmai.reasoning": .string(endpoint.defaultReasoningLevel.rawValue),
      "pocketmai.authMethod": .string(endpoint.authMethod.rawValue),
    ]
    let strings = [
      "oauthIssuer": endpoint.oauthIssuer,
      "oauthClientID": endpoint.oauthClientID,
      "oauthAudience": endpoint.oauthAudience,
      "oauthScope": endpoint.oauthScope,
      "oauthRedirectURI": endpoint.oauthRedirectURI,
      "oauthRefreshToken": endpoint.oauthRefreshToken,
      "oauthAuthorizeURL": endpoint.oauthAuthorizeURL,
      "oauthTokenURL": endpoint.oauthTokenURL,
    ]
    for (key, value) in strings where !value.isEmpty {
      options["pocketmai.\(key)"] = .string(value)
    }
    if let expiry = endpoint.oauthAccessTokenExpiresAt {
      options["pocketmai.oauthAccessTokenExpiresAt"] = .string(
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(expiry))
    }
    self.init(
      id: endpoint.portableID ?? endpoint.id.uuidString.lowercased(),
      kind: endpoint.kind,
      displayName: endpoint.name,
      baseURL: URL(string: endpoint.baseURL),
      apiKey: endpoint.apiKey,
      headers: endpoint.headers,
      options: options)
  }
}

extension OpenAIEndpoint {
  init?(archive provider: ConfiguredProvider) {
    guard [.openAICompatible, .systemOne].contains(provider.kind), let baseURL = provider.baseURL
    else { return nil }
    let options = provider.options
    let portableIdentifier = UUID(uuidString: provider.id)
    let identifier = portableIdentifier ?? UUID()
    self.init(
      id: identifier,
      name: provider.displayName ?? provider.id,
      baseURL: baseURL.absoluteString,
      apiKey: provider.apiKey ?? "",
      defaultModel: options["pocketmai.defaultModel"]?.stringValue ?? "",
      defaultReasoningLevel: options["pocketmai.reasoning"]?.stringValue
        .flatMap(ReasoningLevel.init(rawValue:)) ?? .automatic,
      isEnabled: options["pocketmai.enabled"]?.boolValue ?? true,
      authMethod: options["pocketmai.authMethod"]?.stringValue
        .flatMap(EndpointAuthMethod.init(rawValue:)) ?? .apiKey,
      oauthIssuer: options.archiveString("oauthIssuer"),
      oauthClientID: options.archiveString("oauthClientID"),
      oauthAudience: options.archiveString("oauthAudience"),
      oauthScope: options.archiveString("oauthScope"),
      oauthRedirectURI: options.archiveString("oauthRedirectURI"),
      oauthRefreshToken: options.archiveString("oauthRefreshToken"),
      oauthAccessTokenExpiresAt: options.archiveDate("oauthAccessTokenExpiresAt"),
      oauthAuthorizeURL: options.archiveString("oauthAuthorizeURL"),
      oauthTokenURL: options.archiveString("oauthTokenURL"),
      headers: provider.headers,
      portableID: portableIdentifier == nil ? provider.id : nil, kind: provider.kind)
  }
}

extension ConfiguredMCPServer {
  init(pocketMai server: MCPServer) {
    var options: [String: JSONValue] = [
      "pocketmai.authMethod": .string(server.authentication.method.rawValue)
    ]
    let authentication = server.authentication
    let strings = [
      "oauthRefreshToken": authentication.oauthRefreshToken,
      "oauthClientID": authentication.oauthClientID,
    ]
    for (key, value) in strings where !value.isEmpty {
      options["pocketmai.\(key)"] = .string(value)
    }
    if let expiry = authentication.oauthAccessTokenExpiresAt {
      options["pocketmai.oauthAccessTokenExpiresAt"] = .string(
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(expiry))
    }
    self.init(
      id: server.portableID ?? server.id.uuidString.lowercased(),
      kind: "streamable-http",
      enabled: server.isEnabled,
      displayName: server.name,
      url: URL(string: server.baseURL),
      bearerToken: authentication.accessToken,
      options: options)
  }
}

extension MCPServer {
  init?(archive server: ConfiguredMCPServer) {
    guard server.command == nil, let url = server.url else { return nil }
    var authentication = MCPAuthentication()
    authentication.method = server.options["pocketmai.authMethod"]?.stringValue
      .flatMap(MCPAuthenticationMethod.init(rawValue:)) ?? (server.bearerToken == nil ? .none : .bearer)
    switch authentication.method {
    case .none:
      break
    case .bearer:
      authentication.bearerToken = server.bearerToken ?? ""
    case .oauth:
      authentication.oauthAccessToken = server.bearerToken ?? ""
      authentication.oauthRefreshToken = server.options.archiveString("oauthRefreshToken")
      authentication.oauthClientID = server.options.archiveString("oauthClientID")
      authentication.oauthAccessTokenExpiresAt = server.options.archiveDate(
        "oauthAccessTokenExpiresAt")
    }
    self.init(
      id: UUID(uuidString: server.id) ?? UUID(),
      name: server.displayName ?? server.id,
      baseURL: url.absoluteString,
      isEnabled: server.enabled,
      transport: .streamableHTTP,
      authentication: authentication,
      portableID: UUID(uuidString: server.id) == nil ? server.id : nil)
  }
}

extension ConfiguredPrompts {
  init(pocketMai settings: AppSettings) {
    self.init(
      compact: settings.compactPrompt,
      system: Dictionary(
        settings.systemPrompts.map { ($0.displayName, $0.text) },
        uniquingKeysWith: { _, last in last }),
      user: Dictionary(
        settings.userPrompts.map { ($0.displayName, $0.text) },
        uniquingKeysWith: { _, last in last }))
  }
}

extension AgentChat {
  init(pocketMai conversation: Conversation, settings: AppSettings) {
    let prompt = conversation.systemPromptID.flatMap { id in
      settings.systemPrompts.first { $0.id == id }
    }
    let provider: ProviderID =
      switch conversation.provider {
      case .apple: "apple"
      case .mlx: "mlx"
      case .openAICompatible:
        ProviderID(conversation.endpointID?.uuidString.lowercased() ?? "openai")
      }
    let strategy = ToolCallingStrategy(rawValue: settings.toolCallingMode.rawValue) ?? .automatic
    let agent = AgentDefinition(
      id: "pocketmai",
      displayName: "PocketMai",
      instructions: prompt?.text ?? "",
      systemPrompt: prompt?.displayName,
      provider: provider,
      model: conversation.modelID,
      toolNames: conversation.toolsEnabled ? Set(conversation.enabledTools.map(\.rawValue)) : [],
      stream: conversation.usesStreaming,
      options: GenerationOptions(reasoningEffort: conversation.reasoningLevel.optionValue),
      toolCallingStrategy: strategy)
    var messages = conversation.messages.map { AgentMessage(pocketMai: $0) }
    if let prompt, !prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      messages.first?.role != .system
    {
      messages.insert(.system(prompt.text), at: 0)
    }
    self.init(
      id: conversation.id,
      title: conversation.title,
      primaryAgent: agent,
      messages: messages,
      createdAt: conversation.createdAt,
      updatedAt: conversation.updatedAt,
      isArchived: conversation.isArchived,
      sessionID: conversation.sessionID,
      subagents: conversation.subagents)
  }
}

extension AgentMessage {
  init(pocketMai message: ChatMessage) {
    let role: AgentRole =
      switch message.role {
      case .user: .user
      case .assistant, .error: .assistant
      case .system: .system
      case .tool: .tool
      }
    var content: [ContentPart] = message.text.isEmpty ? [] : [.text(message.text)]
    for attachment in message.attachments {
      switch attachment.kind {
      case .textFile:
        content.append(
          .file(
            FileContent(
              name: attachment.filename,
              mimeType: attachment.mimeType,
              text: attachment.text)))
      case .image:
        guard let encoded = attachment.dataBase64, let data = Data(base64Encoded: encoded) else {
          continue
        }
        content.append(
          .image(
            ImageContent(
              source: .data(data),
              mimeType: attachment.mimeType,
              name: attachment.filename,
              width: attachment.width,
              height: attachment.height)))
      }
    }
    self.init(id: message.id.uuidString.lowercased(), role: role, content: content)
  }
}

extension Conversation {
  init(
    archive chat: AgentChat,
    settings: AppSettings,
    providers: [ConfiguredProvider] = []
  ) {
    self.init()
    id = chat.id
    title = chat.title
    messages = ChatMessage.conversationMessages(from: chat.messages)
    createdAt = chat.createdAt
    updatedAt = chat.updatedAt
    modelID = chat.primaryAgent.model
    usesStreaming = chat.primaryAgent.stream
    isArchived = chat.isArchived
    sessionID = chat.sessionID
    subagents = chat.subagents
    enabledTools = BuiltInToolID.knownTools(from: Array(chat.primaryAgent.toolNames))
    toolsEnabled = !enabledTools.isEmpty
    reasoningLevel = ReasoningLevel(
      name: chat.primaryAgent.options.reasoningEffort ?? "") ?? .automatic

    switch chat.primaryAgent.provider.rawValue {
    case "apple":
      provider = .apple
    case "mlx":
      provider = .mlx
    default:
      provider = .openAICompatible
      let configured = providers.first { $0.id == chat.primaryAgent.provider.rawValue }
      endpointID = UUID(uuidString: chat.primaryAgent.provider.rawValue)
        ?? settings.openAIEndpoints.first(where: {
          $0.name.caseInsensitiveCompare(chat.primaryAgent.provider.rawValue) == .orderedSame
        })?.id
        ?? configured.flatMap { provider in
          settings.openAIEndpoints.first {
            $0.baseURL == provider.baseURL?.absoluteString
              && $0.name.caseInsensitiveCompare(provider.displayName ?? provider.id) == .orderedSame
          }?.id
        }
        ?? settings.openAIEndpoints.first?.id
    }
    if let name = chat.primaryAgent.systemPrompt {
      systemPromptID = settings.systemPrompts.first {
        $0.displayName.caseInsensitiveCompare(name) == .orderedSame
      }?.id
    }
    if systemPromptID == nil, !chat.primaryAgent.instructions.isEmpty {
      systemPromptID = settings.systemPrompts.first {
        $0.text == chat.primaryAgent.instructions
      }?.id
    }
  }
}

extension ChatMessage {
  /// Adapts MaiCore's structured transcript to the tagged representation used
  /// by PocketMai's regular conversation renderer. Native calls and their
  /// results are paired so they appear as the same tool rows as calls made by
  /// the foreground chat.
  static func conversationMessages(from messages: [AgentMessage]) -> [ChatMessage] {
    let callsByID = Dictionary(
      messages.flatMap(\.toolCalls).map { ($0.id, $0) },
      uniquingKeysWith: { _, latest in latest })
    let completedCallIDs = Set(messages.flatMap(\.toolResults).map(\.callID))
    return messages.compactMap { message in
      let converted = ChatMessage(
        agentMessage: message,
        callsByID: callsByID,
        completedCallIDs: completedCallIDs)
      let hasText = !converted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      return hasText || !converted.attachments.isEmpty ? converted : nil
    }
  }

  private init(
    agentMessage message: AgentMessage,
    callsByID: [String: ToolCall],
    completedCallIDs: Set<String>
  ) {
    let role: ChatRole =
      switch message.role {
      case .user: .user
      case .assistant: .assistant
      case .system, .developer: .system
      case .tool: .tool
      }
    var text: [String] = []
    var attachments: [ChatAttachment] = []
    for part in message.content {
      switch part {
      case .text(let value):
        text.append(value)
      case .reasoning(let value):
        text.append("<think>\n\(value)\n</think>")
      case .file(let file):
        attachments.append(
          .textFile(filename: file.name, text: file.text ?? "", mimeType: file.mimeType))
      case .image(let image):
        if case .data(let data) = image.source {
          attachments.append(
            .image(
              filename: image.name ?? "image",
              data: data,
              mimeType: image.mimeType,
              width: image.width,
              height: image.height))
        } else if case .url(let url) = image.source {
          text.append("![\(image.name ?? "image")](\(url.absoluteString))")
        }
      case .audio(let audio):
        text.append("[Audio: \(audio.name ?? audio.mimeType)]")
      case .resource(let resource):
        if let value = resource.text { text.append(value) }
      case .toolCall(let call):
        if !completedCallIDs.contains(call.id) {
          text.append(
            AgentTooling.makeRunBlock(
              toolName: call.name,
              argumentsJSON: call.arguments.compactJSONString,
              result: ""))
        }
      case .toolResult(let result):
        let call = callsByID[result.callID]
        let output = result.text.isEmpty
          ? result.structuredContent?.compactJSONString ?? ""
          : result.text
        text.append(
          AgentTooling.makeRunBlock(
            toolName: call?.name ?? "tool",
            argumentsJSON: call?.arguments.compactJSONString
              ?? "{\"callID\":\"\(result.callID)\"}",
            result: output))
      }
    }
    self.init(
      id: UUID(uuidString: message.id) ?? UUID(),
      role: role,
      text: text.joined(separator: "\n\n"),
      attachments: attachments)
  }
}

extension Dictionary where Key == String, Value == JSONValue {
  fileprivate func archiveString(_ name: String) -> String {
    self["pocketmai.\(name)"]?.stringValue ?? ""
  }

  fileprivate func archiveDate(_ name: String) -> Date? {
    guard let value = self["pocketmai.\(name)"]?.stringValue else { return nil }
    return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)
  }
}
