#if os(macOS) || os(Linux)
import Foundation
import MaiCore

/// Host-owned policy. Shared pmai state is opt-in; box policy and other host
/// control directories stay hidden from the worker, including in shared mode.
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
  /// Presence enables live pmai state sharing. Mount the configuration directory
  /// rather than config.json itself so atomic saves work from either side.
  public var sharedConfigurationDirectory: String?
  public var name: String { "pmai-box-" + id.uuidString.lowercased() }

  public init(project: String, baseCommit: String, id: UUID = UUID()) {
    self.id = id
    self.project = project
    self.baseCommit = baseCommit
  }
}

public struct ProjectBoxes: Sendable {
  private static let privateStateDirectories = ["acp", "gateway", "remote-server", "tailcat", "forwiroh-client"]
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
    if let path = box.sharedConfigurationDirectory {
      guard path.hasPrefix("/"), path != "/", !path.contains(","),
        URL(fileURLWithPath: path).standardizedFileURL.path == path else {
        throw Failure("Invalid shared configuration directory.")
      }
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

  /// Attach host state to an existing box without discarding installed packages.
  /// The previous private home remains on disk; it is never merged over host data.
  public func shareHome(_ box: ProjectBox, configurationDirectory: URL) async throws {
    var shared = box
    shared.sharedConfigurationDirectory = configurationDirectory.resolvingSymlinksInPath().path
    _ = try MaiConfiguration.load(from: configurationDirectory.appendingPathComponent("config.json"))
    _ = try createArguments(shared)
    if box.sharedConfigurationDirectory == shared.sharedConfigurationDirectory {
      try await start(shared)
      return
    }
    // Hold the lifecycle lock through snapshotting and replacement. A failed
    // snapshot leaves the original container intact and its policy unchanged.
    do {
      let lock = try await MaiFileLock.acquire(url: directory(box).appendingPathComponent("runtime.lock"))
      defer { withExtendedLifetime(lock) {} }
      if try await exists(box) {
        _ = try await run(box.engine, ["stop", "--time", "10", box.name])
        _ = try await run(box.engine, ["commit", box.name, box.name])
        _ = try await run(box.engine, ["rm", box.name])
      }
      try save(shared)
    }
    try await start(shared)
  }

  public func createArguments(_ box: ProjectBox) throws -> [String] {
    try Self.validate(box)
    // Bind sources are generated by us, not supplied by the guest or project.
    for path in [workspace(box).path, guestHome(box).rootURL.path, home.rootURL.path] where path.contains(",") {
      throw Failure("Box storage paths cannot contain commas.")
    }
    let relabel = box.engine == "podman" ? ",relabel=private" : ""
    var args = ["create", "--name", box.name, "--label", "org.pmai.box=\(box.id.uuidString)",
      "--init", "--security-opt", "no-new-privileges", "--cap-drop", "ALL",
      "--cap-add", "CHOWN", "--cap-add", "DAC_OVERRIDE", "--cap-add", "FOWNER",
      "--cap-add", "SETUID", "--cap-add", "SETGID", "--cap-add", "FSETID",
      "--pids-limit", "512", "--memory", box.memory, "--cpus", String(box.cpus),
      "--log-driver", "json-file", "--log-opt", "max-size=10m", "--network", box.network == "none" ? "none" : box.name,
      "--mount", "type=bind,src=\(workspace(box).path),dst=\(box.project)" + relabel,
      "--mount", "type=bind,src=\(guestHome(box).rootURL.path),dst=/pmai/home" + relabel,
      "--env", "HOME=/pmai/home", "--env", "PMAI_BOX_ID=" + box.id.uuidString,
      "--workdir", box.project]
    if let configuration = box.sharedConfigurationDirectory {
      let sharedRelabel = box.engine == "podman" ? ",relabel=shared" : ""
      args += [
        "--mount", "type=bind,src=\(home.rootURL.path),dst=/pmai/state" + sharedRelabel,
        "--env", "PMAI_HOME=/pmai/state",
      ]
      if URL(fileURLWithPath: configuration).resolvingSymlinksInPath().path
        == home.rootURL.resolvingSymlinksInPath().appendingPathComponent("config").path {
        args += ["--env", "PMAI_CONFIG=/pmai/state/config/config.json"]
      } else {
        // Older homes keep their configuration outside PMAI_HOME until moved.
        args += ["--mount", "type=bind,src=\(configuration),dst=/pmai/config" + sharedRelabel,
          "--env", "PMAI_CONFIG=/pmai/config/config.json"]
      }
      // Mask host control state and all box workspaces. The guest cannot unmount
      // these read-only filesystems (it has no SYS_ADMIN capability).
      for name in ["box", "worktree"] {
        args += ["--tmpfs", "/pmai/state/\(name):ro,nosuid,nodev,noexec,size=64k"]
      }
      // Server identities and session leases must remain writable, but must not
      // reuse the host's control state. These sources have a host-owned parent.
      for name in Self.privateStateDirectories {
        let source = directory(box).appendingPathComponent("runtime-state/" + name)
        args += ["--mount", "type=bind,src=\(source.path),dst=/pmai/state/\(name)" + relabel]
      }
      let local = URL(fileURLWithPath: box.project).appendingPathComponent(AgentHome.directoryName)
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory), isDirectory.boolValue {
        args += ["--mount", "type=bind,src=\(local.path),dst=\(local.path)" + sharedRelabel]
      }
    } else {
      args += ["--env", "PMAI_HOME=/pmai/home", "--env", "PMAI_CONFIG=/pmai/home/config.json"]
    }
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
    if box.sharedConfigurationDirectory != nil {
      for name in Self.privateStateDirectories {
        try Self.mkdir(directory(box).appendingPathComponent("runtime-state/" + name))
      }
    }
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
  /// The shell only sequences engine commands; all values remain positional arguments.
  /// Never execute a host pmai binary to reach an existing box: it may predate boxing.
  public func launchCommand(_ box: ProjectBox, arguments: [String], cwd: URL, tty: Bool = false)
    throws -> (command: String, arguments: [String], directory: String) {
    try Self.validate(box)
    var forwarded: [String] = []
    var index = 0
    while index < arguments.count {
      if ["--home", "--config"].contains(arguments[index]) { index += 2; continue }
      forwarded.append(arguments[index]); index += 1
    }
    let path = cwd.resolvingSymlinksInPath().path
    let source = workspace(box).resolvingSymlinksInPath().standardizedFileURL.path
    let guestPath = path == source || path.hasPrefix(source + "/") ? box.project + path.dropFirst(source.count) : path
    let script = #"""
      pmai_engine=$1; pmai_box=$2; pmai_cwd=$3; pmai_tty=$4; shift 4
      "$pmai_engine" start "$pmai_box" >/dev/null || exit $?
      exec "$pmai_engine" exec "$pmai_tty" --workdir "$pmai_cwd" "$pmai_box" "$@"
      """#
    // Docker Desktop can retain old file entries after host atomic saves.
    // Refresh their directories before the worker reads settings and history.
    let worker = box.sharedConfigurationDirectory == nil ? ["/opt/pmai/pmai"] : ["/bin/sh", "-c", #"""
      ls -A /pmai/state "${PMAI_CONFIG%/*}" >/dev/null || exit $?
      if [ -d .pmai ]; then ls -A .pmai >/dev/null || exit $?; fi
      exec /opt/pmai/pmai "$@"
      """#, "pmai"]
    return ("/bin/sh", ["-c", script, "pmai-box", box.engine, box.name, guestPath, tty ? "-it" : "-i"] + worker + forwarded, guestPath)
  }
  public func diff(_ box: ProjectBox) async throws -> String {
    try await start(box)
    let paths = ["."] + (box.sharedConfigurationDirectory == nil ? [] : [":(exclude).pmai"])
    _ = try await run(box.engine, ["exec", box.name, "git", "add", "--intent-to-add", "--"] + paths)
    return try await run(box.engine, ["exec", box.name, "git", "diff", "--no-ext-diff", "--no-textconv",
      "--binary", box.baseCommit, "--"] + paths, trimOutput: false)
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
  public mutating func restrictProjectBoxAccess() throws {
    guard URL(fileURLWithPath: command).lastPathComponent == "pmai" else { return }
    var env = environment ?? ProcessInfo.processInfo.environment
    if let index = arguments.firstIndex(of: "--home"), index + 1 < arguments.count {
      env[AgentHome.environmentVariable] = arguments[index + 1]
    }
    let boxes = ProjectBoxes(home: AgentHome.resolve(environment: env), environment: env)
    let cwd = workingDirectory ?? AgentExecutionScope.directory
    if let box = try boxes.find(at: cwd), box.enabled {
      let launch = try boxes.launchCommand(box, arguments: arguments, cwd: cwd)
      command = launch.command
      arguments = launch.arguments
      remoteWorkingDirectory = launch.directory
      forwardTools = false
      readClientFiles = false
    }
  }
}
#endif
