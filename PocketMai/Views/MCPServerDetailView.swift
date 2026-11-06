import MaiCore
import SwiftUI

private enum MCPServerNameResolution {
  static func savedName(for server: MCPServer) -> String {
    server.name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func savedBaseURL(for server: MCPServer) -> String {
    server.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func validationMessage(for server: MCPServer, in servers: [MCPServer]) -> String? {
    let name = savedName(for: server)
    if !name.isEmpty, hasDuplicateName(name, excluding: server.id, in: servers) {
      return "Another MCP server is already named \"\(name)\"."
    }
    return endpointValidationMessage(for: server)
  }

  static func resolvedName(
    for server: MCPServer,
    serverInfoName: String?,
    in servers: [MCPServer]
  ) -> String {
    let manualName = savedName(for: server)
    if !manualName.isEmpty {
      return manualName
    }

    let detectedName =
      serverInfoName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let baseName = detectedName.isEmpty ? hostName(for: server) : detectedName
    return uniqueName(baseName.isEmpty ? "MCP Server" : baseName, excluding: server.id, in: servers)
  }

  static func endpointValidationMessage(for server: MCPServer) -> String? {
    let baseURL = savedBaseURL(for: server)
    guard !baseURL.isEmpty else {
      return "Specify an endpoint URL for this MCP server."
    }
    guard let components = URLComponents(string: baseURL),
      let scheme = components.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      let host = components.host,
      !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return "Specify a valid http or https endpoint URL."
    }
    return nil
  }

  private static func hasDuplicateName(
    _ name: String,
    excluding serverID: UUID,
    in servers: [MCPServer]
  ) -> Bool {
    let normalized = normalizedName(name)
    return servers.contains { server in
      guard server.id != serverID else { return false }
      return normalizedName(server.name) == normalized
    }
  }

  private static func hostName(for server: MCPServer) -> String {
    let baseURL = savedBaseURL(for: server)
    guard let host = URL(string: baseURL)?.host?.trimmingCharacters(in: .whitespacesAndNewlines),
      !host.isEmpty
    else {
      return "MCP Server"
    }
    return host
  }

  private static func uniqueName(
    _ name: String,
    excluding serverID: UUID,
    in servers: [MCPServer]
  ) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = trimmed.isEmpty ? "MCP Server" : trimmed
    guard hasDuplicateName(base, excluding: serverID, in: servers) else {
      return base
    }
    for suffix in 2...999 {
      let candidate = "\(base) \(suffix)"
      if !hasDuplicateName(candidate, excluding: serverID, in: servers) {
        return candidate
      }
    }
    return "\(base) \(UUID().uuidString.prefix(4))"
  }

  private static func normalizedName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

struct MCPServerDetailView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @Binding private var savedServer: MCPServer
  @State private var server: MCPServer
  @State private var draftStatus: EndpointConnectionState = .unknown
  @State private var draftTools: [MCPToolDescriptor] = []
  @State private var draftResources: [MCPResourceDescriptor] = []
  @State private var draftTransport: MCPTransport?
  @State private var draftProtocolVersion: String?
  @State private var draftServerName: String?
  @State private var draftStatusBaseURL: String
  @State private var draftStatusAuthentication: MCPAuthentication
  @State private var toastMessage: ToastNotice?
  @State private var isAuthorizing = false
  @FocusState private var isNameFocused: Bool
  @FocusState private var isEndpointFocused: Bool
  private let isNew: Bool
  private let onSave: ((MCPServer) -> Void)?

  init(
    server: Binding<MCPServer>,
    isNew: Bool = false,
    onSave: ((MCPServer) -> Void)? = nil
  ) {
    self._savedServer = server
    self._server = State(initialValue: server.wrappedValue)
    self._draftTransport = State(initialValue: server.wrappedValue.transport)
    self._draftStatusBaseURL = State(
      initialValue: MCPServerNameResolution.savedBaseURL(for: server.wrappedValue))
    self._draftStatusAuthentication = State(initialValue: server.wrappedValue.authentication)
    self.isNew = isNew
    self.onSave = onSave
  }

