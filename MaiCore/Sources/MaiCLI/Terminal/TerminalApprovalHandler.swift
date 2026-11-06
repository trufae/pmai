import Foundation
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

actor TerminalApprovalHandler: ApprovalHandler {
  typealias Prompter = @Sendable (ApprovalRequest) async throws -> ApprovalDecision
  typealias CompactionPrompter = @Sendable (AutocompactionRequest) async throws -> AutocompactionDecision

  private struct ProjectSettings: Codable {
    var approvalMode: ToolApprovalMode?
    var pathYolo: Bool?
    var toolYolo: Set<String>?
    var debug: Bool?
    var debugFile: String?
    init() {}
    private enum CodingKeys: String, CodingKey { case approvalMode, pathYolo, toolYolo, yolo, debug, debugFile }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      approvalMode =
        try c.decodeIfPresent(ToolApprovalMode.self, forKey: .approvalMode)
        ?? c.decodeIfPresent(Bool.self, forKey: .yolo).map { $0 ? .yolo : .ask }
      pathYolo = try c.decodeIfPresent(Bool.self, forKey: .pathYolo)
      toolYolo = try c.decodeIfPresent(Set<String>.self, forKey: .toolYolo)
      debug = try c.decodeIfPresent(Bool.self, forKey: .debug)
      debugFile = try c.decodeIfPresent(String.self, forKey: .debugFile)
    }
    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encodeIfPresent(approvalMode, forKey: .approvalMode)
      try c.encodeIfPresent(pathYolo, forKey: .pathYolo)
      try c.encodeIfPresent(toolYolo?.sorted(), forKey: .toolYolo)
      try c.encodeIfPresent(debug, forKey: .debug)
      try c.encodeIfPresent(debugFile, forKey: .debugFile)
    }
  }

  private var projectSettingsURL: URL
  private var defaultApprovalMode: ToolApprovalMode
  private var projectSettings: ProjectSettings
  private var delegate: (any ApprovalHandler)?
  private var approvalMode: ToolApprovalMode
  private var sessionApprovalMode: ToolApprovalMode?
  private var debugEnabled: Bool
  /// Asks through the REPL's own prompt while the persistent screen owns the
  /// terminal, so a question from a child agent never fights the line editor
  /// for stdin.
  private var prompter: Prompter?
  private var compactionPrompter: CompactionPrompter?

  init(
    configuration: ConfiguredApprovals, projectSettingsURL: URL, mode: ToolApprovalMode? = nil
  ) throws {
    self.projectSettingsURL = projectSettingsURL
    let projectSettings =
      FileManager.default.fileExists(atPath: projectSettingsURL.path)
      ? try MaiJSONCoding.default.makeDecoder().decode(
        ProjectSettings.self, from: Data(contentsOf: projectSettingsURL))
      : ProjectSettings()
    self.projectSettings = projectSettings
    self.defaultApprovalMode = mode ?? configuration.mode
    self.approvalMode = mode ?? projectSettings.approvalMode ?? configuration.mode
    self.debugEnabled = projectSettings.debug ?? false
  }

  /// Adopts the newly opened project's approval and debug settings.
  func focusProject(_ url: URL) throws {
    let settings = FileManager.default.fileExists(atPath: url.path)
      ? try MaiJSONCoding.default.makeDecoder().decode(ProjectSettings.self, from: Data(contentsOf: url))
      : ProjectSettings()
    projectSettingsURL = url
    projectSettings = settings
    approvalMode = settings.approvalMode ?? defaultApprovalMode
    debugEnabled = settings.debug ?? false
  }

  /// Routes `ask` decisions elsewhere while another surface owns the terminal.
  func setDelegate(_ handler: (any ApprovalHandler)?) {
    delegate = handler
  }

  func setApprovalMode(_ mode: ToolApprovalMode) { sessionApprovalMode = mode }
  func toolApprovalMode() async -> ToolApprovalMode? {
    await delegate?.toolApprovalMode() ?? currentApprovalMode()
  }
  func toolApprovalMode(for tool: ToolDefinition) async -> ToolApprovalMode? {
    await delegate?.toolApprovalMode(for: tool) ?? effectiveApprovalMode(for: tool)
  }
  private func effectiveApprovalMode(for tool: ToolDefinition) -> ToolApprovalMode {
    projectSettings.toolYolo?.contains(tool.name) == true ? .yolo : currentApprovalMode()
  }
  func currentApprovalMode() -> ToolApprovalMode { sessionApprovalMode ?? approvalMode }
  func yoloTools() -> [String] { projectSettings.toolYolo?.sorted() ?? [] }
  func permitsUnattendedExecution() -> Bool { currentApprovalMode() == .yolo }
  func permitsUnattendedPathAccess() -> Bool {
    if let sessionApprovalMode { return sessionApprovalMode == .yolo }
    return approvalMode == .yolo && projectSettings.pathYolo == true
  }
  func permitsUnattendedApproval(_ request: ApprovalRequest) -> Bool {
    request.tool.name == "files_path_access"
      ? permitsUnattendedPathAccess() : effectiveApprovalMode(for: request.tool) == .yolo
  }

  func saveToolYolo(_ name: String) throws {
    guard name != "files_path_access" else { return }
    var draft = projectSettings
    draft.toolYolo = (draft.toolYolo ?? []).union([name])
    try MaiJSONCoding.default.makeEncoder().encode(draft)
      .write(to: projectSettingsURL, options: .atomic)
    projectSettings = draft
  }

  func saveApprovalMode(_ mode: ToolApprovalMode, includingPaths: Bool = false) throws {
    var draft = projectSettings
    draft.approvalMode = mode
    draft.pathYolo = mode == .yolo && includingPaths ? true : nil
    draft.toolYolo = nil
    try MaiJSONCoding.default.makeEncoder().encode(draft)
      .write(to: projectSettingsURL, options: .atomic)
    sessionApprovalMode = nil
    approvalMode = mode
    projectSettings = draft
  }

  func isDebugEnabled() -> Bool { debugEnabled }

  func debugLogURL() -> URL {
    if let path = projectSettings.debugFile { return URL(fileURLWithPath: path) }
    return defaultDebugLogURL()
  }

  func defaultDebugLogURL() -> URL {
    projectSettingsURL.deletingLastPathComponent().appendingPathComponent("debug.jsonl")
  }

  func saveDebugFile(_ url: URL?) throws {
    var draft = projectSettings
    draft.debugFile = url?.path
    try MaiJSONCoding.default.makeEncoder().encode(draft)
      .write(to: projectSettingsURL, options: .atomic)
    projectSettings = draft
  }

  func saveDebugEnabled(_ enabled: Bool) throws {
    var draft = projectSettings
    draft.debug = enabled
    try MaiJSONCoding.default.makeEncoder().encode(draft)
      .write(to: projectSettingsURL, options: .atomic)
    projectSettings = draft
    debugEnabled = enabled
  }

  func resetSettings() throws {
    var draft = ProjectSettings()
    draft.approvalMode = ConfiguredApprovals().mode
    draft.debug = false
    try MaiJSONCoding.default.makeEncoder().encode(draft)
      .write(to: projectSettingsURL, options: .atomic)
    projectSettings = draft
    defaultApprovalMode = ConfiguredApprovals().mode
    approvalMode = defaultApprovalMode
    sessionApprovalMode = nil
    debugEnabled = false
  }

  func setPrompter(_ prompter: Prompter?) {
    self.prompter = prompter
  }

  func setCompactionPrompter(_ prompter: CompactionPrompter?) {
    compactionPrompter = prompter
  }

  func decideCompaction(_ request: AutocompactionRequest) async throws -> AutocompactionDecision {
    // Unattended tool approval does not grant permission to replace conversation history.
    if let delegate { return try await delegate.decideCompaction(request) }
    if let compactionPrompter { return try await compactionPrompter(request) }
    guard isatty(STDIN_FILENO) != 0 else { return .compact }
    FileHandle.standardError.write(Data(
      "Context limit: about \(request.estimatedTokens) tokens (threshold \(request.threshold)).\n"
        .utf8))
    if let pruning = request.pruning {
      FileHandle.standardError.write(Data("Pruning preview: \(pruning.summary). Keeps the start and end of each output.\n".utf8))
    }
    let editor = TerminalLineEditor()
    while true {
      guard let line = editor.readLine(
        prompt: (request.pruning == nil ? "" : "[p] prune old tool output / ")
          + "[y] summarize / [n] keep context / [x] clear chat and continue / [c] stop: ", completions: [])
      else { return .cancelRun }
      if editor.wasInterrupted { throw CancellationError() }
      switch line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "y", "yes", "compact", "s", "summarize": return .compact
      case "p", "prune":
        if request.pruning != nil { return .pruneToolOutput }
      case "n", "no", "continue", "skip": return .continueWithoutCompacting
      case "x", "clear": return .clearChat
      case "c", "cancel", "stop": return .cancelRun
      default: continue
      }
    }
  }

  func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    if let delegate, await delegate.toolApprovalMode(for: request.tool) != nil {
      return try await delegate.decide(request)
    }
    let approvalMode = currentApprovalMode()
    if permitsUnattendedApproval(request) { return .approve(arguments: request.call.arguments) }
    guard approvalMode == .ask else {
      return .deny(reason: "Smart approval must be evaluated by the runtime.")
    }
    return try await interactiveDecision(request)
  }

  func decideRemote(_ params: JSONValue, host: String) async throws -> String? {
    let tool = params.objectValue?["toolCall"]?.objectValue ?? [:]
    let name = "\(host)::\(tool["title"]?.stringValue ?? "Remote tool")"
    let arguments = tool["rawInput"] ?? .object([:])
    let request = ApprovalRequest(
      run: .init(runID: UUID(), parentRunID: nil, agentID: host, depth: 0),
      tool: .init(name: name, description: "Run on \(host)", annotations: .init(approval: .confirm)),
      call: .init(id: tool["toolCallId"]?.stringValue ?? UUID().uuidString, name: name, arguments: arguments))
    let decision = permitsUnattendedApproval(request) ? ApprovalDecision.approve(arguments: arguments)
      : try await interactiveDecision(request)
    if case .cancelRun = decision { throw CancellationError() }
    let kind: String
    switch decision {
    case .approve(let edited): kind = edited == arguments ? "allow" : "reject"
    default: kind = "reject"
    }
    let options = params.objectValue?["options"]?.arrayValue ?? []
    return (options.first { $0.objectValue?["kind"]?.stringValue == kind + "_once" }
      ?? options.first { $0.objectValue?["kind"]?.stringValue?.hasPrefix(kind) == true })?
      .objectValue?["optionId"]?.stringValue
  }

  /// Path asks are bypassed only after an explicit session yolo choice or a
  /// saved "always" answer that includes paths. Ordinary tool yolo is separate.
  func decidePromptPathAccess(
    _ url: URL, operation: String = "prompt", preparingTurn: Bool = true,
    forceConfirmation: Bool = false
  )
    async throws -> Bool
  {
    if permitsUnattendedPathAccess() || (!forceConfirmation && permitsUnattendedExecution()) {
      return true
    }
    let arguments: JSONValue = .object(["path": .string(url.path), "operation": .string(operation)])
    let request = ApprovalRequest(
      run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "path-access", depth: 0),
      tool: ToolDefinition(
        name: "files_path_access",
        description: preparingTurn
          ? "Grant the Files tools access to this prompt path for the CLI session; /path manages the grant."
          : "Allow \(operation) to access this path once under /path policy.",
        annotations: .init(readOnly: false, approval: .confirm)),
      call: ToolCall(id: UUID().uuidString, name: "files_path_access", arguments: arguments))
    // The REPL is synchronously preparing a turn here, so routing through its
    // normal approval event would wait for an event loop that is not running.
    let decision =
      try await (preparingTurn ? directTerminalDecision(request) : interactiveDecision(request))
    if case .approve(let approved) = decision { return approved == arguments }
    if case .cancelRun = decision { throw CancellationError() }
    return false
  }

  private func interactiveDecision(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    if let delegate { return try await delegate.decide(request) }
    if let prompter { return try await prompter(request) }
    return try directTerminalDecision(request)
  }

  private func directTerminalDecision(_ request: ApprovalRequest) throws -> ApprovalDecision {
    guard isatty(STDIN_FILENO) != 0 else {
      return .deny(reason: "Interactive approval requires a terminal.")
    }
    let screen = TerminalScreen.current
    func write(_ text: String) {
      if let screen { screen.write(text, to: .standardError) }
      else { FileHandle.standardError.write(Data(text.utf8)) }
    }
    write("Approve \(request.tool.annotations.approval.rawValue) tool '\(request.tool.name)'?\nArguments: \(request.call.arguments.compactJSONString)\n")
    write(REPLModalPrompt.approvalHelp(request) + "\n")
    let editor = TerminalLineEditor()
    editor.configure(
      ui: ConfiguredTerminalUI(backgroundLine: "", promptForeground: "yellow"))
    editor.install(surface: screen)
    let id = UUID()
    var editing = false
    defer { screen?.setStatus("") }
    while true {
      let modal = REPLModalPrompt.approval(request, id: id, editing: editing)
      screen?.setStatus(modal.status, attention: true, question: modal.question)
      editor.updatePrompt(modal.input)
      guard let raw = editor.readLine(
        prompt: modal.input.text, completions: [], rememberInput: false, tracksPromptUpdates: true)
      else { return .deny(reason: "No approval response.") }
      if editor.wasInterrupted { throw CancellationError() }
      if editing {
        if let data = raw.data(using: .utf8),
          let value = try? JSONDecoder().decode(JSONValue.self, from: data), value.objectValue != nil
        {
          return .approve(arguments: value)
        }
        write("Enter a valid JSON object, or Ctrl+C to cancel.\n")
        continue
      }
      switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "y", "yes": return .approve(arguments: request.call.arguments)
      case "a", "always":
        try saveApprovalMode(.yolo, includingPaths: true)
        write("Yolo enabled for tools and path approvals (saved for this project).\n")
        return .approve(arguments: request.call.arguments)
      case "s", "session":
        setApprovalMode(.yolo)
        write("Yolo enabled for this session, including path approvals; settings were not saved.\n")
        return .approve(arguments: request.call.arguments)
      case let answer where ["t", "tool", "tool-specific-yolo"].contains(answer)
        && request.tool.name != "files_path_access":
        try saveToolYolo(request.tool.name)
        write("Yolo enabled for \(request.tool.name) only (saved for this project); path approvals still apply.\n")
        return .approve(arguments: request.call.arguments)
      case "e" where request.tool.name != "files_path_access",
        "edit" where request.tool.name != "files_path_access":
        editing = true
      case "n", "no": return .deny(reason: "Denied by user.")
      case "c", "cancel": return .cancelRun
      default: write("Answer \(modal.input.choices.joined(separator: "/")).\n")
      }
    }
  }
}
