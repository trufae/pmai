import Foundation

/// Saved, host-owned permissions for Files and vdb tools.
public struct ConfiguredFileAccess: Codable, Equatable, Sendable {
  public enum Access: String, Codable, Sendable {
    case allow, ask, deny
  }

  public struct Rule: Codable, Equatable, Sendable {
    public var path: String
    public var access: Access
    public var descendants: Bool

    public init(path: String, access: Access, descendants: Bool = true) {
      self.path = path
      self.access = access
      self.descendants = descendants
    }
  }

  /// nil retains normal tool approval for explicit external prompt paths.
  public var outside: Access?
  public var hidden: Access
  public var rules: [Rule]

  public static let defaultRules: [Rule] = [
    .init(path: "/etc", access: .ask),
    .init(path: "~/.ssh", access: .ask),
    .init(path: "~/.config", access: .ask),
  ]

  public init(
    outside: Access? = nil, hidden: Access = .ask,
    rules: [Rule] = ConfiguredFileAccess.defaultRules
  ) {
    self.outside = outside
    self.hidden = hidden
    self.rules = rules
  }

  private enum CodingKeys: String, CodingKey { case outside, hidden, rules }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      outside: try container.decodeIfPresent(Access.self, forKey: .outside),
      hidden: try container.decodeIfPresent(Access.self, forKey: .hidden) ?? .ask,
      rules: try container.decodeIfPresent([Rule].self, forKey: .rules) ?? Self.defaultRules)
  }
}
