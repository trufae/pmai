import Foundation
import MaiACP
import MaiCore
import MaiLocalProviders
import MaiMCP
import MaiOpenAI
import MaiPluginHost
import MaiStandardTools
import MaiVoice

public struct RemoteHostingRequest: Sendable, Identifiable {
  public let id: String
  public let name: String
  public let kind: String
  public let source: String
}

public struct RemoteHostingClient: Sendable, Identifiable {
  public let id: String
  public let name: String
  public let kind: String
  public let connections: Int
}

public struct RemoteHostingSnapshot: Sendable {
  public var running = false
  public var status = "Remote server is stopped."
  public var endpoint: String?
  public var pairingURI: String?
  public var pairingExpiresAt: Date?
  public var bearerToken: String?
  public var requests: [RemoteHostingRequest] = []
  public var clients: [RemoteHostingClient] = []
  public var failure: String?

  public init() {}

  init(running: Bool, status: String, endpoint: String?, pairingURI: String?, pairingExpiresAt: Date?,
    bearerToken: String?, requests: [RemoteHostingRequest], clients: [RemoteHostingClient], failure: String?) {
    self.running = running
    self.status = status
    self.endpoint = endpoint
    self.pairingURI = pairingURI
    self.pairingExpiresAt = pairingExpiresAt
    self.bearerToken = bearerToken
    self.requests = requests
    self.clients = clients
    self.failure = failure
  }
}

