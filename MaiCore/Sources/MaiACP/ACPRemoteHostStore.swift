import Foundation
import MaiCore

/// Portable host bookmarks. Credentials are separate private files, so the
/// ordinary agent configuration contains only a token-file reference.
public struct ACPRemoteHost: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var url: URL
  public var cwd: String
  public var providerID: String { "remote." + id.uuidString.lowercased() }
}

public struct ACPRemoteHostStore: Sendable {
  public let directory: URL
  public init(directory: URL) { self.directory = directory }
  private var index: URL { directory.appendingPathComponent("hosts.json") }

  public func hosts() throws -> [ACPRemoteHost] {
    guard FileManager.default.fileExists(atPath: index.path) else { return [] }
    return try JSONDecoder().decode([ACPRemoteHost].self, from: Data(contentsOf: index))
  }

  public func host(_ name: String) throws -> ACPRemoteHost {
    let matches = try hosts().filter {
      $0.name.caseInsensitiveCompare(name) == .orderedSame
        || $0.id.uuidString.caseInsensitiveCompare(name) == .orderedSame
    }
    guard matches.count == 1, let host = matches.first else {
      throw JSONRPCError.invalidParams(
        "Unknown remote host '\(name)'. /remote list shows paired hosts.")
    }
    return host
  }

  public func tokenFile(for host: ACPRemoteHost) -> URL {
    directory.appendingPathComponent(host.id.uuidString.lowercased() + ".token")
  }

  public func sessionFile(for host: ACPRemoteHost) -> URL {
    directory.appendingPathComponent(host.id.uuidString.lowercased() + ".sessions.json")
  }

  @discardableResult
  public func pair(_ profile: ACPRemoteConnection, name: String? = nil) throws -> ACPRemoteHost {
    try profile.validate()
    let name = (name ?? profile.name).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty,
      !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw JSONRPCError.invalidParams("Enter a host name without control characters")
    }
    try ACPStateFiles.createDirectory(directory)
    let lock = try ACPFileLock(url: directory.appendingPathComponent("hosts.lock"), wait: true)
    defer { withExtendedLifetime(lock) {} }
    var hosts = try hosts()
    let existing = hosts.firstIndex { $0.url == profile.url }
    guard
      !hosts.contains(where: {
        $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.url != profile.url
      })
    else {
      throw JSONRPCError.invalidParams(
        "A different host is already named '\(name)'. Supply another name after the profile.")
    }
    let host = ACPRemoteHost(
      id: existing.map { hosts[$0].id } ?? UUID(), name: name,
      url: profile.url, cwd: profile.cwd)
    try Data(profile.token.utf8).write(to: tokenFile(for: host), options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: tokenFile(for: host).path)
    if let existing { hosts[existing] = host } else { hosts.append(host) }
    try ACPStateFiles.write(hosts, to: index)
    return host
  }

  public func provider(for host: ACPRemoteHost) -> ConfiguredProvider {
    .init(
      id: host.providerID, kind: "acp", displayName: host.name,
      options: [
        "url": .string(host.url.absoluteString), "remoteCwd": .string(host.cwd),
        "tokenFile": .string(tokenFile(for: host).path),
        "sessionFile": .string(sessionFile(for: host).path),
        "permission": .string("reject"), "readClientFiles": .bool(false),
      ])
  }
}
