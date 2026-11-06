import Foundation
import MaiCore
import MaiStandardTools

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

extension MaiCLI {
  static func defaultConfigurationPath(environment: [String: String]) -> String {
    AgentHome.expandUserPath("~/.config/pmai/config.json", environment: environment)
  }

  static func initialConfiguration() -> MaiConfiguration {
    MaiConfiguration(toolSources: [
      ConfiguredToolSource(id: "standard-tools", kind: MaiStandardToolsPlugin.factoryKind)
    ], fileAccess: .init())
  }

  static func editConfiguration(environment: [String: String]) async throws {
    let editor = environment["EDITOR"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard let command = editor.isEmpty ? fallbackEditor(environment: environment) : editor else {
      throw CLIError.noEditor
    }
    let url = URL(fileURLWithPath: defaultConfigurationPath(environment: environment))
    if !FileManager.default.fileExists(atPath: url.path) {
      try initialConfiguration().save(to: url)
    }
    guard await launchEditor(at: url, command: command, terminal: TerminalWriter()) else {
      exit(1)
    }
  }

  static func loadConfiguration(
    options: CLIOptions,
    environment: [String: String]
  ) throws -> (configuration: MaiConfiguration, path: String)? {
    if let explicit = options.configPath {
      let expanded = AgentHome.expandUserPath(explicit, environment: environment)
      guard FileManager.default.fileExists(atPath: expanded) else {
        throw CLIError.configNotFound(expanded)
      }
      return (try MaiConfiguration.load(from: URL(fileURLWithPath: expanded)), expanded)
    }
    let candidates = [
      FileManager.default.currentDirectoryPath + "/pmai.json",
      defaultConfigurationPath(environment: environment),
    ]
    for path in candidates where FileManager.default.fileExists(atPath: path) {
      return (try MaiConfiguration.load(from: URL(fileURLWithPath: path)), path)
    }
    return nil
  }
}
