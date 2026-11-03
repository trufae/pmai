#if !os(iOS)
import Foundation

/// Configures a local subprocess without interpreting its arguments as shell text.
public enum LocalProcess {
  public static func mergedEnvironment(
    _ environment: [String: String], overrides: [String: String] = [:]
  ) -> [String: String] {
    #if os(Windows)
    var result: [String: String] = [:]
    for source in [environment, overrides] {
      // Resolve conflicting spellings deterministically, preferring uppercase.
      for key in source.keys.sorted().reversed() {
        let canonical = key.lowercased() == "path" ? "Path" : key.uppercased()
        result[canonical] = source[key]
      }
    }
    return result
    #else
    return environment.merging(overrides) { _, configured in configured }
    #endif
  }

  public static func configure(
    _ process: Process, command: String, arguments: [String] = [],
    environment: [String: String]? = nil, workingDirectory: URL? = nil
  ) throws {
    #if os(Windows)
    let childEnvironment = mergedEnvironment(environment ?? ProcessInfo.processInfo.environment)
    #else
    let childEnvironment = environment ?? ProcessInfo.processInfo.environment
    #endif
    process.executableURL = URL(fileURLWithPath: try LocalExecutable.resolve(
      command, environment: childEnvironment, workingDirectory: workingDirectory))
    process.arguments = arguments
    #if os(Windows)
    process.environment = childEnvironment
    #else
    process.environment = environment
    #endif
    process.currentDirectoryURL = workingDirectory
  }
}
#endif
