import Foundation
import MaiACP
import MaiCore
import MaiStandardTools

/// Owns a dedicated CLI profile, so stopping pmai never stops another app's tunnel.
/// The identity is retained across runs to keep the public address stable.
struct RemoteOpenTunnel: Sendable {
  let command: String
  let profile: String
  let directory: URL

  init(directory: URL) throws {
    guard let command = try? LocalExecutable.resolve("opentunnel") else {
      throw JSONRPCError.invalidParams(
        "OpenTunnel is not installed. Install it with brew install anomalyco/tap/opentunnel or cargo install opentunnel-cli, or supply --url wss://HOST/acp for an existing tunnel.")
    }
    self.command = command
    self.directory = directory
    let file = directory.appendingPathComponent("opentunnel-profile.json")
    if FileManager.default.fileExists(atPath: file.path) {
      profile = try JSONDecoder().decode(String.self, from: Data(contentsOf: file))
    } else {
      profile = "pmai-" + UUID().uuidString.lowercased()
      try ACPStateFiles.write(profile, to: file)
    }
    guard profile.hasPrefix("pmai-"), profile.count <= 63,
      profile.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
    else { throw JSONRPCError.invalidParams("Invalid pmai OpenTunnel profile") }
  }

  func start(port: Int) async throws -> URL {
    let output = try await run(["route", "add", "127.0.0.1:\(port)", "--name", "pmai"])
    guard let address = output.split(whereSeparator: \.isNewline).last(where: {
      $0.hasPrefix("https://")
    }), var url = URLComponents(string: String(address)), url.scheme == "https",
      url.host?.isEmpty == false, url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/"
    else { throw JSONRPCError.invalidParams("OpenTunnel did not return a public HTTPS URL") }
    url.scheme = "wss"
    url.path = "/acp"
    guard let gateway = url.url else { throw JSONRPCError.invalidParams("Invalid OpenTunnel URL") }
    // route add starts the service before its bridge necessarily attaches.
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
      let status = try await run(["status"], timeout: 5)
      if status.split(whereSeparator: \.isNewline).contains(where: {
        $0.hasPrefix("Service: connected")
      }) { return gateway }
      try await Task.sleep(for: .milliseconds(500))
    }
    throw JSONRPCError.invalidParams("OpenTunnel did not connect within 30 seconds")
  }

  func stop() async throws {
    // Cleanup must also run when serving was interrupted during provisioning.
    _ = try await Task.detached { try await run(["down"], timeout: 10) }.value
  }

  private func run(_ arguments: [String], timeout: Int = 180) async throws -> String {
    let result = try await CapturedProcess.run(
      command, arguments: ["--profile", profile] + arguments, directory: directory,
      timeout: TimeInterval(timeout), outputLimit: 64 * 1024)
    return String(decoding: result.stdout + result.stderr, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
