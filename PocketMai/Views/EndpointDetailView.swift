import MaiCore
import MaiOpenAI
import SwiftUI
import UIKit

private let customProviderTag = "__custom__"

struct EndpointDetailView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @Binding private var savedEndpoint: OpenAIEndpoint
  @State private var endpoint: OpenAIEndpoint
  @State private var toastMessage: ToastNotice?
  @State private var shareFile: ExportedFile?
  @State private var isSigningIn = false
  @State private var showAdvancedOAuthConfiguration = false
  @State private var showOllamaScanner = false
  /// The headers as typed, one `Name: value` per line. The text is the source
  /// of truth while editing, since a half-typed line has no dictionary form.
  @State private var headersText: String
  private let onSave: ((OpenAIEndpoint) -> Void)?

  init(endpoint: Binding<OpenAIEndpoint>, onSave: ((OpenAIEndpoint) -> Void)? = nil) {
    self._savedEndpoint = endpoint
    self._endpoint = State(initialValue: endpoint.wrappedValue)
    self._headersText = State(initialValue: Self.headersText(for: endpoint.wrappedValue.headers))
    self.onSave = onSave
  }

  private static func headersText(for headers: [String: String]) -> String {
    ProviderHeaders.lines(headers).joined(separator: "\n")
  }

  var body: some View {
    Form {
      Section {
        Toggle("Enabled", isOn: $endpoint.isEnabled)
        TextField(OpenAIEndpoint.defaultDisplayName, text: $endpoint.name)
        Button {
          saveEndpointAndDismiss(makeDefault: true)
        } label: {
          Label(
            isDefaultProvider ? "Default Provider" : "Set as Default",
            systemImage: isDefaultProvider ? "checkmark.circle" : "star"
          )
        }
        .disabled(isDefaultProvider || !endpoint.isEnabled || store.settings.isOffline)
      } footer: {
        Text(
          store.settings.isOffline
            ? "Go online to set this provider as the default."
            : "A friendly name shown in the provider picker. The default provider is used for new chats."
        )
      }

      Section {
        Picker("API", selection: $endpoint.kind) {
          Text("OpenAI API").tag(ConfiguredProviderKind.openAI)
          Text("ChatGPT subscription").tag(ConfiguredProviderKind.chatGPT)
          Text("System One (TEV / JEV)").tag(ConfiguredProviderKind.systemOne)
        }
        .onChange(of: endpoint.kind) { _, _ in
          if endpoint.kind == .chatGPT {
            endpoint.baseURL = "https://api.openai.com/v1"
            clearCredentials()
          }
          endpoint.defaultModel = ""
          store.endpointModels[endpoint.id] = nil
          store.endpointModelDescriptors[endpoint.id] = nil
          store.endpointVoices[endpoint.id] = nil
          store.endpointStatuses[endpoint.id] = .unknown
        }
        if endpoint.kind == .systemOne {
          Text(
            "Use a decision model such as tev1 on Ollama 0.35 or later. Assign this connection to a Tool decisions agent; keep a chat model for answers and arguments."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        if endpoint.kind != .chatGPT {
          Picker("Provider", selection: providerPresetBinding) {
            ForEach(endpointProviderPresets, id: \.tag) { preset in
              Text(preset.name).tag(preset.tag)
            }
            Text("Custom").tag(customProviderTag)
          }
          .pickerStyle(.menu)
          TextField("https://api.example.com/v1", text: $endpoint.baseURL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
          authenticationControls
        } else {
          Text("Use your ChatGPT plan").font(.headline)
          Text("Sign in to use eligible models with your ChatGPT subscription.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if showsOllamaScanButton {
          Button {
            showOllamaScanner = true
          } label: {
            Label("Scan Local Network", systemImage: "network")
          }
        }
        Button {
          if let message = EndpointNameResolution.connectionValidationMessage(for: endpoint) {
            toastMessage = ToastNotice(message)
            return
          }
          let snapshot = endpoint
          Task { await store.refreshEndpoint(snapshot, force: true) }
        } label: {
          if isChecking {
            HStack {
              ProgressView()
              Text("Testing connection…")
            }
          } else {
            Label(
              endpoint.kind == .chatGPT ? "Refresh Models" : "Test & Refresh Models & Voices",
              systemImage: "arrow.clockwise")
          }
        }
        .disabled(isChecking)
        if let scheme = URL(string: endpoint.baseURL)?.scheme?.lowercased(),
          !scheme.isEmpty,
          !["http", "https"].contains(scheme)
        {
          Label("Only http and https are supported", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      } header: {
        Text("Connection")
      } footer: {
        Text(
          "Pick a provider to autofill the base URL, or choose Custom to enter your own. OAuth setup is shown only for providers that support it, or for Custom endpoints."
        )
      }

      if endpoint.kind == .chatGPT {
        ChatGPTSignInSection(providerID: endpoint.id.uuidString) {
          savedEndpoint = endpoint
          if let index = store.settings.openAIEndpoints.firstIndex(where: { $0.id == endpoint.id })
          {
            store.settings.openAIEndpoints[index] = endpoint
            store.saveSettings()
          }
          await store.refreshEndpoint(endpoint, force: true)
        }
      } else if effectiveAuthMethod == .oauth {
        oauthConfigSection
      }

      if endpoint.kind != .chatGPT {
        Section {
          TextEditor(text: $headersText)
            .font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(minHeight: 72)
        } header: {
          Text("Custom Headers")
        } footer: {
          Text(
            "One header per line as Name: value, sent with every request. \(ProviderHeaders.sessionPlaceholder) becomes the chat's session id, which OpenCode needs in x-opencode-session."
          )
        }
      }

      Section {
        modelField
        reasoningLevelField
      } header: {
        Text("Default Model")
      } footer: {
        statusFooter
      }

      Section {
        Button {
          exportProvider()
        } label: {
          Label("Export Provider JSON", systemImage: "square.and.arrow.up")
        }
      } footer: {
        Text(
          "Exports only this provider, including its API key and connection settings. Import it from Settings > Import > Provider Settings on another device."
        )
      }
    }
    .navigationTitle(endpoint.displayName)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { saveEndpointAndDismiss() }
      }
    }
    .onAppear(perform: normalizeAuthForSelectedProvider)
    .onChange(of: endpoint.baseURL) { _, _ in normalizeAuthForSelectedProvider() }
    .onChange(of: headersText) { _, text in endpoint.headers = ProviderHeaders.parse(text) }
    .sheet(isPresented: $showOllamaScanner) {
      OllamaPortScanView(
        initialRange: OllamaNetworkScanner.defaultRange(),
        initialPort: OllamaNetworkScanner.defaultPort
      ) { url in
        applyScannedOllamaURL(url)
        showOllamaScanner = false
      }
    }
    .sheet(item: $shareFile) { file in
      ActivityShareSheet(activityItems: [file.url])
    }
    .toast($toastMessage)
  }

  @ViewBuilder
  private var authenticationControls: some View {
    let methods = authMethodsForCurrentProvider
    if methods.count > 1 {
      Picker("Authentication", selection: authMethodBinding) {
        ForEach(methods) { method in
          Text(method.displayName).tag(method)
        }
      }
      .pickerStyle(.menu)
    } else if methods.first == .oauth {
      LabeledContent("Authentication") {
        Text(EndpointAuthMethod.oauth.displayName)
          .foregroundStyle(.secondary)
      }
    }

    switch effectiveAuthMethod {
    case .apiKey:
      SecureField("API Key (Optional)", text: $endpoint.apiKey)
      if let apiKeyOnlyProvider {
        apiKeyOnlyGuidance(for: apiKeyOnlyProvider)
      }
    case .oauth:
      oauthCredentialsView
    }
  }

  @ViewBuilder
  private var oauthCredentialsView: some View {
    let signedIn = !endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let expired = endpoint.oauthAccessTokenExpired
    let hasRefresh =
      !endpoint.oauthRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let setupMessage = oauthSetupMessage
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(
          systemName: signedIn && !expired
            ? "checkmark.seal.fill"
            : (signedIn ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.questionmark")
        )
        .foregroundStyle(
          signedIn && !expired
            ? Color.green
            : (signedIn ? Color.orange : Color.secondary))
        Text(oauthStatusText(signedIn: signedIn, expired: expired))
          .font(.subheadline)
      }
      if let expiry = endpoint.oauthAccessTokenExpiresAt {
        Text(
          "Access token \(expired ? "expired" : "expires") \(expiry.formatted(date: .abbreviated, time: .shortened))."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      if let setupMessage {
        Label(setupMessage, systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 10) {
        Button {
          Task { await runSignIn() }
        } label: {
          if isSigningIn {
            HStack(spacing: 6) {
              ProgressView()
              Text("Signing in…")
            }
          } else {
            Label(
              signedIn ? "Sign In Again" : "Sign In",
              systemImage: "person.crop.circle.badge.checkmark")
          }
        }
        .disabled(isSigningIn || setupMessage != nil)
        if signedIn {
          Button(role: .destructive) {
            signOut()
          } label: {
            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
          }
          .disabled(isSigningIn)
        }
      }
      if signedIn && hasRefresh {
        Button {
          Task { await runRefresh() }
        } label: {
          Label("Refresh Token", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(isSigningIn)
      }
    }
  }

  private var oauthConfigSection: some View {
    Section {
      if isOpenAIEndpoint {
        openAIOAuthGuidance
      } else if let apiKeyOnlyProvider {
        apiKeyOnlyGuidance(for: apiKeyOnlyProvider)
      } else {
        genericOAuthGuidance
      }
      DisclosureGroup(isExpanded: $showAdvancedOAuthConfiguration) {
        TextField("Issuer (https://auth.example.com)", text: $endpoint.oauthIssuer)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
        TextField("Client ID", text: $endpoint.oauthClientID)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        TextField("Audience (optional)", text: $endpoint.oauthAudience)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        TextField("Scope", text: $endpoint.oauthScope)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        TextField("Redirect URI", text: $endpoint.oauthRedirectURI)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
        TextField("Authorize URL (optional)", text: $endpoint.oauthAuthorizeURL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
        TextField("Token URL (optional)", text: $endpoint.oauthTokenURL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
      } label: {
        Label("Advanced OAuth Configuration", systemImage: "slider.horizontal.3")
      }
    } header: {
      Text("OAuth")
    } footer: {
      Text(
        "These fields are only needed for providers that require a registered OAuth application. Leave Authorize and Token URLs blank to derive them from the issuer."
      )
    }
  }

  private func apiKeyOnlyGuidance(for provider: APIKeyOnlyProvider) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("No \(provider.name) OAuth client ID", systemImage: "key.slash")
        .font(.subheadline.weight(.semibold))
      Text(provider.message)
        .font(.caption)
        .foregroundStyle(.secondary)
      Button {
        endpoint.authMethod = .apiKey
        clearCredentials()
        UIApplication.shared.open(provider.apiKeyURL)
      } label: {
        Label("Open \(provider.name) API Keys", systemImage: "arrow.up.right.square")
      }
      .buttonStyle(.borderless)
      if let dashboardURL = provider.dashboardURL {
        Button {
          UIApplication.shared.open(dashboardURL)
        } label: {
          Label("Open \(provider.name) Dashboard", systemImage: "safari")
        }
        .buttonStyle(.borderless)
      }
    }
  }

  private var openAIOAuthGuidance: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("OpenAI OAuth", systemImage: "person.crop.circle.badge.checkmark")
        .font(.subheadline.weight(.semibold))
      Text(
        "Use OAuth here if you have an OpenAI OAuth client ID registered for pocketmai://oauth/callback. Otherwise use API Key above."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Button {
        if let url = URL(string: "https://platform.openai.com") {
          UIApplication.shared.open(url)
        }
      } label: {
        Label("Open OpenAI Dashboard", systemImage: "safari")
      }
      .buttonStyle(.borderless)
    }
  }

  private var genericOAuthGuidance: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("OAuth client ID", systemImage: "person.badge.key")
        .font(.subheadline.weight(.semibold))
      Text(
        "Create an OAuth client in the provider's developer console, copy its client ID here, and register pocketmai://oauth/callback as an allowed redirect URI."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      if isGoogleVertexEndpoint,
        let url = URL(string: "https://console.cloud.google.com/apis/credentials")
      {
        Link(destination: url) {
          Label("Open Google OAuth Clients", systemImage: "arrow.up.right.square")
        }
      }
    }
  }

  private var oauthSetupMessage: String? {
    guard effectiveAuthMethod == .oauth else { return nil }
    let clientID = endpoint.oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard clientID.isEmpty else { return nil }
    if isOpenAIEndpoint {
      return "OpenAI OAuth needs a client ID before Sign In can open."
    }
    if isAnthropicEndpoint {
      return "Anthropic API auth uses API keys here. Use the button below."
    }
    return "OAuth needs a client ID before Sign In can open."
  }

  private struct APIKeyOnlyProvider {
    let name: String
    let message: String
    let apiKeyURL: URL
    let dashboardURL: URL?
  }

  private var apiKeyOnlyProvider: APIKeyOnlyProvider? {
    if isAnthropicEndpoint,
      let apiKeyURL = URL(string: "https://console.anthropic.com/settings/keys"),
      let dashboardURL = URL(string: "https://console.anthropic.com")
    {
      return APIKeyOnlyProvider(
        name: "Anthropic",
        message:
          "There is no Anthropic OAuth client ID you can generate here for the public API. Use OAuth only if you own a registered OAuth app that allows pocketmai://oauth/callback.",
        apiKeyURL: apiKeyURL,
        dashboardURL: dashboardURL
      )
    }
    return nil
  }

  private var isOpenAIEndpoint: Bool {
    endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      == OpenAIEndpoint.openAIAuthDefaults.baseURL
  }

  private var isAnthropicEndpoint: Bool {
    endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      == OpenAIEndpoint.anthropicOAuthDefaults.baseURL
  }

  private var isGoogleVertexEndpoint: Bool {
    endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      == OpenAIEndpoint.googleOAuthDefaults.baseURL
  }

  private var showsOllamaScanButton: Bool {
    if selectedProviderPreset?.name == "Ollama" {
      return true
    }
    if endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ollama" {
      return true
    }
    return OllamaNetworkScanner.isLikelyLocalOllamaBaseURL(endpoint.baseURL)
  }

  private var selectedProviderPreset: EndpointProviderPreset? {
    EndpointNameResolution.providerPreset(forBaseURL: endpoint.baseURL)
  }

  private var authMethodsForCurrentProvider: [EndpointAuthMethod] {
    if let selectedProviderPreset {
      return selectedProviderPreset.authMethods
    }
    return [.apiKey]
  }

  private var effectiveAuthMethod: EndpointAuthMethod {
    let methods = authMethodsForCurrentProvider
    if methods.contains(endpoint.authMethod) {
      return endpoint.authMethod
    }
    return methods.first ?? .apiKey
  }

  private func oauthStatusText(signedIn: Bool, expired: Bool) -> String {
    if !signedIn { return "Not signed in" }
    if expired { return "Signed in (token expired)" }
    return "Signed in"
  }

  @MainActor
  private func runSignIn() async {
    isSigningIn = true
    defer { isSigningIn = false }
    do {
      let tokens = try await OAuthService.signIn(endpoint: endpoint)
      applyTokens(tokens)
      persistOAuthState()
      toastMessage = ToastNotice("Signed in successfully.", style: .success)
    } catch let error as OAuthError {
      if case .userCancelled = error { return }
      toastMessage = ToastNotice(error.localizedDescription)
    } catch {
      toastMessage = ToastNotice(error.localizedDescription)
    }
  }

  @MainActor
  private func runRefresh() async {
    isSigningIn = true
    defer { isSigningIn = false }
    do {
      let tokens = try await OAuthService.refresh(endpoint: endpoint)
      applyTokens(tokens)
      persistOAuthState()
      toastMessage = ToastNotice("Access token refreshed.", style: .success)
    } catch {
      toastMessage = ToastNotice(error.localizedDescription)
    }
  }

  private func applyTokens(_ tokens: OAuthTokens) {
    endpoint.apiKey = tokens.accessToken
    if let refresh = tokens.refreshToken {
      endpoint.oauthRefreshToken = refresh
    }
    endpoint.oauthAccessTokenExpiresAt = tokens.expiresAt
  }

  private func signOut() {
    endpoint.apiKey = ""
    endpoint.oauthRefreshToken = ""
    endpoint.oauthAccessTokenExpiresAt = nil
    persistOAuthState()
    toastMessage = ToastNotice("Signed out.", style: .success)
  }

  /// Persist the current OAuth credential state immediately so a successful sign-in
  /// survives navigating away without an explicit Save tap.
  private func persistOAuthState() {
    if let index = store.settings.openAIEndpoints.firstIndex(where: { $0.id == endpoint.id }) {
      store.settings.openAIEndpoints[index] = endpoint
      savedEndpoint = endpoint
      store.saveSettings()
    }
  }

  @ViewBuilder
  private var modelField: some View {
    FilteredModelPicker(
      selection: $endpoint.defaultModel, endpoint: endpoint,
      emptySelectionTitle: "Select a model",
      initialFeatures: endpoint.kind == .systemOne ? [.decision] : [],
      onSelect: { model in
        if model.capabilities.contains(.nativeToolCalling) {
          store.settings.toolCallingMode = .native
          store.saveSettings()
        }
      })
  }

  private var reasoningLevelField: some View {
    ReasoningLevelControl(
      level: $endpoint.defaultReasoningLevel,
      model: endpoint.defaultModel, endpointName: endpoint.name, baseURL: endpoint.baseURL)
  }

  @ViewBuilder
  private var statusFooter: some View {
    let status = store.endpointStatuses[endpoint.id] ?? .unknown
    let models = store.endpointModels[endpoint.id] ?? []
    let voices = store.endpointVoices[endpoint.id] ?? []
    switch status {
    case .unknown:
      Text("Tap “Test & Refresh Models & Voices” to verify the connection and load capabilities.")
    case .checking:
      Text("Testing connection…")
    case .available:
      if models.isEmpty && voices.isEmpty {
        Text("Connected.")
      } else if voices.isEmpty {
        Text("Connected. \(models.count) models available.")
      } else if models.isEmpty {
        Text("Connected. \(voices.count) voices available.")
      } else {
        Text("Connected. \(models.count) models and \(voices.count) voices available.")
      }
    case .failed(let message):
      Text(message).foregroundStyle(.red)
    }
  }

  private var isChecking: Bool {
    if case .checking = store.endpointStatuses[endpoint.id] {
      return true
    }
    return false
  }

  private var isDefaultProvider: Bool {
    store.settings.defaultProvider == .openAICompatible
      && store.settings.selectedEndpointID == endpoint.id
  }

  private func saveEndpointAndDismiss(makeDefault: Bool = false) {
    normalizeAuthForSelectedProvider()
    endpoint.headers = ProviderHeaders.parse(headersText)
    if let message = EndpointNameResolution.validationMessage(
      for: endpoint,
      in: store.settings.openAIEndpoints)
    {
      toastMessage = ToastNotice(message)
      return
    }
    if let savedName = EndpointNameResolution.savedName(for: endpoint) {
      endpoint.name = savedName
    }
    let connectionChanged =
      endpoint.baseURL != savedEndpoint.baseURL || endpoint.apiKey != savedEndpoint.apiKey
      || endpoint.headers != savedEndpoint.headers
    savedEndpoint = endpoint
    onSave?(endpoint)
    if makeDefault {
      store.settings.defaultProvider = .openAICompatible
      store.settings.selectedEndpointID = endpoint.id
    }
    if connectionChanged {
      store.resetEndpointStatus(endpoint.id)
    }
    store.saveSettings()
    dismiss()
  }

  private func exportProvider() {
    normalizeAuthForSelectedProvider()
    var exportedEndpoint = endpoint
    if let message = EndpointNameResolution.validationMessage(
      for: exportedEndpoint,
      in: store.settings.openAIEndpoints)
    {
      toastMessage = ToastNotice(message)
      return
    }
    if let savedName = EndpointNameResolution.savedName(for: exportedEndpoint) {
      exportedEndpoint.name = savedName
    }
    guard let url = store.exportEndpointBackupFile(exportedEndpoint) else {
      toastMessage = ToastNotice(store.errorMessage ?? "Could not export provider.")
      return
    }
    shareFile = ExportedFile(url: url)
  }

  private func applyScannedOllamaURL(_ url: String) {
    endpoint.baseURL = url
    endpoint.authMethod = .apiKey
    clearCredentials()
    if endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      endpoint.name = "Ollama"
    }
  }

  private var providerPresetBinding: Binding<String> {
    Binding(
      get: {
        let trimmed = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preset = EndpointNameResolution.providerPreset(forBaseURL: trimmed) {
          return preset.tag
        }
        return customProviderTag
      },
      set: { newValue in
        if newValue == customProviderTag {
          if endpoint.authMethod != .apiKey {
            clearCredentials()
            endpoint.authMethod = .apiKey
          }
          endpoint.baseURL = ""
          return
        }
        guard let preset = endpointProviderPresets.first(where: { $0.tag == newValue }) else {
          return
        }
        let oldAuthMethod = endpoint.authMethod
        let oldBaseURL = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        endpoint.baseURL = preset.url
        applyPresetHeaders(
          preset, replacing: EndpointNameResolution.providerPreset(forBaseURL: oldBaseURL))
        if let preferredAuthMethod = preset.preferredAuthMethod,
          preset.authMethods.contains(preferredAuthMethod)
        {
          endpoint.authMethod = preferredAuthMethod
        } else if !preset.authMethods.contains(endpoint.authMethod) {
          endpoint.authMethod = preset.authMethods.first ?? .apiKey
        }
        let authChanged = oldAuthMethod != endpoint.authMethod
        let oauthProviderChanged =
          endpoint.authMethod == .oauth && oldBaseURL != preset.url
        if authChanged || oauthProviderChanged {
          clearCredentials()
        }
        if endpoint.authMethod == .oauth,
          preset.authMethods.contains(.oauth),
          let defaults = preset.oauthDefaults
        {
          applyOAuthDefaults(defaults, overwriteExisting: true)
        }
      }
    )
  }

  /// Fills in the headers a preset needs, keeping any the user already set,
  /// and drops what the previous preset added unless the user changed it.
  private func applyPresetHeaders(
    _ preset: EndpointProviderPreset, replacing previous: EndpointProviderPreset?
  ) {
    var headers = ProviderHeaders.parse(headersText)
    for (name, value) in previous?.headers ?? [:] where headers[name] == value {
      headers.removeValue(forKey: name)
    }
    headers.merge(preset.headers) { own, _ in own }
    // Rewriting the text would drop a half-typed line, so only do it when the
    // preset actually changed something.
    if headers != ProviderHeaders.parse(headersText) {
      headersText = Self.headersText(for: headers)
    }
  }

  private var authMethodBinding: Binding<EndpointAuthMethod> {
    Binding(
      get: { endpoint.authMethod },
      set: { newValue in
        guard newValue != endpoint.authMethod else { return }
        clearCredentials()
        endpoint.authMethod = newValue
        if newValue == .oauth {
          applyOAuthDefaultsIfMissing()
        }
      }
    )
  }

  private func applyOAuthDefaults(
    _ defaults: OAuthPresetDefaults,
    overwriteExisting: Bool = false
  ) {
    endpoint.authMethod = .oauth
    endpoint.baseURL = defaults.baseURL
    fillOAuthDefaults(defaults, overwriteExisting: overwriteExisting)
  }

  private func fillOAuthDefaults(_ defaults: OAuthPresetDefaults, overwriteExisting: Bool) {
    if overwriteExisting
      || endpoint.oauthIssuer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      endpoint.oauthIssuer = defaults.issuer
    }
    if overwriteExisting
      || endpoint.oauthAudience.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      endpoint.oauthAudience = defaults.audience
    }
    if overwriteExisting
      || endpoint.oauthScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      endpoint.oauthScope = defaults.scope
    }
    if overwriteExisting
      || endpoint.oauthRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      endpoint.oauthRedirectURI = defaults.redirectURI
    }
    if overwriteExisting
      || endpoint.oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      endpoint.oauthClientID = defaults.clientID
    }
    if overwriteExisting
      || endpoint.oauthAuthorizeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      endpoint.oauthAuthorizeURL = defaults.authorizeURL
    }
    if overwriteExisting
      || endpoint.oauthTokenURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      endpoint.oauthTokenURL = defaults.tokenURL
    }
  }

  private func applyOAuthDefaultsIfMissing() {
    let providerPreset = EndpointNameResolution.providerPreset(forBaseURL: endpoint.baseURL)
    let matchingPreset = EndpointNameResolution.matchingOAuthPreset(for: endpoint)
    let defaults: OAuthPresetDefaults?
    if let providerPreset, providerPreset.authMethods.contains(.oauth) {
      defaults = providerPreset.oauthDefaults
    } else {
      defaults = matchingPreset?.oauthDefaults
    }
    guard let defaults else { return }
    let shouldOverwrite =
      providerPreset?.oauthDefaults != nil
      && matchingPreset != nil
      && providerPreset?.tag != matchingPreset?.tag
    fillOAuthDefaults(defaults, overwriteExisting: shouldOverwrite)
  }

  private func normalizeAuthForSelectedProvider() {
    guard endpoint.kind != .chatGPT else { return }
    let methods = authMethodsForCurrentProvider
    guard !methods.contains(endpoint.authMethod) else { return }
    clearCredentials()
    endpoint.authMethod = methods.first ?? .apiKey
    if endpoint.authMethod == .oauth {
      applyOAuthDefaultsIfMissing()
    }
  }

  private func clearCredentials() {
    endpoint.apiKey = ""
    endpoint.oauthRefreshToken = ""
    endpoint.oauthAccessTokenExpiresAt = nil
  }
}