  var body: some View {
    Form {
      Section {
        Toggle("Enabled", isOn: $server.isEnabled)
        TextField("Name", text: $server.name)
          .focused($isNameFocused)
      } footer: {
        Text("Leave blank to use the name reported by the server.")
      }

      Section {
        TextField("https://example.com/mcp", text: $server.baseURL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
          .focused($isEndpointFocused)
        if !server.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && MCPServerNameResolution.endpointValidationMessage(for: server) != nil
        {
          Label(
            "Specify a valid http or https endpoint URL.", systemImage: "exclamationmark.triangle"
          )
          .foregroundStyle(.red)
        }
      } header: {
        Text("Endpoint")
      } footer: {
        Text(
          "Enter a Streamable HTTP endpoint, usually ending in /mcp. Legacy /sse URLs are not supported."
        )
      }

      authenticationSection

      Section {
        Button {
          if let message = MCPServerNameResolution.endpointValidationMessage(for: server) {
            toastMessage = ToastNotice(message)
            return
          }
          if let message = authenticationValidationMessage {
            setDraftConnectionFailure(message)
            toastMessage = ToastNotice(message)
            return
          }
          let snapshot = normalizedServerForSaving
          refreshTools(snapshot)
        } label: {
          if isChecking {
            HStack {
              ProgressView()
              Text("Connecting…")
            }
          } else {
            Label("Refresh MCP", systemImage: "arrow.clockwise")
          }
        }
        .disabled(
          isChecking
            || MCPServerNameResolution.endpointValidationMessage(for: server) != nil)
        if let transport = currentTransport {
          LabeledContent("Transport", value: transport.displayName)
        }
        if let protocolVersion = currentProtocolVersion, !protocolVersion.isEmpty {
          LabeledContent("Protocol", value: protocolVersion)
        }
      } header: {
        Text("Connection")
      } footer: {
        statusFooter
      }

      if !currentTools.isEmpty {
        let tools = currentTools
        Section("Available Tools (\(tools.count))") {
          ForEach(tools) { tool in
            VStack(alignment: .leading, spacing: 4) {
              Text(tool.name)
                .font(.callout.weight(.semibold))
              if !tool.description.isEmpty {
                Text(tool.description)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(4)
              }
            }
            .padding(.vertical, 2)
          }
        }
      }

      if !currentResources.isEmpty {
        let resources = currentResources
        Section("Available Resources (\(resources.count))") {
          ForEach(resources) { resource in
            VStack(alignment: .leading, spacing: 4) {
              Text(resource.uri)
                .font(.callout.weight(.semibold))
              if !resource.name.isEmpty {
                Text(resource.name)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
              if !resource.description.isEmpty {
                Text(resource.description)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(4)
              }
            }
            .padding(.vertical, 2)
          }
        }
      }
    }
    .navigationTitle(navigationTitle)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button {
          saveServerAndDismiss()
        } label: {
          Text("Save")
        }
      }
    }
    .toast($toastMessage)
    .onAppear {
      if isNew {
        isEndpointFocused = true
      }
    }
    .onDisappear {
      if hasUnsavedConnectionChanges {
        Task { await MCPHTTPClient.resetSession(for: server.id) }
      }
    }
  }

  @ViewBuilder
  private var authenticationSection: some View {
    Section {
      Picker("Authentication", selection: authenticationMethodBinding) {
        ForEach(MCPAuthenticationMethod.allCases) { method in
          Text(method.displayName).tag(method)
        }
      }
      .pickerStyle(.menu)

      switch server.authentication.method {
      case .none:
        Text("No authorization header will be sent.")
          .font(.caption)
          .foregroundStyle(.secondary)
      case .bearer:
        SecureField("Bearer token or API key", text: $server.authentication.bearerToken)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      case .oauth:
        oauthAuthenticationControls
      }
    } header: {
      Text("Authentication")
    } footer: {
      Text(
        "Bearer tokens are sent in the Authorization header. OAuth settings are discovered automatically from the MCP endpoint."
      )
    }
  }

