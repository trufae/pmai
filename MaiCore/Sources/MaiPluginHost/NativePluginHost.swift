import CMaiPluginABI
import Foundation
import MaiCore
import MaiPluginSDK

#if os(Windows)
  import WinSDK
#elseif canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// Owns loaded dynamic libraries for the lifetime of their registered
/// factories and adapters. Native plugins are trusted in-process code.
public actor NativePluginHost {
  private var libraries: [NativePluginLibrary] = []

  public init() {}

  @discardableResult
  public func loadPlugin(
    at url: URL,
    into registry: PluginRegistry
  ) async throws -> InstalledPlugin {
    let library = try NativePluginLibrary(url: url)
    try await registry.install(
      NativeLoadedPlugin(library: library),
      origin: library.url.path)
    libraries.append(library)
    return try await installedPlugin(PluginID(library.manifest.plugin.id), in: registry)
  }

  public func loadedPluginURLs() -> [URL] { libraries.map(\.url) }

  private func installedPlugin(
    _ id: PluginID,
    in registry: PluginRegistry
  ) async throws -> InstalledPlugin {
    guard let plugin = await registry.installedPlugins().first(where: { $0.manifest.id == id })
    else {
      throw NativePluginHostError.registrationFailed(id.rawValue)
    }
    return plugin
  }
}

private final class NativePluginLibrary: @unchecked Sendable {
  let url: URL
  let manifest: NativePluginManifest

  #if os(Windows)
    static let libraryExtension = "dll"
  #else
    static let libraryExtension = "dylib"
  #endif

  private let handle: UnsafeMutableRawPointer
  private let api: mai_plugin_api_v1

  init(url: URL) throws {
    let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
    guard resolvedURL.pathExtension.lowercased() == Self.libraryExtension else {
      throw NativePluginHostError.invalidExtension(resolvedURL.path)
    }
    guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
      throw NativePluginHostError.notFound(resolvedURL.path)
    }
    guard let handle = Self.open(resolvedURL.path) else {
      throw NativePluginHostError.openFailed(
        path: resolvedURL.path,
        message: Self.dynamicLoaderError())
    }
    do {
      guard let symbol = Self.symbol(MAI_PLUGIN_ENTRY_SYMBOL_V1, in: handle) else {
        throw NativePluginHostError.entryPointMissing(MAI_PLUGIN_ENTRY_SYMBOL_V1)
      }
      typealias EntryPoint = @convention(c) () -> UnsafePointer<mai_plugin_api_v1>?
      let entryPoint = unsafeBitCast(symbol, to: EntryPoint.self)
      guard let pointer = entryPoint() else { throw NativePluginHostError.invalidEntryPoint }
      let api = pointer.pointee
      guard api.abi_version == MAI_PLUGIN_ABI_VERSION else {
        throw NativePluginHostError.unsupportedABIVersion(
          found: api.abi_version,
          supported: UInt32(MAI_PLUGIN_ABI_VERSION))
      }
      guard api.start != nil else { throw NativePluginHostError.invalidEntryPoint }
      guard let rawManifest = api.manifest_json else {
        throw NativePluginHostError.invalidManifest("The manifest pointer is null.")
      }
      let manifestData = Data(String(cString: rawManifest).utf8)
      guard manifestData.count <= 1_048_576 else {
        throw NativePluginHostError.invalidManifest("The manifest exceeds 1 MiB.")
      }
      let manifest: NativePluginManifest
      do {
        manifest = try JSONDecoder().decode(NativePluginManifest.self, from: manifestData)
      } catch {
        throw NativePluginHostError.invalidManifest(error.localizedDescription)
      }
      self.url = resolvedURL
      self.handle = handle
      self.api = api
      self.manifest = manifest
    } catch {
      Self.close(handle)
      throw error
    }
  }

  deinit {
    api.destroy?(api.plugin_context)
    Self.close(handle)
  }

  func invoke(
    _ request: NativePluginRequest,
    emit: (@Sendable (PluginJSONValue) async -> Void)? = nil
  ) async throws -> PluginJSONValue? {
    guard let start = api.start else { throw NativePluginHostError.invalidEntryPoint }
    let data = try JSONEncoder().encode(request)
    guard let requestJSON = String(data: data, encoding: .utf8) else {
      throw NativePluginHostError.invalidRequest
    }
    let state = NativeInvocationState(emit: emit)
    let responseJSON = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        state.install(continuation)
        let retainedState = Unmanaged.passRetained(state).toOpaque()
        let operationID = requestJSON.withCString { rawRequest in
          start(
            api.plugin_context,
            rawRequest,
            retainedState,
            nativePluginEmit,
            nativePluginComplete)
        }
        state.didStart(operationID: operationID) { [self] operationID in
          cancel(operationID: operationID)
        }
      }
    } onCancel: {
      state.cancel()
    }
    let response: NativePluginResponse
    do {
      response = try JSONDecoder().decode(
        NativePluginResponse.self,
        from: Data(responseJSON.utf8))
    } catch {
      throw NativePluginHostError.invalidResponse(error.localizedDescription)
    }
    if let error = response.error { throw error }
    return response.result
  }

  private func cancel(operationID: UInt64) {
    api.cancel?(api.plugin_context, operationID)
  }

  #if os(Windows)
    private static func open(_ path: String) -> UnsafeMutableRawPointer? {
      guard let module = path.withCString(encodedAs: UTF16.self, { LoadLibraryW($0) }) else {
        return nil
      }
      return UnsafeMutableRawPointer(module)
    }

    private static func symbol(
      _ name: String, in handle: UnsafeMutableRawPointer
    ) -> UnsafeMutableRawPointer? {
      guard let address = GetProcAddress(handle.assumingMemoryBound(to: HINSTANCE__.self), name)
      else {
        return nil
      }
      return unsafeBitCast(address, to: UnsafeMutableRawPointer.self)
    }

    private static func close(_ handle: UnsafeMutableRawPointer) {
      FreeLibrary(handle.assumingMemoryBound(to: HINSTANCE__.self))
    }

    private static func dynamicLoaderError() -> String {
      "Windows error \(GetLastError())."
    }
  #else
    private static func open(_ path: String) -> UnsafeMutableRawPointer? {
      dlopen(path, RTLD_NOW | RTLD_LOCAL)
    }

    private static func symbol(
      _ name: String, in handle: UnsafeMutableRawPointer
    ) -> UnsafeMutableRawPointer? {
      dlsym(handle, name)
    }

    private static func close(_ handle: UnsafeMutableRawPointer) {
      dlclose(handle)
    }

    private static func dynamicLoaderError() -> String {
      dlerror().map { String(cString: $0) } ?? "Unknown dynamic loader error."
    }
  #endif
}

