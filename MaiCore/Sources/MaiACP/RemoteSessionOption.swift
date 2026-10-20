import Foundation
import MaiCore

/// ACP session config options, also used to present OpenCode's native settings.
public struct RemoteSessionOption: Identifiable, Equatable, Sendable {
  public struct Choice: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var group: String?

    public init(_ id: String, _ name: String, group: String? = nil) {
      self.id = id
      self.name = name
      self.group = group
    }
  }

  public var id: String
  public var name: String
  public var category: String?
  public var description: String?
  public var currentValue: JSONValue
  public var choices: [Choice]
  public var isBoolean: Bool { currentValue.boolValue != nil }

  public init(
    id: String, name: String, category: String? = nil, description: String? = nil,
    currentValue: JSONValue,
    choices: [Choice] = []
  ) {
    self.id = id
    self.name = name
    self.category = category
    self.description = description
    self.currentValue = currentValue
    self.choices = choices
  }

  public func accepts(_ value: JSONValue) -> Bool {
    isBoolean ? value.boolValue != nil : choices.contains { value == .string($0.id) }
  }

  public static func parse(_ value: JSONValue?) -> [Self] {
    var ids = Set<String>()
    return (value?.arrayValue ?? []).compactMap { value in
      guard let object = value.objectValue, let id = object["id"]?.stringValue,
        let name = object["name"]?.stringValue, let current = object["currentValue"],
        let type = object["type"]?.stringValue,
        (type == "select" && current.stringValue != nil)
          || (type == "boolean" && current.boolValue != nil), ids.insert(id).inserted
      else { return nil }
      var choices: [Choice] = []
      var values = Set<String>()
      for entry in object["options"]?.arrayValue ?? [] {
        let group = entry.objectValue?["options"]?.arrayValue
        for choice in group ?? [entry] {
          guard let fields = choice.objectValue, let value = fields["value"]?.stringValue,
            let name = fields["name"]?.stringValue, values.insert(value).inserted
          else { continue }
          choices.append(
            .init(value, name, group: group == nil ? nil : entry.objectValue?["name"]?.stringValue))
        }
      }
      return Self(
        id: id, name: name, category: object["category"]?.stringValue,
        description: object["description"]?.stringValue,
        currentValue: current, choices: choices)
    }
  }

  public var json: JSONValue {
    var result: [String: JSONValue] = [
      "id": .string(id), "name": .string(name),
      "type": .string(isBoolean ? "boolean" : "select"), "currentValue": currentValue,
    ]
    if let category { result["category"] = .string(category) }
    if let description { result["description"] = .string(description) }
    if !isBoolean {
      result["options"] = .array(
        choices.map {
          .object(["value": .string($0.id), "name": .string($0.name)])
        })
    }
    return .object(result)
  }
}