  @ViewBuilder
  private var oauthAuthenticationControls: some View {
    let signedIn = !server.authentication.oauthAccessToken
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let expired = server.authentication.oauthAccessTokenExpired
    HStack(spacing: 8) {
      Image(
        systemName: signedIn && !expired
          ? "checkmark.seal.fill"
          : (signedIn ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.questionmark")
      )
      .foregroundStyle(signedIn && !expired ? Color.green : (signedIn ? Color.orange : .secondary))
      Text(!signedIn ? "Not signed in" : (expired ? "Signed in (token expired)" : "Signed in"))
        .font(.subheadline)
    }
    Button {
      isNameFocused = false
      isEndpointFocused = false
      Task { await signInToMCP() }
    } label: {
      if isAuthorizing {
        HStack(spacing: 6) {
          ProgressView()
          Text("Authorizing…")
        }
      } else {
        Label(
          signedIn ? "Sign In Again" : "Sign In with OAuth",
          systemImage: "person.crop.circle.badge.checkmark")
      }
    }
    .disabled(isAuthorizing || !server.hasValidEndpointURL)
    if signedIn {
      Button(role: .destructive) {
        signOutOfMCP()
      } label: {
        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
      }
      .disabled(isAuthorizing)
    }
  }

  private var authenticationMethodBinding: Binding<MCPAuthenticationMethod> {
    Binding(
      get: { server.authentication.method },
      set: { method in
        guard method != server.authentication.method else { return }
        server.authentication.method = method
        clearDraftConnectionState()
        Task { await MCPHTTPClient.resetSession(for: server.id) }
      })
  }

  @MainActor
  private func signInToMCP() async {
    guard !isAuthorizing else { return }
    isAuthorizing = true
    defer { isAuthorizing = false }
    do {
      let result = try await MCPOAuthService.signIn(server: normalizedServerForSaving)
      applyOAuthResult(result)
      persistMCPAuthentication()
      await MCPHTTPClient.resetSession(for: server.id)
      clearDraftConnectionState()
      toastMessage = ToastNotice("MCP OAuth authorization succeeded.", style: .success)
      refreshTools(normalizedServerForSaving)
    } catch let error as MCPOAuthError {
      if case .userCancelled = error { return }
      setDraftConnectionFailure(error.localizedDescription)
      toastMessage = ToastNotice(error.shortDescription)
    } catch {
      setDraftConnectionFailure(error.localizedDescription)
      toastMessage = ToastNotice("OAuth sign-in failed.")
    }
  }

  private func applyOAuthResult(_ result: MCPOAuthResult) {
    server.authentication.oauthAccessToken = result.accessToken
    if let refreshToken = result.refreshToken {
      server.authentication.oauthRefreshToken = refreshToken
    }
    server.authentication.oauthAccessTokenExpiresAt = result.expiresAt
    server.authentication.oauthClientID = result.clientID
  }

  private func signOutOfMCP() {
    server.authentication.oauthAccessToken = ""
    server.authentication.oauthRefreshToken = ""
    server.authentication.oauthAccessTokenExpiresAt = nil
    persistMCPAuthentication()
    Task { await MCPHTTPClient.resetSession(for: server.id) }
    clearDraftConnectionState()
    toastMessage = ToastNotice("Signed out from MCP OAuth.", style: .success)
  }

  private func persistMCPAuthentication() {
    guard let index = store.settings.mcpServers.firstIndex(where: { $0.id == server.id }) else {
      return
    }
    store.settings.mcpServers[index].authentication = server.authentication
    savedServer.authentication = server.authentication
    store.saveSettings()
  }

  private func clearDraftConnectionState() {
    draftStatus = .unknown
    draftTools = []
    draftResources = []
    draftTransport = nil
    draftProtocolVersion = nil
    draftServerName = nil
    draftStatusBaseURL = MCPServerNameResolution.savedBaseURL(for: server)
    draftStatusAuthentication = server.authentication
  }

  private func setDraftConnectionFailure(_ message: String) {
    draftStatusBaseURL = MCPServerNameResolution.savedBaseURL(for: server)
    draftStatusAuthentication = server.authentication
    draftStatus = .failed(message)
  }

  private var authenticationValidationMessage: String? {
    switch server.authentication.method {
    case .none:
      return nil
    case .bearer:
      return server.authentication.accessToken == nil ? "Enter a Bearer token first." : nil
    case .oauth:
      let refreshToken = server.authentication.oauthRefreshToken
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return server.authentication.accessToken == nil && refreshToken.isEmpty
        ? "Sign in with OAuth first."
        : nil
    }
  }

  private var navigationTitle: String {
    let name = MCPServerNameResolution.savedName(for: server)
    return name.isEmpty ? "MCP Server" : name
  }

  private var normalizedServerForSaving: MCPServer {
    var normalized = server
    normalized.name = MCPServerNameResolution.savedName(for: server)
    normalized.baseURL = MCPServerNameResolution.savedBaseURL(for: server)
    normalized.transport = currentTransport
    return normalized
  }

  private var hasUnsavedConnectionChanges: Bool {
    MCPServerNameResolution.savedBaseURL(for: server)
      != MCPServerNameResolution.savedBaseURL(for: savedServer)
      || server.authentication != savedServer.authentication
  }

  private var draftStateMatchesCurrentEndpoint: Bool {
    draftStatusBaseURL == MCPServerNameResolution.savedBaseURL(for: server)
      && draftStatusAuthentication == server.authentication
  }

  private var currentStatus: EndpointConnectionState {
    if draftStateMatchesCurrentEndpoint, case .failed = draftStatus {
      return draftStatus
    }
    if let message = authenticationValidationMessage {
      return .failed(message)
    }
    if hasUnsavedConnectionChanges {
      return draftStateMatchesCurrentEndpoint ? draftStatus : .unknown
    }
    return store.mcpStatuses[server.id] ?? .unknown
  }

  private var currentTools: [MCPToolDescriptor] {
    if hasUnsavedConnectionChanges {
      return draftStateMatchesCurrentEndpoint ? draftTools : []
    }
    return store.mcpTools[server.id] ?? []
  }

  private var currentResources: [MCPResourceDescriptor] {
    if hasUnsavedConnectionChanges {
      return draftStateMatchesCurrentEndpoint ? draftResources : []
    }
    return store.mcpResources[server.id] ?? []
  }

  private var currentTransport: MCPTransport? {
    if hasUnsavedConnectionChanges {
      return draftStateMatchesCurrentEndpoint ? draftTransport : server.transport
    }
    return server.transport ?? draftTransport
  }

  private var currentProtocolVersion: String? {
    guard draftStateMatchesCurrentEndpoint else { return nil }
    return draftProtocolVersion
  }

  private var isChecking: Bool {
    if case .checking = currentStatus {
      return true
    }
    return false
  }

  @ViewBuilder
  private var statusFooter: some View {
    let status = currentStatus
    let tools = currentTools
    let resources = currentResources
    switch status {
    case .unknown:
      Text("The Streamable HTTP connection will be checked when this server is refreshed or saved.")
    case .checking:
      Text("Connecting…")
    case .available:
      let transportText = currentTransport?.displayName ?? "MCP"
      if tools.isEmpty && resources.isEmpty {
        Text("Connected over \(transportText), but the server reports no tools or resources.")
      } else {
        Text(
          "Connected over \(transportText). \(tools.count) tool\(tools.count == 1 ? "" : "s"), \(resources.count) resource\(resources.count == 1 ? "" : "s") available."
        )
      }
    case .failed(let message):
      Text(message)
        .foregroundStyle(.red)
        .textSelection(.enabled)
    }
  }

  private func refreshTools(_ snapshot: MCPServer) {
    guard hasUnsavedConnectionChanges else {
      Task { await store.refreshMCP(snapshot, force: true) }
      return
    }

    draftStatusBaseURL = snapshot.baseURL
    draftStatusAuthentication = snapshot.authentication
    draftStatus = .checking
    draftTools = []
    draftResources = []
    draftTransport = snapshot.transport
    draftProtocolVersion = nil
    draftServerName = nil
    let timeout = store.settings.mcpRequestTimeoutInterval
    Task {
      do {
        let catalog = try await MCPHTTPClient.fetchCatalog(
          server: snapshot,
          timeout: timeout)
        await MainActor.run {
          guard MCPServerNameResolution.savedBaseURL(for: server) == snapshot.baseURL else {
            return
          }
          draftTools = catalog.tools
          draftResources = catalog.resources
          draftTransport = catalog.transport
          draftProtocolVersion = catalog.protocolVersion
          draftServerName = catalog.serverName
          draftStatus = .available
        }
      } catch {
        await MainActor.run {
          guard MCPServerNameResolution.savedBaseURL(for: server) == snapshot.baseURL else {
            return
          }
          draftTools = []
          draftResources = []
          draftTransport = nil
          draftProtocolVersion = nil
          draftServerName = nil
          draftStatus = .failed(error.localizedDescription)
        }
      }
    }
  }

  private func saveServerAndDismiss() {
    if let message = MCPServerNameResolution.validationMessage(
      for: server,
      in: store.settings.mcpServers)
    {
      toastMessage = ToastNotice(message)
      return
    }

    var snapshot = normalizedServerForSaving
    snapshot.name = MCPServerNameResolution.resolvedName(
      for: snapshot,
      serverInfoName: draftServerName,
      in: store.settings.mcpServers)
    finalizeSave(snapshot)
  }

  private func finalizeSave(_ normalized: MCPServer) {
    let connectionChanged =
      normalized.baseURL != MCPServerNameResolution.savedBaseURL(for: savedServer)
      || normalized.authentication != savedServer.authentication
    server = normalized
    savedServer = normalized
    onSave?(normalized)
    if connectionChanged || hasDraftConnectionState(for: normalized) {
      applyDraftConnectionStateAfterSave(for: normalized)
    }
    store.saveSettings()
    dismiss()
  }

  private func hasDraftConnectionState(for server: MCPServer) -> Bool {
    guard draftStatusBaseURL == server.baseURL,
      draftStatusAuthentication == server.authentication
    else {
      return false
    }
    switch draftStatus {
    case .available, .failed:
      return true
    case .unknown, .checking:
      return false
    }
  }

  private func applyDraftConnectionStateAfterSave(for server: MCPServer) {
    guard draftStatusBaseURL == server.baseURL else {
      store.resetMCPStatus(server.id)
      return
    }
    switch draftStatus {
    case .available:
      store.mcpTools[server.id] = draftTools
      store.mcpResources[server.id] = draftResources
      store.mcpStatuses[server.id] = .available
    case .failed(let message):
      store.mcpTools[server.id] = nil
      store.mcpResources[server.id] = nil
      store.mcpStatuses[server.id] = .failed(message)
    case .unknown, .checking:
      store.resetMCPStatus(server.id)
    }
  }
}