private final class NativeInvocationState: @unchecked Sendable {
  private let lock = NSLock()
  private let emit: (@Sendable (PluginJSONValue) async -> Void)?
  private var continuation: CheckedContinuation<String, Error>?
  private var cancelOperation: (@Sendable (UInt64) -> Void)?
  private var operationID: UInt64?
  private var cancellationRequested = false
  private var completed = false

  init(emit: (@Sendable (PluginJSONValue) async -> Void)?) {
    self.emit = emit
  }

  func install(_ continuation: CheckedContinuation<String, Error>) {
    lock.lock()
    self.continuation = continuation
    lock.unlock()
  }

  func didStart(
    operationID: UInt64,
    cancel: @escaping @Sendable (UInt64) -> Void
  ) {
    lock.lock()
    self.operationID = operationID
    cancelOperation = cancel
    let shouldCancel = cancellationRequested && !completed
    lock.unlock()
    if shouldCancel { cancel(operationID) }
  }

  func receive(eventJSON: String) {
    guard let emit,
      let value = try? JSONDecoder().decode(PluginJSONValue.self, from: Data(eventJSON.utf8))
    else { return }
    Task { await emit(value) }
  }

  func complete(responseJSON: String) {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(returning: responseJSON)
  }

  func cancel() {
    lock.lock()
    cancellationRequested = true
    let operationID = operationID
    let cancelOperation = cancelOperation
    let shouldCancel = !completed
    lock.unlock()
    if shouldCancel, let operationID, let cancelOperation { cancelOperation(operationID) }
  }
}

private func nativePluginEmit(
  _ callbackContext: UnsafeMutableRawPointer?,
  _ eventJSON: UnsafePointer<CChar>?
) {
  guard let callbackContext, let eventJSON else { return }
  let state = Unmanaged<NativeInvocationState>.fromOpaque(callbackContext).takeUnretainedValue()
  state.receive(eventJSON: String(cString: eventJSON))
}

