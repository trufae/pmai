import Foundation
import MaiACP
import MaiACPGateway

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

enum ACPGatewayCLI {
  static func run(_ arguments: [String], environment: [String: String]) async throws {
    if arguments.contains("--help") || arguments.contains("-h") {
      print(
        """
        Usage: pmai acp-gateway [options] -- ACP_COMMAND [ARGS...]
          --host HOST          Listen address (default: 127.0.0.1)
          --port PORT          Listen port (default: 19283)
          --token-file PATH    Bearer token file (created with mode 0600 if missing)
          --cwd PATH           Absolute workspace on the agent host (required)
          --url URL            Phone-facing ws:// or wss:// URL, ending in /acp
          --name NAME          Connection name for the phone (default: pmai)
          --qr PATH            Also save the terminal QR as an image (requires --url)
          --profile PATH       Export a connection URI (requires --url)

        Example: pmai acp-gateway --cwd /work/project -- pmai --acp --acp-root /work/project
        Tailcat: pmai acp-gateway --cwd /remote/project -- pmai tailcat connect workstation
        Use WSS through a TLS reverse proxy, or WS on a trusted private network.
        Each authenticated connection starts one agent process. Tokens grant control
        of that agent. Replacing the token file revokes existing connections within 40s.
        """)
      return
    }
    let separator = arguments.firstIndex(of: "--") ?? arguments.endIndex
    var flags: [String: String] = [:]
    var index = 0
    let allowed: Set<String> = [
      "--host", "--port", "--token-file", "--cwd", "--url", "--name", "--qr", "--profile",
    ]
    while index < separator {
      let key = arguments[index]
      guard allowed.contains(key), index + 1 < separator, flags[key] == nil else {
        throw TailcatCLI.Error.message(
          "Invalid gateway option: \(key). Use pmai acp-gateway --help.")
      }
      flags[key] = arguments[index + 1]
      index += 2
    }
    guard separator < arguments.endIndex - 1,
      let cwd = flags["--cwd"], cwd.hasPrefix("/"),
      let port = Int(flags["--port"] ?? "19283"), (1...65535).contains(port)
    else {
      throw TailcatCLI.Error.message(
        "Provide --cwd /absolute/remote/workspace and -- ACP_COMMAND [ARGS...].")
    }
    let command = arguments[separator + 1]
    let commandArguments = Array(arguments.dropFirst(separator + 2))
    let home =
      environment["PMAI_HOME"]
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pmai").path
    let tokenFile = URL(
      fileURLWithPath: NSString(string: flags["--token-file"] ?? "\(home)/gateway/token")
        .expandingTildeInPath)
    let token = try loadToken(tokenFile)
    if let urlString = flags["--url"], let url = URL(string: urlString) {
      guard url.path == "/acp" else {
        throw TailcatCLI.Error.message("The gateway URL must end in /acp")
      }
      let profile = try ACPRemoteConnection(
        name: flags["--name"] ?? "pmai", url: url, token: token, cwd: cwd)
      let uri = try profile.uri()
      if let path = flags["--profile"] {
        let file = URL(fileURLWithPath: path)
        try Data((uri + "\n").utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      }
      print("Connection profile (contains the gateway credential):\n\(uri)")
      try TailcatQR.show(uri, output: flags["--qr"].map { URL(fileURLWithPath: $0) })
      fflush(stdout)
    } else if flags["--url"] != nil || flags["--qr"] != nil || flags["--profile"] != nil {
      throw TailcatCLI.Error.message(
        "QR/profile export requires a valid --url ws://host:port/acp or wss://host/acp")
    }
    let configuration = ACPWebSocketGateway.Configuration(
      host: flags["--host"] ?? "127.0.0.1",
      port: port, tokenFile: tokenFile, command: command, arguments: commandArguments,
      workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    let server = Task {
      try await ACPWebSocketGateway.serve(configuration) { address in
        FileHandle.standardError.write(
          Data("ACP WebSocket gateway listening at \(address)/acp\n".utf8))
      }
    }
    #if !os(Windows)
      let sources = [SIGINT, SIGTERM].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { server.cancel() }
        source.resume()
        return source
      }
      defer { for source in sources { source.cancel() } }
    #endif
    try await server.value
  }

  private static func loadToken(_ tokenFile: URL) throws -> String {
    try FileManager.default.createDirectory(
      at: tokenFile.deletingLastPathComponent(),
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let tokenLock = try ACPFileLock(url: tokenFile.appendingPathExtension("lock"), wait: true)
    defer { withExtendedLifetime(tokenLock) {} }
    if !FileManager.default.fileExists(atPath: tokenFile.path) {
      let token = UUID().uuidString + UUID().uuidString
      guard
        FileManager.default.createFile(
          atPath: tokenFile.path, contents: Data((token + "\n").utf8),
          attributes: [.posixPermissions: 0o600])
      else {
        throw TailcatCLI.Error.message("Cannot create gateway token file")
      }
    }
    let token = try String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard token.utf8.count >= 32, !token.contains(where: { $0.isWhitespace }) else {
      throw TailcatCLI.Error.message(
        "Gateway token must contain at least 32 characters without whitespace")
    }
    return token
  }
}
