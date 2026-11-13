#if os(macOS) || os(Linux)
import Foundation
import MaiCore
import MaiACP

public enum BoxCLI {
  public static let help = """
    Project boxes (off until explicitly created):
      pmai box create [--binary LINUX_PMAI] [--engine docker|podman]
                      [--image ubuntu:24.04] [--network bridge|none]
                      [--port HOST:GUEST] [--debug] [--memory 4g] [--cpus 2]
                      [--config GUEST_CONFIG | --share-home]
      pmai box status | on | off | start | stop | shell | diff | apply | destroy
      pmai box share-home
      pmai box rebuild [--binary LINUX_PMAI]

    Policy: ~/.pmai/box/<id>/box.json. Checkout: ~/.pmai/worktree/<id>.
    Create snapshots committed HEAD; local edits, ignored files and credentials are not copied.
    --config explicitly grants the guest the supplied configuration and its embedded secrets.
    Without it, configure providers inside the box. --binary must be a Linux executable
    for the engine architecture; otherwise the matching verified pmai release is downloaded.
    Normal pmai launches automatically enter enabled project boxes, including subdirectories.
    --share-home shares pmai settings, credentials and history with the host, including a
    project's existing .pmai directory. share-home enables this for an existing box and
    restarts it, preserving installed packages and its previous private home.
    off stops the box and restores host execution. stop keeps boxing enabled.
    apply imports the reviewed diff; conflicts leave the original checkout unchanged.
    destroy stops/removes the container and disables boxing, preserving checkout and history.
    rebuild retries image creation and replaces the container, losing installed packages but
    keeping the checkout and history. It also applies edited box.json runtime settings.
    bridge allows outbound networking; none also blocks model APIs and package downloads.
    Debugging grants SYS_PTRACE inside the container. Ports bind only to 127.0.0.1.
    """