private func nativePluginComplete(
  _ callbackContext: UnsafeMutableRawPointer?,
  _ responseJSON: UnsafePointer<CChar>?
) {
  guard let callbackContext else { return }
  let state = Unmanaged<NativeInvocationState>.fromOpaque(callbackContext).takeRetainedValue()
  let response =
    responseJSON.map { String(cString: $0) }
    ?? "{\"error\":{\"code\":\"null-response\",\"message\":\"Plugin returned a null response.\"}}"
  state.complete(responseJSON: response)
}

private struct NativeLoadedPlugin: MaiPlugin {
  let library: NativePluginLibrary
  var manifest: PluginManifest {
    let native = library.manifest.plugin
    return PluginManifest(
      id: PluginID(native.id),
      displayName: native.displayName,
      version: native.version,
      apiVersion: native.apiVersion,
      capabilities: Set(native.capabilities.map { PluginCapability($0) }))
  }

  func register(in registry: PluginRegistry) async throws {
    for item in library.manifest.extensions(for: PluginCapability.chatProvider.rawValue) {
      try await registry.register(
        providerFactory: NativeProviderFactory(library: library, extension: item),
        from: manifest.id)
    }
    for item in library.manifest.extensions(for: PluginCapability.agentTool.rawValue) {
      try await registry.register(
        toolFactory: NativeToolFactory(library: library, extension: item),
        from: manifest.id)
    }
    for item in library.manifest.extensions(for: PluginCapability.ocrProvider.rawValue) {
      try await registry.register(
        ocrFactory: NativeOCRFactory(library: library, extension: item),
        from: manifest.id)
    }
    for item in library.manifest.extensions(for: PluginCapability.mcpToolSource.rawValue) {
      try await registry.register(
        mcpFactory: NativeMCPFactory(library: library, extension: item),
        from: manifest.id)
    }
  }
}

private struct NativeProviderFactory: ConfiguredProviderFactory {
  let library: NativePluginLibrary
  let `extension`: NativePluginExtension
  var kind: ConfiguredProviderKind { ConfiguredProviderKind(`extension`.kind) }

  func makeProvider(
    from configuration: ConfiguredProvider,
    environment: [String: String]
  ) throws -> any ChatProvider {
    NativeChatProvider(
      library: library,
      extension: `extension`,
      configuration: configuration,
      environment: environment)
  }
}

private struct NativeChatProvider: ChatProvider {
  let library: NativePluginLibrary
  let `extension`: NativePluginExtension
  let configuration: ConfiguredProvider
  let environment: [String: String]
  let descriptor: ProviderDescriptor

  init(
    library: NativePluginLibrary,
    extension: NativePluginExtension,
    configuration: ConfiguredProvider,
    environment: [String: String]
  ) {
    self.library = library
    self.extension = `extension`
    self.configuration = configuration
    self.environment = environment
    let capabilities =
      `extension`.metadata["capabilities"].flatMap {
        try? PluginWireCodec.decode(ProviderCapabilities.self, from: $0)
      } ?? []
    descriptor = ProviderDescriptor(
      id: ProviderID(configuration.id),
      displayName: configuration.displayName ?? library.manifest.plugin.displayName,
      capabilities: capabilities)
  }

  func availableModels() async throws -> [ModelDescriptor] {
    let result = try await library.invoke(
      NativePluginRequest(
        operation: NativePluginOperation.providerModels,
        kind: `extension`.kind,
        configuration: try providerConfiguration()))
    guard let result else { return [] }
    return try PluginWireCodec.decode([ModelDescriptor].self, from: result)
  }

  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    let result = try await library.invoke(
      NativePluginRequest(
        operation: NativePluginOperation.providerComplete,
        kind: `extension`.kind,
        configuration: try providerConfiguration(),
        payload: try PluginWireCodec.value(request))
    ) { value in
      guard let event = try? PluginWireCodec.decode(ProviderEvent.self, from: value) else {
        return
      }
      await emit(event)
    }
    guard let result else { throw NativePluginHostError.missingResult }
    return try PluginWireCodec.decode(ProviderResponse.self, from: result)
  }

  private func providerConfiguration() throws -> PluginJSONValue {
    try PluginWireCodec.value(
      NativeProviderConfiguration(configuration: configuration, environment: environment))
  }
}

