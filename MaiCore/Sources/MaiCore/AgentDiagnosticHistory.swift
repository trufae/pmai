import Foundation

/// A small, persistent timeline of runtime work that is absent from chat messages.
/// Provider attempts share a call ID; chunked summaries share an operation ID.
public struct AgentDiagnosticRecord: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID = UUID()
  public var sequence: Int = 0
  public var timestamp: Date = Date()
  public var sessionID: String
  public var context: AgentEventContext
  public var kind: String
  public var purpose: String?
  public var callID: UUID?
  public var operationID: UUID?
  public var value: JSONValue

  public init(sessionID: String, context: AgentEventContext, kind: String,
    purpose: String? = nil, callID: UUID? = nil, operationID: UUID? = nil,
    value: JSONValue = .object([:])) {
    self.sessionID = sessionID
    self.context = context
    self.kind = kind
    self.purpose = purpose
    self.callID = callID
    self.operationID = operationID
    self.value = DebugDiagnostics.sanitize(value)
  }

  public func copied(to sessionID: String) -> Self {
    var copy = self
    copy.id = UUID()
    copy.sessionID = sessionID
    return copy
  }
}

public struct AgentDiagnosticSnapshot: Codable, Equatable, Sendable {
  public var version = 1
  /// Old chats can contain unrecorded work. An empty timeline is not proof of no calls.
  public var coverage = "Recorded runtime activity only; earlier unrecorded calls are unavailable."
  public var counts: [String: Int]
  public var records: [AgentDiagnosticRecord]

  public init(records: [AgentDiagnosticRecord]) {
    self.records = records
    counts = Dictionary(grouping: records, by: \.kind).mapValues(\.count)
    counts["compactionAttempts"] = records.filter { $0.kind == "model.request" && $0.operationID != nil }.count
    counts["compactionOperations"] = records.filter { $0.kind == "compaction.started" }.count
  }
}

public final class AgentDiagnosticHistory: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [UUID: AgentDiagnosticRecord] = [:]
  private var sequence = 0

  public init() {}

  public func record(_ record: AgentDiagnosticRecord) {
    lock.withLock {
      var record = record
      sequence += 1
      record.sequence = sequence
      entries[record.id] = record
    }
  }

  public func restore(_ records: [AgentDiagnosticRecord]) {
    lock.withLock {
      for record in records where entries[record.id] == nil {
        entries[record.id] = record
        sequence = max(sequence, record.sequence)
      }
    }
  }

  public func records(sessionID: String, saved: [AgentDiagnosticRecord] = []) -> [AgentDiagnosticRecord] {
    lock.withLock {
      var combined = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
      for record in entries.values where record.sessionID == sessionID || combined[record.id] != nil {
        combined[record.id] = record
      }
      return combined.values.sorted {
        if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
        if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
        return $0.id.uuidString < $1.id.uuidString
      }
    }
  }
}

struct AgentDiagnosticScope: Sendable {
  @TaskLocal static var current: AgentDiagnosticScope?
  var operationID: UUID
  var purpose: String
}

extension AgentRuntime {
  func noteDiagnostic(_ kind: String, context: AgentEventContext, sessionID: String? = nil,
    purpose: String? = nil, callID: UUID? = nil, operationID: UUID? = nil,
    value: JSONValue = .object([:])) {
    diagnosticHistory.record(AgentDiagnosticRecord(
      sessionID: sessionID ?? context.pid.flatMap { liveRequests[$0]?.sessionID }
        ?? AgentExecutionScope.current?.sessionID ?? context.runID.uuidString,
      context: context, kind: kind, purpose: purpose ?? AgentDiagnosticScope.current?.purpose,
      callID: callID, operationID: operationID ?? AgentDiagnosticScope.current?.operationID, value: value))
  }

  static func diagnosticRequest(_ request: ProviderRequest) -> [String: JSONValue] {
    [
      "model": .string(request.model), "stream": .bool(request.stream),
      "estimatedInputTokens": .integer(contextTokens(request)),
      "estimatedRequestBytes": .integer((try? JSONEncoder().encode(request).count) ?? 0),
      "toolSchemaBytes": .integer((try? JSONEncoder().encode(request.tools).count) ?? 0),
      "instructionCharacters": .integer(AgentTranscriptEditor.characterCount(
        of: request.messages.filter(AgentPromptContext.isInstruction))),
      "reasoningCharacters": .integer(request.messages.reduce(0) { $0 + $1.reasoning.count }),
      "messages": .integer(request.messages.count),
      "lastMessageID": request.messages.last.map { .string($0.id) } ?? .null,
      "toolNames": .array(request.tools.map { .string($0.name) }),
      "options": (try? DebugDiagnostics.value(request.options)) ?? .null,
    ]
  }
}
