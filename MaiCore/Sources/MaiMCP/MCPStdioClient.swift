#if !os(iOS)
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

  /// An MCP tool source backed by a local subprocess using newline-delimited JSON-RPC.
  public actor MCPStdioClient: MCPToolSource {
    public nonisolated let requiresInternet = false
    public let configuration: MCPStdioServerConfiguration
    private let transport: MCPStdioTransport
    private var catalog: MCPServerCatalog?

    public init(configuration: MCPStdioServerConfiguration) {
      self.configuration = configuration
      self.transport = MCPStdioTransport(configuration: configuration)
    }

    public func connect() async throws -> MCPServerCatalog {
      if let catalog { return catalog }
      do {
        return try await establishConnection()
      } catch {
        await transport.close()
        throw error
      }
    }

    private func establishConnection() async throws -> MCPServerCatalog {
      let initialized = try await transport.sendResult(
        method: "initialize",
        params: [
          "protocolVersion": .string("2025-11-25"),
          "capabilities": .object([:]),
          "clientInfo": .object([
            "name": .string("MaiCore"),
            "version": .string("0.1"),
          ]),
        ])
      try await transport.sendNotification(method: "notifications/initialized")

      var firstError: Error?
      let tools: [ToolDefinition]
      do {
        tools = try await fetchTools()
      } catch {
        if Self.isMethodNotFound(error) {
          tools = []
        } else {
          firstError = error
          tools = []
        }
      }
      let resources: [MCPResourceDescriptor]
      do {
        resources = try await fetchResources()
      } catch {
        if Self.isMethodNotFound(error) {
          resources = []
        } else {
          firstError = firstError ?? error
          resources = []
        }
      }
      if tools.isEmpty, resources.isEmpty, let firstError { throw firstError }

      let result = initialized.objectValue ?? [:]
      let serverInfo = result["serverInfo"]?.objectValue ?? [:]
      let title = serverInfo["title"]?.stringValue?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      let name = serverInfo["name"]?.stringValue?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      let value = MCPServerCatalog(
        serverID: configuration.id,
        serverName: title?.isEmpty == false ? title : name,
        protocolVersion: result["protocolVersion"]?.stringValue ?? "2025-11-25",
        tools: tools.map(canonicalDefinition),
        resources: resources)
      catalog = value
      return value
    }

    public func agentTools() async throws -> [any AgentTool] {
      let catalog = try await connect()
      var tools: [any AgentTool] = catalog.tools.map { definition in
        MCPStdioRemoteTool(
          definition: definition,
          remoteName: remoteName(for: definition.name),
          client: self)
      }
      if !catalog.resources.isEmpty {
        tools.append(
          MCPStdioResourceReadTool(
            definition: ToolDefinition(
              name: "\(namespace)::resources_read",
              description: "Read one resource exposed by \(configuration.displayName).",
              inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                  "uri": .object([
                    "type": .string("string"),
                    "enum": .array(catalog.resources.map { .string($0.uri) }),
                  ])
                ]),
                "required": .array([.string("uri")]),
                "additionalProperties": .bool(false),
              ]),
              annotations: ToolAnnotations(
                readOnly: true,
                idempotent: true,
                openWorld: true,
                approval: configuration.defaultApproval)),
            client: self))
      }
      return tools
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> ToolOutput {
      let result = try await transport.sendResult(
        method: "tools/call",
        params: ["name": .string(remoteName(for: name)), "arguments": arguments])
      let content = try (result.objectValue?["content"]?.arrayValue ?? []).map(Self.mcpContent)
      return ToolOutput(
        content: content.isEmpty ? [.text("(no output)")] : content,
        structuredContent: result.objectValue?["structuredContent"],
        isError: result.objectValue?["isError"]?.boolValue ?? false)
    }

    public func readResource(uri: String) async throws -> [ContentPart] {
      let result = try await transport.sendResult(
        method: "resources/read",
        params: ["uri": .string(uri)])
      let content = try (result.objectValue?["contents"]?.arrayValue ?? []).map(Self.mcpContent)
      return content.isEmpty ? [.text("(empty resource)")] : content
    }

    public func close() async {
      catalog = nil
      await transport.close()
    }

    private func fetchTools() async throws -> [ToolDefinition] {
      var definitions: [ToolDefinition] = []
      var cursor: String?
      repeat {
        let params = cursor.map { ["cursor": JSONValue.string($0)] }
        let result = try await transport.sendResult(method: "tools/list", params: params)
        for value in result.objectValue?["tools"]?.arrayValue ?? [] {
          guard let tool = value.objectValue,
            let name = tool["name"]?.stringValue,
            !name.isEmpty
          else { continue }
          let annotations = tool["annotations"]?.objectValue ?? [:]
          let destructive = annotations["destructiveHint"]?.boolValue ?? false
          definitions.append(
            ToolDefinition(
              name: name,
              description: tool["description"]?.stringValue ?? "",
              inputSchema: tool["inputSchema"] ?? .object(["type": .string("object")]),
              annotations: ToolAnnotations(
                title: annotations["title"]?.stringValue,
                readOnly: annotations["readOnlyHint"]?.boolValue ?? false,
                destructive: destructive,
                idempotent: annotations["idempotentHint"]?.boolValue ?? false,
                openWorld: annotations["openWorldHint"]?.boolValue ?? true,
                approval: destructive ? .dangerous : configuration.defaultApproval,
                requiresInternet: annotations["requiresInternet"]?.boolValue ?? false)))
        }
        cursor = result.objectValue?["nextCursor"]?.stringValue
      } while cursor?.isEmpty == false
      return definitions
    }

    private func fetchResources() async throws -> [MCPResourceDescriptor] {
      var resources: [MCPResourceDescriptor] = []
      var cursor: String?
      repeat {
        let params = cursor.map { ["cursor": JSONValue.string($0)] }
        let result = try await transport.sendResult(method: "resources/list", params: params)
        for value in result.objectValue?["resources"]?.arrayValue ?? [] {
          guard let resource = value.objectValue,
            let uri = resource["uri"]?.stringValue,
            !uri.isEmpty
          else { continue }
          resources.append(
            MCPResourceDescriptor(
              uri: uri,
              name: resource["name"]?.stringValue ?? "",
              description: resource["description"]?.stringValue ?? "",
              mimeType: resource["mimeType"]?.stringValue))
        }
        cursor = result.objectValue?["nextCursor"]?.stringValue
      } while cursor?.isEmpty == false
      return resources
    }

    private var namespace: String {
      let prefix = configuration.toolNamePrefix?.trimmingCharacters(in: .whitespacesAndNewlines)
      return prefix.flatMap { $0.isEmpty ? nil : $0 } ?? configuration.id
    }

    private func canonicalDefinition(_ definition: ToolDefinition) -> ToolDefinition {
      var definition = definition
      definition.name = "\(namespace)::\(definition.name)"
      return definition
    }

    private func remoteName(for canonicalName: String) -> String {
      guard let separator = canonicalName.range(of: "::") else { return canonicalName }
      return String(canonicalName[separator.upperBound...])
    }

    private static func isMethodNotFound(_ error: Error) -> Bool {
      if case MCPClientError.rpcError(let code, _) = error { return code == -32601 }
      return error.localizedDescription.localizedCaseInsensitiveContains("method not found")
    }

    private static func mcpContent(_ value: JSONValue) throws -> ContentPart {
      guard let object = value.objectValue else { return .text(value.compactJSONString) }
      switch object["type"]?.stringValue {
      case "text":
        return .text(object["text"]?.stringValue ?? "")
      case "image":
        guard let raw = object["data"]?.stringValue, let data = Data(base64Encoded: raw) else {
          throw MCPClientError.invalidResponse("MCP image content has invalid base64 data.")
        }
        return .image(
          ImageContent(
            source: .data(data),
            mimeType: object["mimeType"]?.stringValue ?? "application/octet-stream"))
      case "audio":
        guard let raw = object["data"]?.stringValue, let data = Data(base64Encoded: raw) else {
          throw MCPClientError.invalidResponse("MCP audio content has invalid base64 data.")
        }
        return .audio(
          AudioContent(
            source: .data(data),
            mimeType: object["mimeType"]?.stringValue ?? "application/octet-stream"))
      case "resource", "resource_link":
        let resource = object["resource"]?.objectValue ?? object
        return .resource(
          ResourceContent(
            uri: resource["uri"]?.stringValue ?? "",
            name: resource["name"]?.stringValue,
            mimeType: resource["mimeType"]?.stringValue,
            text: resource["text"]?.stringValue,
            blob: resource["blob"]?.stringValue.flatMap { Data(base64Encoded: $0) }))
      default:
        return .text(value.compactJSONString)
      }
    }
  }

  private struct MCPStdioRemoteTool: AgentTool {
    let definition: ToolDefinition
    let remoteName: String
    let client: MCPStdioClient

    func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
      try await client.callTool(name: remoteName, arguments: arguments)
    }
  }

  private struct MCPStdioResourceReadTool: AgentTool {
    let definition: ToolDefinition
    let client: MCPStdioClient

    func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
      guard let uri = arguments.objectValue?["uri"]?.stringValue else {
        return ToolOutput(text: "Missing resource URI.", isError: true)
      }
      return ToolOutput(content: try await client.readResource(uri: uri))
    }
  }

  private actor MCPStdioTransport {
    private static let maximumMessageSize = 16 * 1_024 * 1_024

    private let configuration: MCPStdioServerConfiguration
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var nextRequestID = 1
    private var generation = 0
    private var failure: Error?

    init(configuration: MCPStdioServerConfiguration) {
      self.configuration = configuration
    }

    func sendResult(method: String, params: [String: JSONValue]? = nil) async throws -> JSONValue {
      try Task.checkCancellation()
      try startIfNeeded()
      if let failure { throw failure }
      let id = nextRequestID
      nextRequestID += 1
      var object: [String: JSONValue] = [
        "jsonrpc": .string("2.0"),
        "id": .integer(id),
        "method": .string(method),
      ]
      if let params { object["params"] = .object(params) }

      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          pending[id] = continuation
          do {
            try write(.object(object))
          } catch {
            finish(id: id, result: .failure(error))
            return
          }
          let timeout = configuration.timeout
          timeouts[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.requestTimedOut(id: id, method: method)
          }
        }
      } onCancel: {
        Task { [weak self] in await self?.cancelRequest(id: id) }
      }
    }

    func sendNotification(method: String, params: [String: JSONValue]? = nil) throws {
      try startIfNeeded()
      if let failure { throw failure }
      var object: [String: JSONValue] = [
        "jsonrpc": .string("2.0"),
        "method": .string(method),
      ]
      if let params { object["params"] = .object(params) }
      try write(.object(object))
    }

    func close() {
      generation += 1
      let oldProcess = process
      process = nil
      try? inputHandle?.close()
      if oldProcess?.isRunning == true { oldProcess?.terminate() }
      outputHandle?.readabilityHandler = nil
      errorHandle?.readabilityHandler = nil
      try? outputHandle?.close()
      try? errorHandle?.close()
      inputHandle = nil
      outputHandle = nil
      errorHandle = nil
      outputBuffer.removeAll(keepingCapacity: false)
      errorBuffer.removeAll(keepingCapacity: false)
      failure = nil
      nextRequestID = 1
      failPending(with: CancellationError())
    }

    private func startIfNeeded() throws {
      if process?.isRunning == true { return }
      let child = Process()
      let input = Pipe()
      let output = Pipe()
      let errors = Pipe()
      let command = NSString(string: configuration.command).expandingTildeInPath
      if command.contains("/") {
        let base =
          configuration.workingDirectory
          ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        child.executableURL = URL(fileURLWithPath: command, relativeTo: base).standardizedFileURL
        child.arguments = configuration.args
      } else {
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = [command] + configuration.args
      }
      child.environment = configuration.environment
      child.currentDirectoryURL = configuration.workingDirectory
      child.standardInput = input
      child.standardOutput = output
      child.standardError = errors

      generation += 1
      let currentGeneration = generation
      child.terminationHandler = { [weak self] terminated in
        let status = terminated.terminationStatus
        Task { await self?.processTerminated(status: status, generation: currentGeneration) }
      }
      let stdout = output.fileHandleForReading
      stdout.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        if data.isEmpty { handle.readabilityHandler = nil }
        Task {
          if data.isEmpty {
            await self?.outputClosed(generation: currentGeneration)
          } else {
            await self?.receivedOutput(data, generation: currentGeneration)
          }
        }
      }
      let stderr = errors.fileHandleForReading
      stderr.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        if data.isEmpty { handle.readabilityHandler = nil }
        guard !data.isEmpty else { return }
        Task { await self?.receivedError(data, generation: currentGeneration) }
      }
      do {
        try child.run()
      } catch {
        stdout.readabilityHandler = nil
        stderr.readabilityHandler = nil
        throw MCPStdioTransportError.launchFailed(
          command: configuration.command,
          message: error.localizedDescription)
      }

      process = child
      inputHandle = input.fileHandleForWriting
      outputHandle = output.fileHandleForReading
      errorHandle = errors.fileHandleForReading
      #if os(macOS)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
      #elseif os(Linux) || os(Android)
        signal(SIGPIPE, SIG_IGN)
      #endif
      outputBuffer.removeAll(keepingCapacity: false)
      errorBuffer.removeAll(keepingCapacity: false)
      failure = nil
    }

    private func write(_ value: JSONValue) throws {
      guard let inputHandle else { throw MCPStdioTransportError.closed }
      var data = try JSONEncoder().encode(value)
      data.append(0x0A)
      do {
        try inputHandle.write(contentsOf: data)
      } catch {
        throw MCPStdioTransportError.writeFailed(error.localizedDescription)
      }
    }

    private func receivedOutput(_ data: Data, generation: Int) {
      guard generation == self.generation, failure == nil else { return }
      outputBuffer.append(data)
      guard outputBuffer.count <= Self.maximumMessageSize else {
        fail(
          with: MCPStdioTransportError.invalidMessage("MCP stdio message exceeded 16 MB."),
          generation: generation)
        return
      }
      while let newline = outputBuffer.firstIndex(of: 0x0A) {
        var line = Data(outputBuffer[..<newline])
        outputBuffer.removeSubrange(...newline)
        if line.last == 0x0D { line.removeLast() }
        guard !line.isEmpty else { continue }
        consume(line, generation: generation)
        if failure != nil { return }
      }
    }

    private func consume(_ data: Data, generation: Int) {
      let envelope: JSONValue
      do {
        envelope = try JSONDecoder().decode(JSONValue.self, from: data)
      } catch {
        fail(
          with: MCPStdioTransportError.invalidMessage(
            "MCP server wrote non-JSON data to stdout."),
          generation: generation)
        return
      }
      guard let object = envelope.objectValue,
        object["jsonrpc"]?.stringValue == "2.0"
      else {
        fail(
          with: MCPStdioTransportError.invalidMessage("Invalid MCP JSON-RPC message."),
          generation: generation)
        return
      }

      if let method = object["method"]?.stringValue {
        guard let id = object["id"] else { return }
        var response: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": id]
        if method == "ping" {
          response["result"] = .object([:])
        } else {
          response["error"] = .object([
            "code": .integer(-32601),
            "message": .string("Method not supported by this client: \(method)"),
          ])
        }
        do {
          try write(.object(response))
        } catch {
          fail(with: error, generation: generation)
        }
        return
      }

      guard let id = object["id"]?.intValue, pending[id] != nil else { return }
      if let error = object["error"]?.objectValue {
        finish(
          id: id,
          result: .failure(
            MCPClientError.rpcError(
              code: error["code"]?.intValue,
              message: error["message"]?.stringValue ?? "Unknown MCP error.")))
      } else {
        finish(id: id, result: .success(object["result"] ?? .null))
      }
    }

    private func receivedError(_ data: Data, generation: Int) {
      guard generation == self.generation else { return }
      errorBuffer.append(data)
      if errorBuffer.count > 64 * 1_024 {
        errorBuffer.removeFirst(errorBuffer.count - 64 * 1_024)
      }
    }

    private func outputClosed(generation: Int) {
      guard generation == self.generation, failure == nil else { return }
      fail(with: MCPStdioTransportError.closed, generation: generation)
    }

    private func processTerminated(status: Int32, generation: Int) {
      guard generation == self.generation, failure == nil else { return }
      fail(
        with: MCPStdioTransportError.processExited(
          status: status,
          stderr: stderrSnippet),
        generation: generation)
    }

    private func requestTimedOut(id: Int, method: String) {
      guard pending[id] != nil else { return }
      finish(
        id: id,
        result: .failure(MCPStdioTransportError.timedOut(method: method, stderr: stderrSnippet)))
    }

    private func cancelRequest(id: Int) {
      guard pending[id] != nil else { return }
      finish(id: id, result: .failure(CancellationError()))
    }

    private func finish(id: Int, result: Result<JSONValue, Error>) {
      guard let continuation = pending.removeValue(forKey: id) else { return }
      timeouts.removeValue(forKey: id)?.cancel()
      continuation.resume(with: result)
    }

    private func fail(with error: Error, generation: Int) {
      guard generation == self.generation, failure == nil else { return }
      failure = error
      try? inputHandle?.close()
      if process?.isRunning == true { process?.terminate() }
      failPending(with: error)
    }

    private func failPending(with error: Error) {
      let continuations = pending.values
      pending.removeAll()
      for timeout in timeouts.values { timeout.cancel() }
      timeouts.removeAll()
      for continuation in continuations { continuation.resume(throwing: error) }
    }

    private var stderrSnippet: String {
      String(data: errorBuffer, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
  }

  public enum MCPStdioTransportError: LocalizedError, Equatable, Sendable {
    case launchFailed(command: String, message: String)
    case writeFailed(String)
    case processExited(status: Int32, stderr: String)
    case timedOut(method: String, stderr: String)
    case invalidMessage(String)
    case closed

    public var errorDescription: String? {
      switch self {
      case .launchFailed(let command, let message):
        "Unable to launch MCP command '\(command)': \(message)"
      case .writeFailed(let message):
        "Unable to write to the MCP process: \(message)"
      case .processExited(let status, let stderr):
        stderr.isEmpty
          ? "MCP process exited with status \(status)."
          : "MCP process exited with status \(status): \(stderr)"
      case .timedOut(let method, let stderr):
        stderr.isEmpty
          ? "MCP stdio request '\(method)' timed out."
          : "MCP stdio request '\(method)' timed out: \(stderr)"
      case .invalidMessage(let message):
        message
      case .closed:
        "The MCP stdio connection closed before returning a response."
      }
    }
  }

  public struct StdioMCPFactory: ConfiguredMCPToolSourceFactory {
    public let kind = "stdio"

    public init() {}

    public func makeMCPToolSource(
      from configuration: ConfiguredMCPServer,
      environment: [String: String]
    ) throws -> any MCPToolSource {
      MCPStdioClient(configuration: try configuration.resolvedStdio(environment: environment))
    }
  }
#endif