private struct NativeProviderConfiguration: Codable {
  var configuration: ConfiguredProvider
  var environment: [String: String]
}

private struct NativeToolFactory: ConfiguredToolFactory {
  let library: NativePluginLibrary
  let `extension`: NativePluginExtension
  var kind: String { `extension`.kind }

  func makeTools(context: PluginFactoryContext) async throws -> [any AgentTool] {
    let result = try await library.invoke(
      NativePluginRequest(
        operation: NativePluginOperation.toolList,
        kind: kind,
        configuration: try PluginWireCodec.value(context)))
    guard let result else { return [] }
    let definitions = try PluginWireCodec.decode([ToolDefinition].self, from: result)
    return definitions.map {
      NativeAgentTool(library: library, kind: kind, context: context, definition: $0)
    }
  }

  func toolGroups(context: PluginFactoryContext) async throws -> [ToolGroupDefinition] {
    do {
      let result = try await library.invoke(
        NativePluginRequest(
          operation: NativePluginOperation.toolGroups,
          kind: kind,
          configuration: try PluginWireCodec.value(context)))
      guard let result else {
        return ToolGroupDefinition.inferred(from: try await makeTools(context: context))
      }
      let groups = try PluginWireCodec.decode([NativeToolGroupDefinition].self, from: result)
      return try groups.map { group in
        ToolGroupDefinition(
          id: group.id,
          displayName: group.displayName,
          description: group.description,
          toolNames: group.toolNames,
          options: try group.options.map { option in
            ToolGroupOptionDefinition(
              id: option.id,
              label: option.label,
              help: option.help,
              kind: ToolGroupOptionKind(rawValue: option.kind) ?? .text,
              defaultValue: try option.defaultValue.map {
                try PluginWireCodec.decode(JSONValue.self, from: $0)
              },
              choices: option.choices)
          })
      }
    } catch {
      // `tool.groups` is an optional wire operation added without changing the
      // C ABI. Prefix inference keeps older native plugins compatible.
      return ToolGroupDefinition.inferred(from: try await makeTools(context: context))
    }
  }
}

private struct NativeAgentTool: AgentTool {
  let library: NativePluginLibrary
  let kind: String
  let factoryContext: PluginFactoryContext
  let definition: ToolDefinition

  init(
    library: NativePluginLibrary,
    kind: String,
    context: PluginFactoryContext,
    definition: ToolDefinition
  ) {
    self.library = library
    self.kind = kind
    factoryContext = context
    self.definition = definition
  }

  func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
    let result = try await library.invoke(
      NativePluginRequest(
        operation: NativePluginOperation.toolCall,
        kind: kind,
        configuration: try PluginWireCodec.value(factoryContext),
        payload: try PluginWireCodec.value(
          NativeToolCall(name: definition.name, arguments: arguments, context: context))))
    guard let result else { throw NativePluginHostError.missingResult }
    return try PluginWireCodec.decode(ToolOutput.self, from: result)
  }
}

private struct NativeToolCall: Codable {
  var name: String
  var arguments: JSONValue
  var context: ToolExecutionContext
}

private struct NativeOCRFactory: ConfiguredOCRProviderFactory {
  let library: NativePluginLibrary
  let `extension`: NativePluginExtension
  var kind: String { `extension`.kind }

  func makeOCRProvider(context: PluginFactoryContext) throws -> any OCRProvider {
    NativeOCRProvider(library: library, kind: kind, context: context)
  }
}

private struct NativeOCRProvider: OCRProvider {
  let library: NativePluginLibrary
  let kind: String
  let context: PluginFactoryContext
  var descriptor: OCRProviderDescriptor {
    .init(id: context.id, displayName: context.displayName ?? library.manifest.plugin.displayName)
  }

  func recognize(_ request: OCRRequest) async throws -> OCRResult {
    let result = try await library.invoke(
      NativePluginRequest(
        operation: NativePluginOperation.ocrRecognize,
        kind: kind,
        configuration: try PluginWireCodec.value(context),
        payload: try PluginWireCodec.value(request)))
    guard let result else { throw NativePluginHostError.missingResult }
    return try PluginWireCodec.decode(OCRResult.self, from: result)
  }
}

