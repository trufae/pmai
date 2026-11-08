import Foundation
import MaiCore

enum CLIApp {
  static let usage = "Usage: pmai app run --allow-exec DIRECTORY [ARGS...]"

  private struct Manifest: Decodable {
    struct Step: Decodable {
      let command: [String]
      let pkgConfig: [String]?

      enum CodingKeys: String, CodingKey {
        case command
        case pkgConfig = "pkg_config"
      }
    }

    let version: Int
    let build: Step?
    let run: Step
  }

  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  static func run(
    directory: String, arguments: [String], environment: [String: String],
    input: FileHandle = .standardInput, output: FileHandle = .standardOutput,
    diagnostics: FileHandle = .standardError, sessionURL: String? = nil
  ) async throws -> Int32 {
    let folder = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
    let manifest: Manifest
    do {
      let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
      manifest = try JSONDecoder().decode(Manifest.self, from: data)
    } catch {
      throw Failure(message: "Cannot read \(folder.path)/manifest.json: \(error)")
    }
    guard manifest.version == 1 else {
      throw Failure(message: "Unsupported CLI XDC manifest version: \(manifest.version)")
    }
    let launch = try checked(manifest.run.command)
    let build = try manifest.build.map { try checked($0.command) }

    let files = FileManager.default
    let temporary = files.temporaryDirectory.appendingPathComponent("pmai-app-\(UUID())", isDirectory: true)
    if build != nil {
      #if os(Windows)
        try files.createDirectory(at: temporary, withIntermediateDirectories: false)
      #else
        try files.createDirectory(at: temporary, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
      #endif
    }
    defer {
      if build != nil { try? files.removeItem(at: temporary) }
    }
    #if os(Windows)
      let executable = temporary.appendingPathComponent("app.exe")
    #else
      let executable = temporary.appendingPathComponent("app")
    #endif
    let path = executable.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } }
      ?? executable.path

    if let build {
      var command = build.map { $0 == "{bin}" ? path : $0 }
      if let packages = manifest.build?.pkgConfig, !packages.isEmpty {
        guard packages.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.contains("\0") }) else {
          throw Failure(message: "Expected package names in build.pkg_config.")
        }
        let output = Pipe()
        let config = try start(["pkg-config", "--cflags", "--libs"] + packages, in: folder,
          environment: environment, input: FileHandle.nullDevice, output: output, diagnostics: diagnostics)
        async let flags = readFlags(output.fileHandleForReading)
        guard await finish(config) == 0 else {
          throw Failure(message: "pkg-config failed for: \(packages.joined(separator: ", "))")
        }
        command += try MaiCLI.shellWords(String(decoding: await flags, as: UTF8.self), shellEscapes: true)
      }
      let status = await finish(try start(command, in: folder, environment: environment,
        input: FileHandle.nullDevice, output: diagnostics, diagnostics: diagnostics))
      if status != 0 { return status }
    }

    let command = launch.map { $0 == "{bin}" && build != nil ? path : $0 } + arguments
    var childEnvironment = environment
    childEnvironment.removeValue(forKey: "PMAI_APP_RPC")
    childEnvironment["PMAI_APP_RPC"] = sessionURL
    return await finish(try start(command, in: folder, environment: childEnvironment,
      input: input, output: output, diagnostics: diagnostics))
  }

  private static func checked(_ command: [String]) throws -> [String] {
    guard let program = command.first, !program.isEmpty,
      command.allSatisfy({ !$0.contains("\0") })
    else { throw Failure(message: "Expected a program followed by arguments in command.") }
    return command
  }

  private static func start(
    _ command: [String], in folder: URL, environment: [String: String],
    input: FileHandle, output: Any, diagnostics: FileHandle
  ) throws -> Process {
    try Task.checkCancellation()
    let process = Process()
    try LocalProcess.configure(process, command: command[0], arguments: Array(command.dropFirst()),
      environment: environment, workingDirectory: folder)
    process.standardInput = input
    process.standardOutput = output
    process.standardError = diagnostics
    try process.run()
    return process
  }

  private static func finish(_ process: Process) async -> Int32 {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
          process.waitUntilExit()
          let status = process.terminationStatus
          continuation.resume(returning: process.terminationReason == .uncaughtSignal
            ? 128 + status : status)
        }
      }
    } onCancel: {
      if process.isRunning { process.terminate() }
    }
  }

  private static func readFlags(_ handle: FileHandle) async -> Data {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: handle.readDataToEndOfFile())
      }
    }
  }
}
