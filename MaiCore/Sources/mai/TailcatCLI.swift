import Foundation
import MaiACP
import MaiCore
#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

enum TailcatCLI {
  enum Error: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
  }

  struct Options {
    var values: [String: String] = [:]
    var positional: [String] = []
    var agentArguments: [String] = []
    var help = false

    init(_ arguments: [String]) throws {
      var index = 0
      let flags: Set<String> = ["--home", "--tailcat", "--name", "--expires", "--qr", "--config", "--permission"]
      while index < arguments.count {
        let argument = arguments[index]
        if argument == "--" { agentArguments = Array(arguments.dropFirst(index + 1)); break }
        if argument == "--help" || argument == "-h" { help = true }
        else if flags.contains(argument) {
          index += 1
          guard index < arguments.count else { throw Error.message("Missing value for \(argument)") }
          values[argument] = arguments[index]
        } else if argument.hasPrefix("-") { throw Error.message("Unknown Tailcat option: \(argument)") }
        else { positional.append(argument) }
        index += 1
      }
    }
  }

  static let usage = """
    pmai tailcat serve [--name NAME] [--qr invite.png] -- [pmai options]
    pmai tailcat invite [--expires SECONDS] [--qr invite.png]
    pmai tailcat pair NAME URI_OR_FILE [--config PATH] [--permission auto|allow|reject]
    pmai tailcat connect NAME
    pmai tailcat status [NAME]
    pmai tailcat revoke PEER_ID

    Common options: --home DIR (or PMAI_HOME), --tailcat PATH (or PMAI_TAILCAT).
    serve uses the current project directory. Its first launch prints a pairing QR.
    invite replaces the previous token; invites expire after 300 seconds by default.
    pair installs a named ACP agent in the selected pmai config.
    connect is a raw ACP stdio proxy, intended for an ACP client, not a terminal.
    status shows the registry; status NAME checks a remote worker over ACP.
    revoke removes a controller's access, including active connections.
    See doc/tailcat.md for setup, permissions, session recovery, and limitations.
    """

  static func run(_ arguments: [String], executable: String, environment: [String: String]) async throws {
    let options = try Options(arguments)
    guard let command = options.positional.first, !options.help else { print(usage); return }
    let home = URL(fileURLWithPath: NSString(string:
      options.values["--home"] ?? environment["PMAI_HOME"] ?? "~/.pmai").expandingTildeInPath,
      isDirectory: true).standardizedFileURL
    let store = TailcatStore(directory: home.appendingPathComponent("tailcat", isDirectory: true))
    let args = Array(options.positional.dropFirst())
    let ownExecutable = resolveExecutable(executable) ?? executable
    let tailcatName = options.values["--tailcat"] ?? environment["PMAI_TAILCAT"] ?? "tailcat"
    // Registry administration remains available if Tailcat is not installed.
    if command == "invite" {
      guard args.isEmpty else { throw Error.message(usage) }
      try showInvite(store, options: options)
      return
    }
    if command == "revoke" {
      guard args.count == 1 else { throw Error.message(usage) }
      try store.revoke(args[0])
      print("Revoked \(args[0]). Active connections close within two seconds.")
      return
    }
    if command == "status", args.isEmpty {
      let state = try store.read()
      if let worker = state.worker {
        print("Worker: \(worker.name) (\(worker.id))\nWorkspace: \(worker.workspace)")
        for peer in worker.peers {
          print("  \(peer.id)  \(peer.name)  \(peer.revoked ? "revoked" : "paired")")
        }
      }
      for remote in state.remotes.values.sorted(by: { $0.name < $1.name }) {
        print("Remote: \(remote.name)  \(remote.workspace)  last seen: \(remote.lastSeen.map { ISO8601DateFormatter().string(from: $0) } ?? "never")")
      }
      return
    }
    guard let tailcat = resolveExecutable(tailcatName) else {
      throw Error.message("Tailcat is not installed. Install a release with serve exec and TAILCAT_PEER_KEY support, or pass --tailcat PATH.")
    }
    try ACPStateFiles.createDirectory(store.directory)
    switch command {
    case "serve":
      guard args.isEmpty else { throw Error.message(usage) }
      try await serve(store, home: home, tailcat: tailcat, executable: ownExecutable, options: options, environment: environment)
    case "pair":
      guard args.count == 2 else { throw Error.message(usage) }
      try await pair(args[0], value: args[1], store: store, home: home,
        tailcat: tailcat, executable: ownExecutable, options: options, environment: environment)
    case "connect", "status":
      guard args.count == 1, let remote = try store.read().remotes[args[0]] else {
        throw Error.message("Choose a remote from pmai tailcat status")
      }
      let key = try clientKey(store, tailcat: tailcat)
      let childArguments = ["--key=" + key.path, remote.address, "80"]
      if command == "connect" {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tailcat)
        process.arguments = childArguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        try await wait(process)
      } else {
        let transport = try StdioJSONRPCTransport.spawn(command: tailcat, arguments: childArguments)
        let peer = JSONRPCPeer(transport: transport)
        await peer.start()
        do {
          _ = try await peer.request(ACP.Method.initialize, params: .object(["protocolVersion": .integer(1)]), timeout: 15)
          let status = try await peer.request("_pmai/status", timeout: 15)
          guard status.objectValue?["workerID"]?.stringValue == remote.workerID else {
            throw Error.message("Remote worker identity differs from its pairing record")
          }
          try store.transaction { state in state.remotes[args[0]]?.lastSeen = Date() }
          print(status.compactJSONString)
          await peer.close()
        } catch { await peer.close(); throw error }
      }
    default: throw Error.message(usage)
    }
  }

  private static func serve(_ store: TailcatStore, home: URL, tailcat: String, executable: String,
    options: Options, environment: [String: String]) async throws {
    let lease = try ACPFileLock(url: store.directory.appendingPathComponent("serve.lock"))
    defer { withExtendedLifetime(lease) {} }
    let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let worker = try store.initializeWorker(
      name: options.values["--name"] ?? ProcessInfo.processInfo.hostName, workspace: workspace)
    let key = store.directory.appendingPathComponent("worker.private.json")
    if !FileManager.default.fileExists(atPath: key.path) {
      _ = try capture(tailcat, ["genkey", "--key=" + key.path, "--fixed-region"])
    }
    let addressFile = store.directory.appendingPathComponent("listen-address")
    try Data().write(to: addressFile, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: addressFile.path)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tailcat)
    process.arguments = ["serve", "--key=" + key.path, "exec", "--", executable]
      + options.agentArguments + ["--home", home.path, "--acp", "--tailcat-gateway", store.directory.path]
    var childEnvironment = environment
    childEnvironment["TAILCAT_ADDR_FILE"] = addressFile.path
    // Only Tailcat may supply these values to a gateway child.
    childEnvironment.removeValue(forKey: "TAILCAT_PEER_KEY")
    childEnvironment.removeValue(forKey: "TAILCAT_REMOTE_ADDR")
    process.environment = childEnvironment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.standardError
    process.standardError = FileHandle.standardError
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    var address: String?
    for _ in 0..<600 {
      if let value = try? String(contentsOf: addressFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
        TailcatInvite.validAddress(value) { address = value; break }
      guard process.isRunning else { throw Error.message("Tailcat exited before opening the worker") }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard let address else { throw Error.message("Tailcat did not become ready within 60 seconds") }
    try store.transaction { state in state.worker?.address = address }
    print("Serving \(worker.name) from \(worker.workspace).")
    if !worker.peers.contains(where: { !$0.revoked }) { try showInvite(store, options: options) }
    else { print("Paired controllers can connect. Use pmai tailcat invite to add another.") }
    try await wait(process)
  }

  private static func showInvite(_ store: TailcatStore, options: Options) throws {
    guard let lifetime = Double(options.values["--expires"] ?? "300") else {
      throw Error.message("--expires must be a number of seconds")
    }
    let invite = try store.invite(lifetime: lifetime)
    print("Pairing invite for \(invite.name); expires \(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: invite.expires))).")
    print(invite.url)
    let output = options.values["--qr"].map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
    try TailcatQR.show(invite.url, output: output)
  }

  private static func pair(_ name: String, value: String, store: TailcatStore, home: URL,
    tailcat: String, executable: String, options: Options, environment: [String: String]) async throws {
    guard !name.isEmpty, name.count <= 64, name.utf8.allSatisfy({
      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
    }), let permission = ACPPermissionPolicy(rawValue: options.values["--permission"] ?? "auto") else {
      throw Error.message("Use a simple agent name and --permission auto, allow, or reject")
    }
    let invite = try TailcatInvite(url: TailcatQR.read(value))
    let configurationURL = configURL(options, environment: environment)
    var configuration = FileManager.default.fileExists(atPath: configurationURL.path)
      ? try MaiConfiguration.load(from: configurationURL) : MaiConfiguration()
    let known = try store.read().remotes[name]
    guard known?.workerID == invite.workerID || (known == nil
      && !configuration.providers.contains(where: { $0.id == name })
      && !configuration.agents.contains(where: { $0.id == name })) else {
      throw Error.message("That name already belongs to another agent; choose a new name")
    }
    let key = try clientKey(store, tailcat: tailcat)
    let transport = try StdioJSONRPCTransport.spawn(command: tailcat,
      arguments: ["--key=" + key.path, invite.address, "80"])
    let peer = JSONRPCPeer(transport: transport)
    await peer.start()
    let result: JSONValue
    do {
      result = try await peer.request("_pmai/enroll", params: .object([
        "token": .string(invite.token),
        "name": .string(options.values["--name"] ?? ProcessInfo.processInfo.hostName)
      ]), timeout: 30)
      await peer.close()
    } catch { await peer.close(); throw error }
    guard result.objectValue?["workerID"]?.stringValue == invite.workerID,
      let workspace = result.objectValue?["workspace"]?.stringValue, workspace.hasPrefix("/") else {
      throw Error.message("Worker identity did not match the invite")
    }
    var remote = TailcatRemote(name: name, workerID: invite.workerID, address: invite.address, workspace: workspace)
    remote.lastSeen = Date()
    try store.transaction { $0.remotes[name] = remote }
    let provider = ConfiguredProvider(id: name, kind: "acp", displayName: invite.name, options: [
      "command": .string(executable),
      "args": .array(["tailcat", "connect", name, "--home", home.path, "--tailcat", tailcat].map(JSONValue.string)),
      "remoteCwd": .string(workspace), "readClientFiles": .bool(false),
      "permission": .string(permission.rawValue),
    ])
    if let index = configuration.providers.firstIndex(where: { $0.id == name }) { configuration.providers[index] = provider }
    else { configuration.providers.append(provider) }
    if !configuration.agents.contains(where: { $0.id == name }) {
      configuration.upsertAgent(AgentDefinition(id: name, description: "Tailcat worker: " + invite.name,
        instructions: "", provider: ProviderID(name), model: ""))
    }
    try configuration.save(to: configurationURL)
    print("Paired \(name). Saved ACP agent in \(configurationURL.path).\nUse pmai --agent \(name), or /agent use \(name) after restarting an open pmai session.")
  }

  private static func configURL(_ options: Options, environment: [String: String]) -> URL {
    let local = FileManager.default.currentDirectoryPath + "/pmai.json"
    let path = options.values["--config"] ?? environment["PMAI_CONFIG"]
      ?? (FileManager.default.fileExists(atPath: local) ? local : "~/.config/pmai/config.json")
    return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
  }

  private static func clientKey(_ store: TailcatStore, tailcat: String) throws -> URL {
    let lock = try ACPFileLock(url: store.directory.appendingPathComponent("key.lock"), wait: true)
    return try withExtendedLifetime(lock) {
      let url = store.directory.appendingPathComponent("client.private.json")
      if !FileManager.default.fileExists(atPath: url.path) {
        _ = try capture(tailcat, ["genkey", "--client", "--key=" + url.path])
      }
      return url
    }
  }

  static func resolveExecutable(_ command: String) -> String? {
    if command.contains("/") {
      let path = NSString(string: command).expandingTildeInPath
      return FileManager.default.isExecutableFile(atPath: path)
        ? URL(fileURLWithPath: path).standardizedFileURL.path : nil
    }
    for folder in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") {
      let path = String(folder) + "/" + command
      if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return nil
  }

  static func capture(_ command: String, _ arguments: [String], input: Data? = nil) throws -> String {
    let process = Process(), output = Pipe(), stdin = Pipe()
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = arguments
    process.standardInput = input == nil ? FileHandle.nullDevice : stdin.fileHandleForReading
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    try process.run()
    if let input { try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close() }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw Error.message("\(URL(fileURLWithPath: command).lastPathComponent) exited with status \(process.terminationStatus)") }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func wait(_ process: Process) async throws {
    #if !os(Windows)
      let previousINT = signal(SIGINT, SIG_IGN), previousTERM = signal(SIGTERM, SIG_IGN)
      let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
      let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
      interrupt.setEventHandler { if process.isRunning { process.interrupt() } }
      terminate.setEventHandler { if process.isRunning { process.terminate() } }
      interrupt.resume(); terminate.resume()
      defer { interrupt.cancel(); terminate.cancel(); signal(SIGINT, previousINT); signal(SIGTERM, previousTERM) }
    #endif
    while process.isRunning { try await Task.sleep(for: .milliseconds(100)) }
    guard process.terminationStatus == 0 || process.terminationReason == .uncaughtSignal else {
      throw Error.message("Tailcat exited with status \(process.terminationStatus)")
    }
  }
}