private struct OllamaPortScanView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var rangeText: String
  @State private var portText: String
  @State private var isScanning = false
  @State private var results: [OllamaScanResult] = []
  @State private var message: String?
  @State private var scanTask: Task<Void, Never>?

  let onSelect: (String) -> Void

  init(
    initialRange: String,
    initialPort: Int,
    onSelect: @escaping (String) -> Void
  ) {
    self._rangeText = State(initialValue: initialRange)
    self._portText = State(initialValue: String(initialPort))
    self.onSelect = onSelect
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("192.168.1.x", text: $rangeText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.numbersAndPunctuation)
            .submitLabel(.search)
            .onSubmit { startScan() }
          TextField("Port", text: $portText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.numberPad)
          Button {
            startScan()
          } label: {
            if isScanning {
              HStack {
                ProgressView()
                Text("Scanning…")
              }
            } else {
              Label("Scan", systemImage: "dot.radiowaves.left.and.right")
            }
          }
          .disabled(isScanning || parsedPort == nil)
          if let message {
            Text(message)
              .font(.caption)
              .foregroundStyle(messageIsError ? .red : .secondary)
          }
        } header: {
          Text("Network")
        } footer: {
          Text("Use x, *, a single host, or a final-octet range such as 192.168.1.20-40.")
        }

        Section {
          if results.isEmpty {
            Text(isScanning ? "Looking for Ollama endpoints…" : "No scan results yet.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(results) { result in
              Button {
                scanTask?.cancel()
                onSelect(result.url)
                dismiss()
              } label: {
                HStack {
                  Text(result.url)
                    .textSelection(.enabled)
                  Spacer()
                  Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                }
              }
            }
          }
        } header: {
          Text("Results")
        }
      }
      .navigationTitle("Find Ollama")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            scanTask?.cancel()
            dismiss()
          }
        }
      }
    }
    .onDisappear {
      scanTask?.cancel()
    }
  }

  private var parsedPort: Int? {
    let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let port = Int(trimmed), (1...65535).contains(port) else { return nil }
    return port
  }

  private var messageIsError: Bool {
    guard let message else { return false }
    return message.hasPrefix("Invalid") || message.hasPrefix("Enter")
  }

  private func startScan() {
    guard !isScanning else { return }
    guard let port = parsedPort else {
      message = "Invalid port. Use a number from 1 to 65535."
      return
    }

    scanTask?.cancel()
    results = []
    message = "Scanning \(rangeText):\(port)…"
    isScanning = true
    let range = rangeText
    scanTask = Task {
      do {
        let found = try await OllamaNetworkScanner.scan(rangeText: range, port: port) { result in
          if !results.contains(result) {
            results.append(result)
          }
        }
        guard !Task.isCancelled else { return }
        await MainActor.run {
          results = found
          message =
            found.isEmpty
            ? "No Ollama endpoints found."
            : "Found \(found.count) endpoint\(found.count == 1 ? "" : "s")."
          isScanning = false
        }
      } catch {
        guard !Task.isCancelled else { return }
        await MainActor.run {
          message = error.localizedDescription
          isScanning = false
        }
      }
    }
  }
}