  public static func run(_ arguments: [String], home: AgentHome, directory: URL,
    environment: [String: String]) async throws -> String {
    let boxes = ProjectBoxes(home: home, environment: environment)
    let action = arguments.first ?? "status"
    if ["help", "--help", "-h"].contains(action) { return help }
    if let id = environment["PMAI_BOX_ID"] {
      if action == "status" { return "Running inside project box \(id). Manage its lifecycle from a host terminal." }
      throw ProjectBoxes.Failure("Manage boxes from a host terminal. This worker cannot change host box policy.")
    }
    if action == "create" {
      let project = try await boxes.gitRoot(at: directory)
      let base = try await boxes.run("git", ["-C", project, "rev-parse", "HEAD"])
      var box = ProjectBox(project: project, baseCommit: base)
      var binary: URL?
      var configuration = try MaiCLI.initialConfiguration().encoded()
      var shareHome = false
      var customConfiguration = false
      var index = 1
      while index < arguments.count {
        let option = arguments[index]
        if option == "--debug" { box.debug = true; index += 1; continue }
        if option == "--share-home" { shareHome = true; index += 1; continue }
        guard index + 1 < arguments.count else { throw ProjectBoxes.Failure("Missing value for \(option).") }
        let value = arguments[index + 1]
        switch option {
        case "--binary": binary = URL(fileURLWithPath: AgentHome.expandUserPath(value))
        case "--engine": box.engine = value
        case "--image": box.image = value
        case "--network": box.network = value
        case "--port": box.ports.append(value)
        case "--memory": box.memory = value
        case "--cpus": box.cpus = Int(value) ?? 0
        case "--config":
          customConfiguration = true
          configuration = try MaiConfiguration.load(from: URL(fileURLWithPath: AgentHome.expandUserPath(value))).encoded()
        default: throw ProjectBoxes.Failure("Unknown box option: \(option)")
        }
        index += 2
      }
      if shareHome {
        guard !customConfiguration else { throw ProjectBoxes.Failure("Choose --share-home or --config.") }
        box.sharedConfigurationDirectory = try sharedConfigurationDirectory(home: home, environment: environment).path
      }
      try ProjectBoxes.validate(box)
      let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pmai-box-binary-" + UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: temporary) }
      if binary == nil {
        let arch = try await boxes.run(box.engine, ["info", "--format", box.engine == "podman" ? "{{.Host.Arch}}" : "{{.Architecture}}"])
        let platform: String
        switch arch {
        case "aarch64", "arm64": platform = "linux-arm64-musl"
        case "x86_64", "amd64": platform = "linux-x64-musl"
        default: throw ProjectBoxes.Failure("Unsupported engine architecture: \(arch). Supply --binary.")
        }
        let data = try await CLIUpdater.releaseBinary(platform: platform, version: MaiCLI.version, environment: environment)
        try data.write(to: temporary)
        binary = temporary
      }
      try await boxes.create(box, binary: binary!, configuration: configuration)
      return "Box enabled for \(project). Restart pmai to enter it. Workspace: \(boxes.workspace(box).path)"
    }
    guard arguments.count <= 1 || action == "rebuild" && arguments.count == 3 && arguments[1] == "--binary"
    else { throw ProjectBoxes.Failure(help) }
    guard var box = try boxes.find(at: directory) else {
      if action == "status" { return "Boxing is off for this project. Use pmai box create to enable it." }
      throw ProjectBoxes.Failure("No box exists for this project. Use pmai box create.")
    }
    switch action {
    case "status":
      return "Box \(box.id.uuidString): \(box.enabled ? "enabled" : "disabled")\nProject: \(box.project)\nWorkspace: \(boxes.workspace(box).path)\nEngine: \(box.engine)\nHome: \(box.sharedConfigurationDirectory == nil ? "private" : "shared with host")\nNetwork: \(box.network)\nDebug: \(box.debug)\nPorts: \(box.ports.joined(separator: ", "))"
    case "share-home":
      try await boxes.shareHome(box, configurationDirectory: sharedConfigurationDirectory(home: home, environment: environment))
      return "Host pmai settings, credentials and history are now shared. Restart pmai to enter the updated box."
    case "on": try await boxes.start(box); box.enabled = true; try boxes.save(box)
    case "off": try await boxes.stop(box); box.enabled = false; try boxes.save(box)
    case "start": try await boxes.start(box)
    case "stop": try await boxes.stop(box)
    case "destroy": try await boxes.destroy(box)
    case "rebuild": try await boxes.rebuild(box, binary: arguments.count == 3
      ? URL(fileURLWithPath: AgentHome.expandUserPath(arguments[2])) : nil)
    case "diff": return try await boxes.diff(box)
    case "apply": try await boxes.apply(box)
    case "shell":
      try await boxes.start(box)
      try runTerminal(try LocalExecutable.resolve(box.engine, environment: environment),
        arguments: ["exec", "-it", box.name, "/bin/bash"])
    default: throw ProjectBoxes.Failure(help)
    }
    return "Box: \(action) completed."
  }

  private static func sharedConfigurationDirectory(home: AgentHome, environment: [String: String]) throws -> URL {
    let file = home.configurationFileURL(environment: environment)
    if FileManager.default.fileExists(atPath: file.path) {
      _ = try MaiConfiguration.load(from: file)
    } else {
      try MaiCLI.initialConfiguration().save(to: file)
    }
    return file.deletingLastPathComponent().resolvingSymlinksInPath()
  }

  static func launch(_ box: ProjectBox, boxes: ProjectBoxes, arguments: [String],
    cwd: URL, tty: Bool) async throws {
    try await boxes.start(box)
    let launch = try boxes.launchCommand(box, arguments: arguments, cwd: cwd, tty: tty)
    if tty {
      try runTerminal(launch.command, arguments: launch.arguments)
    } else {
      _ = try await boxes.run(launch.command, launch.arguments,
        input: .standardInput, output: .standardOutput)
    }
  }

  private static func runTerminal(_ command: String, arguments: [String]) throws {
    // Foundation.Process creates a background process group, which the terminal
    // stops when docker/podman reads input. Keep the engine in pmai's foreground
    // job and restore terminal modes through the same handoff as shell commands.
    let invocation = ([command] + arguments).map(MaiCLI.shellQuote).joined(separator: " ")
    let status = try TerminalCommand.run("exec " + invocation)
    guard status == 0 else {
      let reason = status & 0x7f == 0 ? "exit \(status >> 8)" : "signal \(status & 0x7f)"
      throw ProjectBoxes.Failure("Box terminal command failed (\(reason)).")
    }
  }
}
#endif