/// App-facing access to the CLI's hosting lifecycle and durable pairing state.
/// ACP workers use the app's executable in --acp mode, just like local chats.
public actor RemoteHosting {
  private let home: AgentHome
  private let server: RemoteREPLServer
  private var startup: Task<Void, Error>?
  private var starting = false
  private var stopping = false
  private var generation = 0
  private var runtime: AgentRuntime?
  private var nativePlugins: NativePluginHost?
  private var mcpIDs: [String] = []

  public init(home: AgentHome, executable: String) {
    self.home = home
    server = RemoteREPLServer(home: home, executable: executable)
  }

  public func start(arguments: [String], workingDirectory: URL, configurationURL: URL?,
    approvalHandler: any ApprovalHandler = DenyInteractiveApprovals()) async throws {
    guard !starting, !stopping else {
      throw JSONRPCError.invalidParams("A server operation is already in progress.")
    }
    starting = true
    let attempt = generation
    defer { starting = false }
    guard !(try await server.snapshot()).running else {
      throw JSONRPCError.invalidParams("Stop the running server before changing its settings.")
    }
    try Task.checkCancellation()
    guard !stopping, generation == attempt else { throw CancellationError() }
    let task = Task {
      do {
        try await launch(arguments: arguments, cwd: workingDirectory, configurationURL: configurationURL,
          approvalHandler: approvalHandler)
      } catch {
        await server.stop()
        await releaseRuntime()
        throw error
      }
    }
    startup = task
    defer { startup = nil }
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: { task.cancel() }
  }

  private func launch(arguments: [String], cwd: URL, configurationURL: URL?,
    approvalHandler: any ApprovalHandler) async throws {
    await releaseRuntime()
    let environment = ProcessInfo.processInfo.environment
    let options = try CLIOptions(arguments: [], environment: environment)
    var configuration = try configurationURL.map { try MaiConfiguration.load(from: $0) }
      ?? MaiCLI.initialConfiguration()
    guard !configuration.airplane else {
      throw JSONRPCError.invalidParams("Disable Airplane Mode in this configuration before starting a server.")
    }
    let agent = try MaiCLI.selectedProfile(configuration: configuration, options: options,
      environment: environment).agentDefinition
    if let index = arguments.firstIndex(of: "--protocol"),
      index + 1 < arguments.count, arguments[index + 1] == "openai" {
      let http = try OpenAIRemoteOptions(arguments)
      let project = try home.openProject(atWorkingDirectory: cwd)
      let approvals = try TerminalApprovalHandler(configuration: configuration.approvals,
        projectSettingsURL: home.storageDirectory(for: project).appendingPathComponent("settings.json"))
      await approvals.setDelegate(approvalHandler)
      let runtime = AgentRuntime(approvalHandler: approvals)
      self.runtime = runtime
      let plugins = PluginRegistry()
      try await plugins.install(MaiCoreBuiltinsPlugin(), origin: "built-in")
      try await plugins.install(MaiVoicePlugin(), origin: "built-in")
      try await plugins.install(MaiOpenAIPlugin(credentialsDirectory: home.rootURL.appendingPathComponent("chatgpt")), origin: "built-in")
      try await plugins.install(MaiLocalProvidersPlugin(), origin: "built-in")
      try await plugins.install(MaiACPPlugin(onPermission: { params, host in
        try await approvals.decideRemote(params, host: host)
      }), origin: "built-in")
      let native = NativePluginHost()
      nativePlugins = native
      try await MaiCLI.loadNativePlugins(options: options, loadedConfigurationPath: configurationURL?.path,
        configuration: configuration, environment: environment, host: native, registry: plugins)
      if http.allowTools {
        try await plugins.install(MaiMCPPlugin(), origin: "built-in")
        let files = PromptFileAccess(approvalHandler: approvals, settings: configuration.fileAccess ?? .init(),
          environment: environment, home: home)
        try await plugins.install(MaiStandardToolsPlugin(configureFiles: { value in
          var value = value
          value.projectHomeURL = self.home.rootURL
          value.pathAccessPolicy = files.policy
          return value
        }), origin: "built-in")
        try await MaiCLI.registerTools(in: runtime, plugins: plugins, configuration: configuration, environment: environment)
        try await MaiCLI.registerMemoryTools(in: runtime, state: MemoryState(home: home))
        try await MaiCLI.registerTodoTools(in: runtime, state: TodoState(home: home))
        try await MaiCLI.registerSkillTools(in: runtime, state: SkillState(home: home))
        try await runtime.register(tools: MaiContextTools.makeTools(supervisor: runtime.supervisor))
        let hosts = ACPRemoteHostStore(directory: home.rootURL.appendingPathComponent("remotes"))
        let remoteTools = RemoteWorkspaceTools {
          try hosts.hosts().filter { $0.agentAccess == true }.map {
            RemoteWorkspaceHost(id: $0.id.uuidString.lowercased(), connection: try hosts.connection(for: $0))
          }
        }
        try await runtime.register(tools: remoteTools.tools())
        mcpIDs = configuration.mcpServers.filter(\.enabled).map(\.id)
      } else {
        configuration.mcpServers = []
        configuration.toolsEnabled = false
      }
      _ = try await MaiCLI.configureRuntime(runtime, plugins: plugins, configuration: configuration,
        options: options, selectedProvider: agent.provider, resumingChat: false, environment: environment,
        startup: CLIStartupTiming(started: .now, environment: environment))
      if !(await runtime.availableAgents(includingDisabled: true)).contains(where: { $0.id == agent.id }) {
        try await runtime.register(agent: agent)
      }
    }
    try Task.checkCancellation()
    try await AgentExecutionScope.$current.withValue(.init(sessionID: UUID().uuidString, workingDirectory: cwd)) {
      try await server.start(arguments, configuration: configuration, agent: agent, runtime: runtime, cwd: cwd)
    }
    try Task.checkCancellation()
  }

  public func snapshot() async throws -> RemoteHostingSnapshot { try await server.snapshot() }
  public func renewPairing() async throws { try await server.renewPairing() }
  @discardableResult public func resolvePairing(_ id: String, allow: Bool) async throws -> String {
    try await server.resolvePairing(id, allow: allow)
  }
  public func revokeClient(_ id: String) async throws { try await server.revokeClient(id) }

  public func stop() async {
    generation += 1
    stopping = true
    let task = startup
    task?.cancel()
    await server.stop()
    _ = try? await task?.value
    await server.stop()
    await releaseRuntime()
    stopping = false
  }

  private func releaseRuntime() async {
    let previous = runtime
    let ids = mcpIDs
    let plugins = nativePlugins
    mcpIDs = []
    runtime = nil
    nativePlugins = nil
    if let previous { for id in ids { await previous.unregisterMCP(serverID: id) } }
    withExtendedLifetime(plugins) {}
  }
}
