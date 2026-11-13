#if os(macOS) || os(Linux)
import Foundation
import MaiCore

/// Host-owned policy. Only workspace and home are shared with the worker;
/// neither the policy nor the original repository is mounted in the container.
public struct ProjectBox: Codable, Sendable, Identifiable {
  public var id: UUID
  public var project: String
  public var enabled = true
  public var engine = "docker"
  public var image = "ubuntu:24.04"
  public var network = "bridge"
  public var ports: [String] = []
  public var debug = false
  public var memory = "4g"
  public var cpus = 2
  public var baseCommit: String
  public var name: String { "pmai-box-" + id.uuidString.lowercased() }

  public init(project: String, baseCommit: String, id: UUID = UUID()) {
    self.id = id
    self.project = project
    self.baseCommit = baseCommit
  }
}

public struct ProjectBoxes: Sendable {
  public let home: AgentHome
  public let environment: [String: String]
  public init(home: AgentHome, environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.home = home
    self.environment = environment
  }
  public struct Failure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
  }
  public func directory(_ box: ProjectBox) -> URL {
    home.rootURL.appendingPathComponent("box/" + box.id.uuidString.lowercased())
  }
  public func workspace(_ box: ProjectBox) -> URL {
    home.rootURL.appendingPathComponent("worktree/" + box.id.uuidString.lowercased())
  }
  public func guestHome(_ box: ProjectBox) -> AgentHome {
    AgentHome(rootURL: directory(box).appendingPathComponent("home"))
  }
  public func list() throws -> [ProjectBox] {
    let root = home.rootURL.appendingPathComponent("box")
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { UUID(uuidString: $0.lastPathComponent) != nil }
      .map { try JSONDecoder().decode(ProjectBox.self, from: Data(contentsOf: $0.appendingPathComponent("box.json"))) }
  }
  public func find(at directory: URL) throws -> ProjectBox? {
    let path = directory.resolvingSymlinksInPath().standardizedFileURL.path
    return try list().filter {
      let checkout = workspace($0).resolvingSymlinksInPath().standardizedFileURL.path
      return path == $0.project || path.hasPrefix($0.project + "/")
        || path == checkout || path.hasPrefix(checkout + "/")
    }
      .max { $0.project.count < $1.project.count }
  }
  public func save(_ box: ProjectBox) throws {
    try Self.validate(box)
    try Self.mkdir(directory(box))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(box).write(to: directory(box).appendingPathComponent("box.json"), options: .atomic)
  }
  public static func validate(_ box: ProjectBox) throws {
    guard ["docker", "podman"].contains(box.engine), ["none", "bridge"].contains(box.network),
      box.project.hasPrefix("/"), box.project != "/", !box.project.contains(","),
      URL(fileURLWithPath: box.project).standardizedFileURL.path == box.project,
      !["/pmai", "/opt/pmai"].contains(where: { box.project == $0 || $0.hasPrefix(box.project + "/") || box.project.hasPrefix($0 + "/") }),
      !box.image.isEmpty, !box.image.hasPrefix("-"), !box.image.contains(where: \.isWhitespace),
      box.cpus > 0, box.memory.range(of: #"^[1-9][0-9]*[mg]$"#, options: .regularExpression) != nil,
      box.baseCommit.range(of: #"^[0-9a-f]{40,64}$"#, options: .regularExpression) != nil
    else { throw Failure("Invalid box policy.") }
    for port in box.ports {
      let pair = port.split(separator: ":", omittingEmptySubsequences: false)
      guard pair.count == 2, pair.allSatisfy({ Int($0).map { (1...65535).contains($0) } == true }) else {
        throw Failure("Ports must be HOST_PORT:GUEST_PORT (1–65535).")
      }
    }
    guard box.network != "none" || box.ports.isEmpty else {
      throw Failure("Port forwarding requires bridge networking.")
    }
  }
  private static func mkdir(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  /// Capture stdout in a file so large output cannot deadlock on a full pipe.
  /// Diagnostics never share ACP's stdout. Cancellation stops the launcher.
  public func run(_ command: String, _ arguments: [String], cwd: URL? = nil,
    input: FileHandle = .nullDevice, output: FileHandle? = nil, trimOutput: Bool = true) async throws -> String {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pmai-box-" + UUID().uuidString)
    FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
    defer { try? FileManager.default.removeItem(at: temporary) }
    let capture = try FileHandle(forWritingTo: temporary)
    defer { try? capture.close() }
    let process = Process()
    var childEnvironment = environment
    var args = arguments
    if command == "git" {
      childEnvironment = childEnvironment.filter { !$0.key.hasPrefix("GIT_") }
      childEnvironment["GIT_CONFIG_NOSYSTEM"] = "1"
      childEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
      args = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + args
    }
    try LocalProcess.configure(process, command: command, arguments: args,
      environment: childEnvironment, workingDirectory: cwd)
    process.standardInput = input
    process.standardOutput = output ?? capture
    process.standardError = FileHandle.standardError
    try Task.checkCancellation()
    let status: Int32 = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do {
          try process.run()
          if Task.isCancelled, process.isRunning { process.terminate() }
        } catch { continuation.resume(throwing: error) }
      }
    } onCancel: { if process.isRunning { process.terminate() } }
    try Task.checkCancellation()
    guard status == 0 else { throw Failure("\(command) failed (exit \(status)). The project was not run on the host.") }
    guard output == nil else { return "" }
    let text = String(decoding: try Data(contentsOf: temporary), as: UTF8.self)
    return trimOutput ? text.trimmingCharacters(in: .newlines) : text
  }
  public func gitRoot(at directory: URL) async throws -> String {
    let root = try await run("git", ["-C", directory.path, "rev-parse", "--show-toplevel"])
    return URL(fileURLWithPath: root).resolvingSymlinksInPath().path
  }

  public func create(_ box: ProjectBox, binary: URL, configuration: Data) async throws {
    try Self.validate(box)
    try Self.mkdir(home.rootURL.appendingPathComponent("box"))
    let lock = try await MaiFileLock.acquire(url: home.rootURL.appendingPathComponent("box/create.lock"))
    defer { withExtendedLifetime(lock) {} }
    guard try find(at: URL(fileURLWithPath: box.project)) == nil else {
      throw Failure("This project already has a box. Use on, off, start, or destroy.")
    }
    // Persist intent first: failed provisioning must never silently launch locally.
    try save(box)
    try Self.mkdir(workspace(box).deletingLastPathComponent())
    _ = try await run("git", ["clone", "--no-local", "--no-hardlinks", "--", box.project, workspace(box).path])
    _ = try await run("git", ["-C", workspace(box).path, "checkout", "--detach", box.baseCommit])
    _ = try await run("git", ["-C", workspace(box).path, "remote", "remove", "origin"])
    try Self.mkdir(guestHome(box).rootURL)
    try configuration.write(to: guestHome(box).rootURL.appendingPathComponent("config.json"), options: .atomic)
    let build = directory(box).appendingPathComponent("build")
    try Self.mkdir(build)
    try FileManager.default.copyItem(at: binary, to: build.appendingPathComponent("pmai"))
    let recipe = """
      FROM \(box.image)
      USER root
      RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git curl build-essential gdb && rm -rf /var/lib/apt/lists/*
      COPY --chmod=755 pmai /opt/pmai/pmai
      RUN /opt/pmai/pmai --version
      ENTRYPOINT []
      CMD ["sleep", "infinity"]
      """
    try Data(recipe.utf8).write(to: build.appendingPathComponent("Dockerfile"))
    try await rebuild(box)
  }

  public func rebuild(_ box: ProjectBox, binary: URL? = nil) async throws {
    let build = directory(box).appendingPathComponent("build")
    if let binary { try Data(contentsOf: binary).write(to: build.appendingPathComponent("pmai"), options: .atomic) }
    _ = try await run(box.engine, ["build", "--tag", box.name, build.path])
    try await removeContainer(box)
    try await start(box)
  }

  public func createArguments(_ box: ProjectBox) throws -> [String] {
    try Self.validate(box)
    // Bind sources are generated by us, not supplied by the guest or project.
    for path in [workspace(box).path, guestHome(box).rootURL.path] where path.contains(",") {
      throw Failure("Box storage paths cannot contain commas.")
    }
    var args = ["create", "--name", box.name, "--label", "org.pmai.box=\(box.id.uuidString)",
      "--init", "--security-opt", "no-new-privileges", "--cap-drop", "ALL",
      "--cap-add", "CHOWN", "--cap-add", "DAC_OVERRIDE", "--cap-add", "FOWNER",
      "--cap-add", "SETUID", "--cap-add", "SETGID", "--cap-add", "FSETID",
      "--pids-limit", "512", "--memory", box.memory, "--cpus", String(box.cpus),
      "--log-opt", "max-size=10m", "--log-opt", "max-file=2", "--network", box.network == "none" ? "none" : box.name,
      "--mount", "type=bind,src=\(workspace(box).path),dst=\(box.project)",
      "--mount", "type=bind,src=\(guestHome(box).rootURL.path),dst=/pmai/home",
      "--env", "HOME=/pmai/home", "--env", "PMAI_HOME=/pmai/home",
      "--env", "PMAI_CONFIG=/pmai/home/config.json", "--workdir", box.project]
    if box.debug { args += ["--cap-add", "SYS_PTRACE"] }
    for port in box.ports { args += ["--publish", "127.0.0.1:" + port] }
    return args + [box.name]
  }
  private func exists(_ box: ProjectBox) async throws -> Bool {
    // Listing distinguishes an absent container from an unavailable daemon.
    let names = try await run(box.engine, ["container", "ls", "--all", "--format", "{{.Names}}"])
    return names.split(separator: "\n").contains(Substring(box.name))
  }
  public func start(_ box: ProjectBox) async throws {
    try Self.validate(box)
    let lock = try await MaiFileLock.acquire(url: directory(box).appendingPathComponent("runtime.lock"))
    defer { withExtendedLifetime(lock) {} }
    if try await !exists(box) {
      if box.network == "bridge" {
        let networks = try await run(box.engine, ["network", "ls", "--format", "{{.Name}}"])
        if !networks.split(separator: "\n").contains(Substring(box.name)) {
          _ = try await run(box.engine, ["network", "create", box.name])
        }
      }
      _ = try await run(box.engine, createArguments(box))
    }
    _ = try await run(box.engine, ["start", box.name])
  }
  public func isRunning(_ box: ProjectBox) async throws -> Bool {
    let names = try await run(box.engine, ["container", "ls", "--format", "{{.Names}}"])
    return names.split(separator: "\n").contains(Substring(box.name))
  }
  public func stop(_ box: ProjectBox) async throws {
    let lock = try await MaiFileLock.acquire(url: directory(box).appendingPathComponent("runtime.lock"))
    defer { withExtendedLifetime(lock) {} }
    if try await exists(box) { _ = try await run(box.engine, ["stop", "--time", "10", box.name]) }
  }
  private func removeContainer(_ box: ProjectBox) async throws {
    let lock = try await MaiFileLock.acquire(url: directory(box).appendingPathComponent("runtime.lock"))
    defer { withExtendedLifetime(lock) {} }
    if try await exists(box) { _ = try await run(box.engine, ["rm", "--force", box.name]) }
    let networks = try await run(box.engine, ["network", "ls", "--format", "{{.Name}}"])
    if networks.split(separator: "\n").contains(Substring(box.name)) {
      _ = try await run(box.engine, ["network", "rm", box.name])
    }
  }
  public func destroy(_ box: ProjectBox) async throws {
    try await removeContainer(box)
    // Preserve checkout, guest history and image; only an explicit off/destroy allows local execution.
    var disabled = box
    disabled.enabled = false
    try save(disabled)
  }
  public func launch(_ box: ProjectBox, arguments: [String], cwd: URL, tty: Bool) async throws {
    try await start(box)
    var forwarded: [String] = []
    var index = 0
    while index < arguments.count {
      if ["--home", "--config"].contains(arguments[index]) { index += 2; continue }
      forwarded.append(arguments[index]); index += 1
    }
    let path = cwd.resolvingSymlinksInPath().path
    let source = workspace(box).resolvingSymlinksInPath().standardizedFileURL.path
    let guestPath = path == source || path.hasPrefix(source + "/") ? box.project + path.dropFirst(source.count) : path
    _ = try await run(box.engine, ["exec", tty ? "-it" : "-i", "--workdir", guestPath,
      box.name, "/opt/pmai/pmai"] + forwarded,
      input: .standardInput, output: .standardOutput)
  }
  public func diff(_ box: ProjectBox) async throws -> String {
    try await start(box)
    _ = try await run(box.engine, ["exec", box.name, "git", "add", "--intent-to-add", "--", "."])
    return try await run(box.engine, ["exec", box.name, "git", "diff", "--no-ext-diff", "--no-textconv",
      "--binary", box.baseCommit, "--", "."], trimOutput: false)
  }
  public func apply(_ box: ProjectBox) async throws {
    let patch = try await diff(box)
    guard !patch.isEmpty else { return }
    let url = directory(box).appendingPathComponent("result.patch")
    try Data(patch.utf8).write(to: url, options: .atomic)
    let args = ["-C", box.project, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "apply"]
    _ = try await run("git", args + ["--check", "--", url.path])
    _ = try await run("git", args + ["--", url.path])
  }
}
extension ACPClient.Configuration {
  /// A local-looking pmai command can transparently enter a project box.
  /// Apply the same host boundary even when the caller explicitly enabled forwarding.
  mutating func restrictProjectBoxAccess() throws {
    guard URL(fileURLWithPath: command).lastPathComponent == "pmai" else { return }
    var env = environment ?? ProcessInfo.processInfo.environment
    if let index = arguments.firstIndex(of: "--home"), index + 1 < arguments.count {
      env[AgentHome.environmentVariable] = arguments[index + 1]
    }
    let boxes = ProjectBoxes(home: AgentHome.resolve(environment: env), environment: env)
    if let box = try boxes.find(at: workingDirectory ?? AgentExecutionScope.directory), box.enabled {
      forwardTools = false
      readClientFiles = false
    }
  }
}
#endif
