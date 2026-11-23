import Foundation
import MaiCore

#if os(macOS) || os(Linux) || os(Android) || os(Windows)
/// Small host helpers use the same cancellation, process groups and concurrent
/// pipe draining as run_shell. No Foundation exit socket is inherited on Linux.
package enum CapturedProcess {
  private struct Failure: LocalizedError {
    let errorDescription: String?
  }

  package static func run(
    _ command: String, arguments: [String] = [], input: Data? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    timeout: TimeInterval? = 30, outputLimit: Int = 1024 * 1024, checkExit: Bool = true
  ) async throws -> (stdout: Data, stderr: Data, exitCode: Int32) {
    try Task.checkCancellation()
    let executable = try LocalExecutable.resolve(
      command, environment: environment, workingDirectory: directory)
    let result = try await MaiHostProcess.run(
      executable: URL(fileURLWithPath: executable), arguments: arguments,
      workingDirectory: directory, environment: environment, stdin: input,
      timeout: timeout, outputLimit: outputLimit, outputMode: .inline)
    let name = URL(fileURLWithPath: executable).lastPathComponent
    if result.timedOut { throw Failure(errorDescription: "\(name) timed out.") }
    if result.stdoutDropped > 0 || result.stderrDropped > 0 {
      throw Failure(errorDescription: "\(name) exceeded the output limit.")
    }
    if checkExit, result.exitCode != 0 {
      let detail = String(decoding: result.stderr, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw Failure(errorDescription: "\(name) exited with status \(result.exitCode)."
        + (detail.isEmpty ? "" : " " + detail))
    }
    return (result.stdout, result.stderr, result.exitCode)
  }
}
#endif
