import Foundation

public struct AgentPSOptions: Equatable, Sendable {
  public static let usage = "Usage: /ps [-a] [-p] | /ps -k PID"
  public var includeSubagents = false
  public var past = false
  public var killPID: Int32?
  public var help = false

  public init(_ argument: String) throws {
    let fields = argument.split(whereSeparator: \.isWhitespace)
    if fields == ["-h"] || fields == ["--help"] {
      help = true
      return
    }
    if fields.first == "-k" {
      guard fields.count == 2, fields[1].allSatisfy(\.isNumber),
        let pid = Int32(fields[1]), pid > 0
      else { throw InvalidArguments() }
      killPID = pid
      return
    }
    for field in fields {
      guard field.hasPrefix("-"), field.count > 1 else { throw InvalidArguments() }
      for flag in field.dropFirst() {
        switch flag {
        case "a": includeSubagents = true
        case "p": past = true
        default: throw InvalidArguments()
        }
      }
    }
  }

  public func includes(_ record: AgentCommandRecord) -> Bool {
    (includeSubagents || record.run.depth == 0)
      && (past ? record.state != .running : record.state == .running)
  }

  private struct InvalidArguments: LocalizedError {
    var errorDescription: String? { AgentPSOptions.usage }
  }
}
