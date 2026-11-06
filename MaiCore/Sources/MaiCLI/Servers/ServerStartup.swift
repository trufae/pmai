import Foundation
import MaiCore
import MaiACP
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
  /// Runs pmai as a stdio server instead of the REPL: ACP for editors, MCP for
  /// tool callers. Both speak JSON-RPC over stdin/stdout, so no output may go
  /// there but the protocol itself; diagnostics go to stderr.
  static func runServer(
    _ mode: ServeMode,
    runtime: AgentRuntime,
    approvalHandler: TerminalApprovalHandler,
    agent: AgentDefinition,
    configuration: MaiConfiguration?,
    options: CLIOptions,
    environment: [String: String]
  ) async throws {
    let transport = StdioJSONRPCTransport.standardIO()
    switch mode {
    case .acp:
      // Tool approvals belong to the editor, not to a terminal nobody is at.
      let bridge = ACPPermissionBridge()
      await approvalHandler.setDelegate(bridge.approvalHandler)
      var directory = options.acpSessionDirectory.map {
        URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true)
      } ?? resolvedHome(options: options, environment: environment).rootURL
        .appendingPathComponent("acp", isDirectory: true)
      directory.appendPathComponent(ACPStateFiles.component(agent.id), isDirectory: true)
      var root = options.acpRoot.map {
        URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true)
      }
      var authorize: @Sendable () throws -> Void = {}
      var extensionHandler: @Sendable (String, JSONValue?) throws -> JSONValue? = { _, _ in nil }
      if let path = options.tailcatGateway {
        let store = TailcatStore(directory: URL(fileURLWithPath: path, isDirectory: true))
        guard let worker = try store.read().worker,
          let key = environment["TAILCAT_PEER_KEY"], TailcatStore.validNodeKey(key) else {
          throw TailcatCLI.Error.message("Tailcat gateway requires an authenticated Tailcat peer")
        }
        root = URL(fileURLWithPath: worker.workspace, isDirectory: true)
        directory.appendPathComponent(ACPStateFiles.component(key), isDirectory: true)
        authorize = { _ = try store.authorize(key) }
        extensionHandler = { method, params in
          if method == "_pmai/enroll" {
            guard let fields = params?.objectValue,
              let token = fields["token"]?.stringValue, let name = fields["name"]?.stringValue else {
              throw JSONRPCError.invalidParams("token and name are required")
            }
            let registered = try store.enroll(token: token, nodeKey: key, name: name)
            return .object(["workerID": .string(registered.id), "workspace": .string(registered.workspace)])
          }
          if method == "_pmai/status" {
            _ = try store.authorize(key)
            return .object([
              "workerID": .string(worker.id), "name": .string(worker.name),
              "workspace": .string(worker.workspace), "agent": .string(agent.id),
              "tools": .array(agent.toolNames.sorted().map(JSONValue.string)),
              "loadSession": .bool(true), "time": .number(Date().timeIntervalSince1970),
            ])
          }
          _ = try store.authorize(key)
          try store.audit(method, nodeKey: key)
          return nil
        }
      }
      let source = configuration?.toolSources.first {
        $0.enabled && $0.kind == MaiStandardToolsPlugin.factoryKind
      }
      var files = MaiStandardToolFactory.fileWorkspaceConfiguration(
        context: source?.context(environment: environment)
          ?? PluginFactoryContext(id: "standard-tools", environment: environment))
      let access = configuration?.fileAccess ?? .init()
      // Direct browsing has no agent session to request a tool approval in.
      // Ask rules remain inaccessible until the host explicitly allows them.
      let policy = MaiFileAccessPolicy(
        hidden: access.hidden, sensitive: access.sensitive, symlinks: access.symlinks,
        defaultAllowedURLs: ConfiguredFileAccess.defaultAllowedPaths.map { URL(fileURLWithPath: $0) }
      ) { _, _ in false }
      for rule in access.rules {
        policy.set(
          .init(
            url: URL(
              fileURLWithPath: AgentHome.expandUserPath(rule.path, environment: environment)),
            access: rule.access, descendants: rule.descendants))
      }
      files.pathAccessPolicy = policy
      let home = resolvedHome(options: options, environment: environment)
      files.projectHomeURL = home.rootURL
      let server = ACPServer(runtime: runtime, agent: agent, bridge: bridge,
        sessionDirectory: directory, workspaceRoot: root,
        workspaceRoots: options.tailcatGateway == nil && !options.acpPaths.isEmpty
          ? options.acpPaths.map { URL(fileURLWithPath: AgentHome.expandUserPath($0), isDirectory: true) } : nil,
        workspace: AgentHomeACPWorkspace(home: resolvedHome(options: options, environment: environment)),
        fileConfiguration: files,
        promptCatalog: { cwd in
          let project = try? home.loadProject(atWorkingDirectory: cwd)
          let skills = AgentSkillCatalog.load(directories: [
            project.map { home.skillsURL(for: $0) }
              ?? cwd.appendingPathComponent(".pmai/skills", isDirectory: true),
            home.skillsDirectoryURL,
          ]).skills
          return configuration?.promptCatalog(skills: skills) ?? PromptCatalog(skills: skills)
        },
        authorize: authorize,
        terminalIdleTimeout: {
          let file = home.rootURL.appendingPathComponent("remote-server/terminal-timeout.json")
          return Double((try? JSONDecoder().decode(Int.self, from: Data(contentsOf: file)))
            ?? configuration?.remoteTerminalTimeoutSeconds ?? 0)
        }, extensionHandler: extensionHandler)
      FileHandle.standardError.write(
        Data("pmai ACP agent ready (\(agent.id)); waiting for a client on stdio.\n".utf8))
      await server.serve(on: transport)
    case .mcp:
      let server = MCPAgentServer(runtime: runtime, agent: agent)
      FileHandle.standardError.write(
        Data("pmai MCP server ready (\(agent.id)); waiting for a client on stdio.\n".utf8))
      await server.serve(on: transport)
    }
  }
}
