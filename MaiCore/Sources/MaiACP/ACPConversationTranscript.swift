import Foundation
import MaiCore

/// A cached, presentation-independent message received over ACP. Local IDs stay
/// stable when a host replaces streamed chunks with its authoritative snapshot.
public struct ACPConversationMessage: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var role: String
  public var text: String
  public var toolID: String?
  public var status: String?
  public var toolName: String?
  public var toolInput: JSONValue?
  public var createdAt: Date?
  public var remoteID: String?

  public init(
    id: UUID = UUID(), role: String, text: String, toolID: String? = nil,
    status: String? = nil, toolName: String? = nil, toolInput: JSONValue? = nil,
    createdAt: Date? = Date(), remoteID: String? = nil
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.toolID = toolID
    self.status = status
    self.toolName = toolName
    self.toolInput = toolInput
    self.createdAt = createdAt
    self.remoteID = remoteID
  }

  private enum CodingKeys: String, CodingKey {
    case id, role, text, toolID, status, toolName, toolInput, createdAt, remoteID
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    // Early mobile caches used host message IDs as local IDs.
    id = try values.decodeIfPresent(String.self, forKey: .id).flatMap(UUID.init(uuidString:)) ?? UUID()
    role = try values.decode(String.self, forKey: .role)
    text = try values.decode(String.self, forKey: .text)
    toolID = try values.decodeIfPresent(String.self, forKey: .toolID)
    status = try values.decodeIfPresent(String.self, forKey: .status)
    toolName = try values.decodeIfPresent(String.self, forKey: .toolName)
    toolInput = try values.decodeIfPresent(JSONValue.self, forKey: .toolInput)
    createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt)
    remoteID = try values.decodeIfPresent(String.self, forKey: .remoteID)
  }
}

public enum ACPConversationTranscript {
  /// Reduces standard ACP transcript events and pmai snapshots. Connection state,
  /// permissions, persistence, and rendering belong to the caller.
  public static func apply(_ update: JSONValue, to messages: inout [ACPConversationMessage]) {
    guard let object = update.objectValue, let kind = object["sessionUpdate"]?.stringValue else { return }
    switch kind {
    case "_pmai/message_snapshot":
      let previous = Dictionary(messages.compactMap { message in
        message.remoteID.map { ($0, message.id) }
      }, uniquingKeysWith: { first, _ in first })
      let tools = Dictionary(messages.compactMap { message in
        message.toolID.map { ($0, message.id) }
      }, uniquingKeysWith: { first, _ in first })
      messages = (object["messages"]?.arrayValue ?? []).compactMap { value in
        guard let fields = value.objectValue, let remoteID = fields["remoteID"]?.stringValue,
          let role = fields["role"]?.stringValue, let text = fields["text"]?.stringValue else { return nil }
        return ACPConversationMessage(
          id: previous[remoteID] ?? fields["toolID"]?.stringValue.flatMap { tools[$0] } ?? UUID(),
          role: role, text: text,
          toolID: fields["toolID"]?.stringValue, status: fields["status"]?.stringValue,
          toolName: fields["toolName"]?.stringValue, toolInput: fields["toolInput"],
          createdAt: fields["created"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) },
          remoteID: remoteID)
      }
    case "user_message_chunk", "agent_message_chunk", "agent_thought_chunk":
      let role = kind == "user_message_chunk" ? "user" : kind == "agent_message_chunk" ? "assistant" : "thought"
      let text = ACP.ContentBlock.text(from: object["content"])
      guard !text.isEmpty else { return }
      if role == "user", let id = object["messageId"]?.stringValue {
        if !messages.contains(where: { $0.remoteID == id }) {
          messages.append(.init(role: role, text: text, remoteID: id))
        }
        return
      }
      if let last = messages.indices.last, messages[last].role == role {
        messages[last].text += text
      } else { messages.append(.init(role: role, text: text)) }
    case "tool_call", "tool_call_update":
      guard let id = object["toolCallId"]?.stringValue else { return }
      let content = ACP.ContentBlock.text(from: object["content"])
      if let index = messages.firstIndex(where: { $0.toolID == id }) {
        if !content.isEmpty { messages[index].text += "\n" + content }
        if let status = object["status"]?.stringValue { messages[index].status = status }
        if let name = object["name"]?.stringValue ?? object["title"]?.stringValue {
          messages[index].toolName = name
        }
        if let input = object["rawInput"] { messages[index].toolInput = input }
      } else {
        messages.append(.init(role: "tool",
          text: [object["title"]?.stringValue ?? "Tool", content].filter { !$0.isEmpty }.joined(separator: "\n"),
          toolID: id, status: object["status"]?.stringValue,
          toolName: object["name"]?.stringValue ?? object["title"]?.stringValue,
          toolInput: object["rawInput"]))
      }
    case "plan":
      let text = (object["entries"]?.arrayValue ?? []).compactMap {
        $0.objectValue?["content"]?.stringValue
      }.joined(separator: "\n")
      if !text.isEmpty { messages.append(.init(role: "plan", text: text)) }
    default: break
    }
  }
}
