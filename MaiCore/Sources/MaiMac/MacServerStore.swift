import AppKit
import MaiACP
import MaiCLI
import MaiCore
import Observation

@MainActor @Observable
final class MacServerStore: ApprovalHandler {
  struct Permission: Identifiable {
    let id: UUID
    let request: ApprovalRequest
    let reply: CheckedContinuation<ApprovalDecision, Error>
  }

  var snapshot = RemoteHostingSnapshot()
  var busy = false
  var error: String?
  var notice: String?
  var permissions: [Permission] = []
  var protocolName = "forwiroh"
  var port = "19283"
  var name = ProcessInfo.processInfo.hostName
  var workingDirectory = AgentHome.userHomeDirectory().path
  var shareAll = true
  var paths: [String] = []
  var bindAddress = "127.0.0.1"
  var advertisedAddress = ""
  var publicURL = ""
  var loopback = false
  var allowTools = false
  private let home: AgentHome
  private var service: RemoteHosting
  private var operation: Task<Void, Never>?
  private var monitor: Task<Void, Never>?
  private var prepared = false
  private var operationID = UUID()

  init(home: AgentHome) {
    self.home = home
    service = RemoteHosting(home: home, executable: "pmai")
  }

  var attentionCount: Int { snapshot.requests.count + permissions.count }
  var configurationURL: URL? {
    let local = URL(fileURLWithPath: AgentHome.expandUserPath(workingDirectory)).appendingPathComponent("pmai.json")
    let global = home.configurationFileURL()
    return [local, global].first { FileManager.default.fileExists(atPath: $0.path) }
  }

  func prepare(cwd: String?) {
    guard !prepared else { return }
    prepared = true
    if let cwd, !cwd.isEmpty { workingDirectory = cwd }
    Task { await refresh() }
  }

  func start() {
    guard !snapshot.running else { return }
    perform { [self] in
      guard let port = Int(self.port), (1...65535).contains(port) else {
        throw JSONRPCError.invalidParams("Port must be between 1 and 65535.")
      }
      let cwd = URL(fileURLWithPath: AgentHome.expandUserPath(self.workingDirectory), isDirectory: true)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw JSONRPCError.invalidParams("Choose an existing working directory.")
      }
      if self.protocolName != "openai" {
        let executable = try MacCLI.executable(environment: MacCLI.environment, workingDirectory: cwd)
        await self.service.stop()
        try Task.checkCancellation()
        self.service = RemoteHosting(home: self.home, executable: executable)
      }
      var arguments = ["--protocol", self.protocolName, "--port", String(port)]
      if self.protocolName == "openai" {
        arguments += ["--bind", self.bindAddress.trimmingCharacters(in: .whitespacesAndNewlines)]
        if self.allowTools { arguments.append("--tools") }
      } else {
        arguments += ["--name", self.name]
        if !self.shareAll {
          guard !self.paths.isEmpty else { throw JSONRPCError.invalidParams("Choose at least one folder to share.") }
          arguments += ["--path"] + self.paths
        }
        if self.protocolName == "local" {
          if self.loopback { arguments.append("--loopback") }
          if !self.advertisedAddress.isEmpty { arguments += ["--address", self.advertisedAddress] }
        }
        if self.protocolName == "opentunnel", !self.publicURL.isEmpty { arguments += ["--url", self.publicURL] }
      }
      try await self.service.start(arguments: arguments, workingDirectory: cwd,
        configurationURL: self.configurationURL, approvalHandler: self)
      try Task.checkCancellation()
      self.monitor?.cancel()
      self.monitor = Task { [weak self] in
        while !Task.isCancelled {
          await self?.refresh()
          do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
      }
    }
  }

  func stop() {
    operation?.cancel()
    operationID = UUID()
    let id = operationID
    busy = true
    cancelPermissions()
    // stop() also cancels and joins a start still opening its listener/tunnel.
    operation = Task {
      await service.stop()
      monitor?.cancel()
      monitor = nil
      await refresh()
      if operationID == id { busy = false }
      notice = "Server stopped."
    }
  }

  func refresh() async {
    do { snapshot = try await service.snapshot() }
    catch is CancellationError {}
    catch { self.error = error.localizedDescription }
  }

  func renewPairing() { perform { try await self.service.renewPairing() } }
  func resolve(_ id: String, allow: Bool) {
    perform { self.notice = try await self.service.resolvePairing(id, allow: allow) }
  }
  func revoke(_ id: String) { perform { try await self.service.revokeClient(id) } }

  private func perform(_ action: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true
    error = nil
    notice = nil
    operationID = UUID()
    let id = operationID
    operation = Task {
      defer { if operationID == id { busy = false } }
      do { try await action() }
      catch is CancellationError {}
      catch { self.error = error.localizedDescription }
      await refresh()
    }
  }

  func toolApprovalMode() async -> ToolApprovalMode? { .ask }

  func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { reply in
        if Task.isCancelled { reply.resume(throwing: CancellationError()); return }
        permissions.append(.init(id: id, request: request, reply: reply))
      }
    } onCancel: {
      Task { @MainActor in self.answer(id, allow: false) }
    }
  }

  func answer(_ id: UUID, allow: Bool) {
    guard let index = permissions.firstIndex(where: { $0.id == id }) else { return }
    let permission = permissions.remove(at: index)
    permission.reply.resume(returning: allow ? .approve(arguments: permission.request.call.arguments)
      : .deny(reason: "Denied by the Mac server operator."))
  }

  private func cancelPermissions() {
    for permission in permissions { permission.reply.resume(throwing: CancellationError()) }
    permissions = []
  }

  func close() async {
    operation?.cancel()
    monitor?.cancel()
    cancelPermissions()
    await service.stop()
    await operation?.value
  }
}