private struct NativeMCPFactory: ConfiguredMCPToolSourceFactory {
  let library: NativePluginLibrary
  let `extension`: NativePluginExtension
  var kind: String { `extension`.kind }

  func makeMCPToolSource(
    from configuration: ConfiguredMCPServer,
    environment: [String: String]
  ) throws -> any MCPToolSource {
    NativeMCPToolSource(
      library: library,
      kind: kind,
      configuration: configuration,
      environment: environment)
  }
}

private actor NativeMCPToolSource: MCPToolSource {
  let library: NativePluginLibrary
  let kind: String
  let configuration: ConfiguredMCPServer
  let environment: [String: String]
  private var catalog: MCPServerCatalog?

  init(
    library: NativePluginLibrary,
    kind: String,
    configuration: ConfiguredMCPServer,
    environment: [String: String]
  ) {
    self.library = library
    self.kind = kind
    self.configuration = configuration
    self.environment = environment
  }

  func connect() async throws -> MCPServerCatalog {
    if let catalog { return catalog }
    let result = try await library.invoke(
      NativePluginRequest(
        operation: NativePluginOperation.mcpConnect,
        kind: kind,
        configuration: try encodedConfiguration()))
    guard let result else { throw NativePluginHostError.missingResult }
    let catalog = try PluginWireCodec.decode(MCPServerCatalog.self, from: result)
    self.catalog = catalog
    return catalog
  }

  func agentTools() async throws -> [any AgentTool] {
    let catalog = try await connect()
    return catalog.tools.map {
      NativeMCPTool(
        library: library,
        kind: kind,
        configuration: configuration,
        environment: environment,
        definition: $0)
    }
  }

  func close() async {
    _ = try? await library.invoke(
      NativePluginRequest(
        operation: NativePluginOperation.mcpClose,
        kind: kind,
        configuration: try? encodedConfiguration()))
    catalog = nil
  }

  private func encodedConfiguration() throws -> PluginJSONValue {
    try PluginWireCodec.value(
      NativeMCPConfiguration(configuration: configuration, environment: environment))
  }
}

private struct NativeMCPConfiguration: Codable {
  var configuration: ConfiguredMCPServer
  var environment: [String: String]
}

private struct NativeMCPTool: AgentTool {
  let library: NativePluginLibrary
  let kind: String
  let configuration: ConfiguredMCPServer
  let environment: [String: String]
  let definition: ToolDefinition

  func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
    let result = try await library.invoke(
      NativePluginRequest(
        operation: NativePluginOperation.mcpCall,
        kind: kind,
        configuration: try PluginWireCodec.value(
          NativeMCPConfiguration(configuration: configuration, environment: environment)),
        payload: try PluginWireCodec.value(
          NativeToolCall(name: definition.name, arguments: arguments, context: context))))
    guard let result else { throw NativePluginHostError.missingResult }
    return try PluginWireCodec.decode(ToolOutput.self, from: result)
  }
}

public enum NativePluginHostError: LocalizedError, Equatable, Sendable {
  case notFound(String)
  case invalidExtension(String)
  case openFailed(path: String, message: String)
  case entryPointMissing(String)
  case invalidEntryPoint
  case unsupportedABIVersion(found: UInt32, supported: UInt32)
  case invalidManifest(String)
  case invalidRequest
  case invalidResponse(String)
  case missingResult
  case registrationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .notFound(let path): "Native plugin not found at '\(path)'."
    case .invalidExtension(let path):
      "Native plugins must be .\(NativePluginLibrary.libraryExtension) files: '\(path)'."
    case .openFailed(let path, let message): "Could not load native plugin '\(path)': \(message)"
    case .entryPointMissing(let symbol): "Native plugin does not export '\(symbol)'."
    case .invalidEntryPoint: "Native plugin returned an invalid API entry point."
    case .unsupportedABIVersion(let found, let supported):
      "Native plugin ABI version \(found) is unsupported; expected \(supported)."
    case .invalidManifest(let message): "Invalid native plugin manifest: \(message)"
    case .invalidRequest: "Could not encode a native plugin request."
    case .invalidResponse(let message): "Invalid native plugin response: \(message)"
    case .missingResult: "Native plugin response did not include a result."
    case .registrationFailed(let id): "Native plugin '\(id)' was not registered."
    }
  }
}
