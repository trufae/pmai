import Foundation
import MaiCore
import MaiACP
import MaiLocalProviders

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

private enum ProviderEditorError: LocalizedError {
  case invalidJSON(String)
  case expectedObject
  case unknownFields([String])
  case changedID(String)


  var errorDescription: String? {
    switch self {
    case .invalidJSON(let reason):
      return
        "Invalid provider JSON: \(reason) Check commas, matching braces, and double-quoted names and strings; JSON does not allow comments."
    case .expectedObject:
      return "The provider JSON must be an object enclosed in { }, not an array or a string."
    case .unknownFields(let fields):
      let suggestions = fields.compactMap { field -> String? in
        guard
          let match = providerEditorFieldNames.first(where: {
            $0.lowercased() == field.lowercased()
          })
        else { return nil }
        return "Use '\(match)' instead of '\(field)'."
      }
      return
        "Unknown provider field\(fields.count == 1 ? "" : "s"): \(fields.joined(separator: ", ")). "
        + suggestions.joined(separator: " ")
        + " Valid fields: \(providerEditorFieldNames.joined(separator: ", ")). Put provider-specific settings inside options. Names are case-sensitive."
    case .changedID(let id): return "Keep the id '\(id)'; /provider rename \(id) NEW renames it."

    }
  }
}

private let providerEditorFieldNames = [
  "id", "kind", "displayName", "baseURL", "defaultModel", "apiKey", "apiKeyEnvironment",
  "apiKeyFile", "headers", "headerEnvironment", "timeout", "options",
]

extension MaiCLI {
  static func handleProviderCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    providerBaseURLs: ProviderBaseURLStore,
    credentialsDirectory: URL,
    terminal: TerminalWriter
  ) async {
    let fields: [String]
    do { fields = try shellWords(argument) }
    catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return
    }
    if let command = fields.first, ["login", "logout", "status"].contains(command) {
      let id = fields.count == 2 ? fields[1] : session.profile.provider.rawValue
      guard fields.count <= 2,
        let provider = configuration?.providers.first(where: { $0.id == id }),
        provider.kind == .chatGPT
      else {
        await terminal.line(
          "Usage: /provider \(command) CHATGPT_PROVIDER_ID (add one with /provider add chatgpt --kind chatgpt)"
        )
        return
      }
      await chatGPTAccountCommand(
        command, provider: provider, directory: credentialsDirectory, terminal: terminal)
      return
    }
    guard !fields.isEmpty else {
      guard !session.profile.provider.rawValue.isEmpty else {
        await terminal.line("No provider selected. Type /about for setup commands.")
        return
      }
      let configured = configuration?.providers.first {
        $0.id == session.profile.provider.rawValue
      }
      let baseURL =
        providerBaseURLs.url(for: session.profile.provider.rawValue)?.absoluteString
        ?? configured?.baseURL?.absoluteString ?? "-"
      await terminal.line("Current provider: \(session.profile.provider) — \(baseURL)")
      if let configured {
        let names = (Array(configured.headers.keys) + Array(configured.headerEnvironment.keys))
          .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if !names.isEmpty {
          await terminal.line("Headers: \(names.joined(separator: ", "))")
        }
      }
      await terminal.line(
        "Use /help provider for local Apple/MLX setup, /provider add ID URL for remote connections, or /edit provider [ID] for options."
      )
      return
    }

    if ["del", "delete", "remove"].contains(fields[0].lowercased()) {
      guard fields.count == 2 else {
        await terminal.line("Usage: /provider del ID")
        return
      }
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      let id = fields[1]
      do {
        guard session.profile.provider.rawValue != id else {
          throw MaiConfigurationError.invalidFile(
            "Provider '\(id)' is this chat's provider; switch with /provider use OTHER first.")
        }
        let taskIDs = Set(AgentTask.allCases.compactMap { draft.taskAgents[$0] })
        let reassigned = draft.agents.indices.filter {
          taskIDs.contains(draft.agents[$0].id) && draft.agents[$0].provider.rawValue == id
        }
        for index in reassigned {
          draft.agents[index].provider = session.profile.provider
          draft.agents[index].model = session.profile.model
        }
        try draft.removeProvider(id)
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        for index in reassigned {
          try await runtime.register(agent: draft.agents[index], replacingExisting: true)
        }
        await runtime.unregister(providerID: ProviderID(id))
        providerBaseURLs.set(nil, for: id)
        configuration = draft
        if !reassigned.isEmpty {
          let names = reassigned.map { draft.agents[$0].id }.sorted().joined(separator: ", ")
          await terminal.line(
            "Task agents moved to \(session.profile.provider)::\(session.profile.model): \(names).")
        }
        await terminal.line(
          "Provider '\(id)' removed (saved). Other saved chats keep their own connection snapshots.")
      } catch { await terminal.line("error: \(error.localizedDescription)", to: .standardError) }
      return
    }

    if fields[0].lowercased() == "rename" {
      guard (2...3).contains(fields.count), var draft = configuration, let configurationPath else {
        await terminal.line("Usage: /provider rename [OLD] NEW")
        return
      }
      let oldID = fields.count == 3 ? fields[1] : session.profile.provider.rawValue
      let newID = fields.last!
      do {
        try draft.renameProvider(oldID, to: newID)
        guard oldID != newID else {
          await terminal.line("Provider '\(oldID)' already has that name.")
          return
        }
        var provider = draft.providers.first { $0.id == newID }!
        let effectiveURL = providerBaseURLs.url(for: oldID) ?? provider.baseURL
        provider.baseURL = effectiveURL
        let built = try await plugins.makeProvider(
          from: provider, environment: ProcessInfo.processInfo.environment)
        guard await runtime.availableProviders().contains(where: { $0.id.rawValue == oldID }) else {
          throw MaiConfigurationError.unknownProvider(oldID)
        }
        guard !(await runtime.availableProviders().contains(where: { $0.id.rawValue == newID }))
        else {
          throw MaiConfigurationError.duplicateIdentifier(kind: "provider", id: newID)
        }
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        try await runtime.renameProvider(ProviderID(oldID), to: built)
        configuration = draft
        if session.profile.provider.rawValue == oldID {
          session.profile.provider = ProviderID(newID)
        }
        providerBaseURLs.set(nil, for: oldID)
        providerBaseURLs.set(effectiveURL, for: newID)
        await terminal.line(
          "Provider '\(oldID)' renamed to '\(newID)' (saved; agent references updated).")
      } catch { await terminal.line("error: \(error.localizedDescription)", to: .standardError) }
      return
    }

    if fields[0] == "add" {
      guard fields.count >= 2 else {
        await terminal.line(providerHelp)
        return
      }
      if fields[1].lowercased() == "acp" {
        do {
          let provider = try ACPProviderCommand.configuration(Array(fields.dropFirst(2)))
          guard var draft = configuration, let configurationPath else {
            throw JSONRPCError.invalidParams("No writable configuration is active")
          }
          guard !draft.providers.contains(where: { $0.id == provider.id }) else {
            throw MaiConfigurationError.duplicateIdentifier(kind: "provider", id: provider.id)
          }
          let instance = try await plugins.makeProvider(from: provider, environment: ProcessInfo.processInfo.environment)
          draft.providers.append(provider)
          try draft.save(to: URL(fileURLWithPath: configurationPath))
          try await runtime.register(instance)
          configuration = draft
          if let catalog = ACPCatalog.agent(provider.id), !catalog.isInstalled, let install = catalog.install {
            await terminal.line("Install the ACP adapter with: \(install)")
          }
          await terminal.line("ACP provider '\(provider.id)' saved. /provider use \(provider.id) selects it; /models \(provider.id) lists its models.")
        } catch { await terminal.line("error: \(error.localizedDescription)", to: .standardError) }
        return
      }
      var offset = 2
      var url: URL?
      if fields.count > offset, !fields[offset].hasPrefix("--") {
        guard let parsed = URL(string: fields[offset]),
          ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil
        else {
          await terminal.line("Usage: /provider add ID [BASE_URL] [--kind apple|mlx|chatgpt|openai|systemone] [--model MODEL] [--api-key KEY | --api-key-file PATH]")
          return
        }
        url = parsed
        offset += 1
      }
      let flags = Array(fields.dropFirst(offset))
      var kind: ConfiguredProviderKind = url == nil && ["apple", "mlx"].contains(fields[1])
        ? ConfiguredProviderKind(fields[1]) : .openAICompatible
      var keyFile: String?
      var apiKey: String?
      var model: String?
      var validFlags = flags.count.isMultiple(of: 2)
      if validFlags {
        for index in stride(from: 0, to: flags.count, by: 2) {
          switch flags[index] {
          case "--kind":
            let value = flags[index + 1]
            kind = value.lowercased() == "openaicompatible" ? .openAICompatible
              : ConfiguredProviderKind(value.lowercased())
          case "--api-key-file": keyFile = flags[index + 1]
          case "--api-key": apiKey = flags[index + 1]
          case "--model": model = flags[index + 1]
          default: validFlags = false
          }
        }
      }
      let local = [.apple, .mlx].contains(kind)
      let subscription = kind == .chatGPT
      guard validFlags, apiKey == nil || keyFile == nil,
        subscription
          ? (url == nil && apiKey == nil && keyFile == nil) : (local ? url == nil : url != nil),
        var draft = configuration, let configurationPath
      else {
        await terminal.line(
          "Usage: /provider add ID [BASE_URL] [--kind apple|mlx|chatgpt|openai|systemone] [--model MODEL] [--api-key KEY | --api-key-file PATH] (Apple/MLX/ChatGPT use no URL)"
        )
        return
      }
      guard !draft.providers.contains(where: { $0.id == fields[1] }) else {
        await terminal.line(
          "Provider '\(fields[1])' already exists; /edit provider \(fields[1]) edits it.")
        return
      }
      let provider = ConfiguredProvider(
        id: fields[1], kind: kind, baseURL: url,
        defaultModel: model
          ?? (kind == .apple
            ? AppleProvider.modelID
            : kind == .mlx ? MLXProvider.defaultModelID : nil),
        apiKey: apiKey, apiKeyFile: keyFile,
        options: subscription ? ["account": .string(UUID().uuidString)] : [:])
      do {
        let instance = try await plugins.makeProvider(
          from: provider, environment: ProcessInfo.processInfo.environment)
        draft.providers.append(provider)
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        try await runtime.register(instance)
        configuration = draft
        providerBaseURLs.set(url, for: provider.id)
        if subscription {
          await terminal.line(
            "ChatGPT provider '\(provider.id)' saved. Continue with ChatGPT: /provider login \(provider.id)"
          )
          return
        }
        await terminal.line(
          "Provider '\(provider.id)' saved. /models \(provider.id) lists models; /model \(provider.id)::MODEL selects one."
        )
      } catch { await terminal.line("error: \(error.localizedDescription)", to: .standardError) }
      return
    }

    if ["baseurl", "url"].contains(fields[0].lowercased()) {
      await handleBaseURLCommand(
        fields.dropFirst().joined(separator: " "),
        currentProvider: session.profile.provider,
        configuration: configuration,
        providerBaseURLs: providerBaseURLs,
        terminal: terminal)
      return
    }

    guard fields.count == 1 || (fields[0].lowercased() == "use" && fields.count == 2) else {
      await terminal.line(
        "Usage: /provider [use] ID · /provider add ID URL · /provider del ID · /provider rename [OLD] NEW")
      return
    }
    let selectedID = fields.count == 2 ? fields[1] : fields[0]
    let id = ProviderID(selectedID)
    guard await runtime.availableProviders().contains(where: { $0.id == id }) else {
      await terminal.line("Unknown provider '\(selectedID)'. Use /providers.")
      return
    }
    session.profile.provider = id
    if let defaultModel = configuration?.providers.first(where: { $0.id == selectedID })?
      .defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines), !defaultModel.isEmpty
    {
      session.profile.model = defaultModel
    }
    let saved = await persistAgentProfile(
      session: session,
      configuration: &configuration,
      configurationPath: configurationPath,
      makeDefault: true,
      runtime: runtime,
      terminal: terminal)
    if saved {
      await terminal.line(
        "Provider: \(id) (saved for agent \(session.profile.agentID)) · default for new chats")
    }
  }

  static func handleBaseURLCommand(
    _ argument: String,
    currentProvider: ProviderID,
    configuration: MaiConfiguration?,
    providerBaseURLs: ProviderBaseURLStore,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(whereSeparator: \Character.isWhitespace).map(String.init)
    let queryingID =
      fields.count == 1 && configuration?.providers.contains { $0.id == fields[0] } == true
    let providerID = fields.count == 2 || queryingID ? ProviderID(fields[0]) : currentProvider
    guard !fields.isEmpty, !queryingID else {
      let configuredURL = configuration?.providers.first {
        $0.id == providerID.rawValue
      }?.baseURL
      let effectiveURL = providerBaseURLs.url(for: providerID.rawValue) ?? configuredURL
      var detail = effectiveURL?.absoluteString ?? "-"
      if let effectiveURL, let configuredURL, effectiveURL != configuredURL {
        detail += " (runtime override; configured: \(configuredURL.absoluteString))"
      }
      await terminal.line("Base URL for '\(providerID)': \(detail)")
      return
    }
    let editID = fields.count >= 2 && configuration?.providers.contains { $0.id == fields[0] } == true
      ? fields[0] : currentProvider.rawValue
    await terminal.line("Change baseURL with /edit provider \(editID).")
  }

  /// Opens one configured provider as JSON, the way `/edit agent` opens an
  /// agent, and rebuilds it in the live runtime once the file is saved, so a
  /// new header or base URL takes effect without a restart.
  static func editConfiguredProvider(
    named id: String,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    providerBaseURLs: ProviderBaseURLStore,
    terminal: TerminalWriter
  ) async {
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    guard let index = draft.providers.firstIndex(where: { $0.id == id }) else {
      await terminal.line("Unknown configured provider '\(id)'. /providers lists them.")
      return
    }
    do {
      let encoder = JSONEncoder()
      let providerData = try encoder.encode(draft.providers[index])
      var fields = try JSONSerialization.jsonObject(with: providerData) as! [String: Any]
      fields["_credentialHelp"] = [
        "Help is regenerated from the current provider when this editor opens; it is not saved.",
        "Keep id unchanged. kind is case-sensitive: openai, chatgpt, systemone, apple, mlx, hello, or a registered plugin kind. Legacy openAICompatible is accepted as openai.",
        "chatgpt uses /provider login ID, with no baseURL or API key. Keep options.account unchanged to retain its account registration.",
        "baseURL: the remote API endpoint, such as https://api.openai.com/v1.",
        "defaultModel: the model ID to use when no model is explicitly selected.",
        "Optional fields can be null or removed. Set unused credential fields to null when switching sources.",
        "apiKeyEnvironment: the NAME of an exported variable, such as OPENAI_API_KEY.",
        "apiKeyFile: a path to a file containing the key.",
        "apiKey: the key itself; this saves the secret in the config file.",
        "Credential precedence: a set environment variable (even empty), then apiKeyFile, then apiKey.",
        "Export variables before starting pmai. For custom auth, use headers or headerEnvironment.",
        "headers: an object such as {\"X-Tenant\": \"value\"}, or an array of \"X-Tenant: value\" strings; {{session}} expands to the chat session ID.",
        "headerEnvironment: an object mapping header names to exported variable NAMES; these override headers of the same name.",
        "timeout: a positive number of seconds, or null for the provider default.",
        "options: an object containing provider-specific settings; preserve options you still use.",
      ]
      for key in [
        "displayName", "baseURL", "defaultModel", "apiKey", "apiKeyEnvironment", "apiKeyFile",
        "timeout",
      ]
      where fields[key] == nil {
        fields[key] = NSNull()
      }
      var data = try JSONSerialization.data(
        withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
      var retrying = false
      var validated: (provider: ConfiguredProvider, built: any ChatProvider)?
      while let edited = await editTemporaryData(
        data, suffix: "provider-\(id).json", terminal: terminal)
      {
        if edited == data {
          if retrying {
            await terminal.line("Provider edit canceled; the invalid draft was not saved.")
          }
          return
        }
        data = edited
        do {
          try validateProviderEditorFields(in: edited)
          let provider = try JSONDecoder().decode(ConfiguredProvider.self, from: edited)
          guard provider.id == id else { throw ProviderEditorError.changedID(id) }
          try provider.validate()
          let built = try await plugins.makeProvider(
            from: provider, environment: ProcessInfo.processInfo.environment)
          var candidate = draft
          candidate.providers[index] = provider
          try candidate.validate()
          validated = (provider, built)
          break
        } catch {
          await terminal.line(
            "error: \(providerEditorErrorDescription(error))",
            to: .standardError)
          // The REPL reader is parked during /edit. Use its terminal surface
          // for this prompt so Ctrl+C, Ctrl+D and Ctrl+Z keep their usual meaning.
          guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else { return }
          let reader = TerminalLineEditor()
          reader.install(surface: TerminalScreen.current)
          guard
            let answer = reader.readLine(
              prompt: "Press Enter to reopen the provider editor (Ctrl+C to cancel)> ",
              completions: [], rememberInput: false), !reader.wasInterrupted, answer.isEmpty
          else {
            await terminal.line("Provider edit canceled; the invalid draft was not saved.")
            return
          }
          retrying = true
        }
      }
      guard let validated else { return }
      let (provider, built) = validated
      try await runtime.register(built, replacingExisting: true)
      draft.providers[index] = provider
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      providerBaseURLs.set(provider.baseURL, for: id)
      await terminal.line("Provider '\(id)' saved to \(configurationPath) and reloaded.")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func validateProviderEditorFields(in data: Data) throws {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
      throw ProviderEditorError.invalidJSON(error.localizedDescription)
    }
    guard let fields = object as? [String: Any] else { throw ProviderEditorError.expectedObject }
    let valid = Set(providerEditorFieldNames + ["_credentialHelp"])
    let unknown = fields.keys.filter { !valid.contains($0) }.sorted()
    if !unknown.isEmpty { throw ProviderEditorError.unknownFields(unknown) }
  }

  private static func providerEditorErrorDescription(_ error: Error) -> String {
    if let configuration = error as? MaiConfigurationError {
      let suggestion: String
      switch configuration {
      case .providerMissingBaseURL:
        suggestion = "Set baseURL to the API endpoint, for example https://api.openai.com/v1."
      case .missingEnvironmentVariable(let name):
        suggestion =
          "Export \(name) before starting pmai, or change the corresponding headerEnvironment entry to an exported variable."
      case .unreadableAPIKeyFile:
        suggestion =
          "Check apiKeyFile's path and read permissions, or set apiKeyFile to null and use apiKeyEnvironment or apiKey."
      default: suggestion = ""
      }
      return configuration.localizedDescription + (suggestion.isEmpty ? "" : " " + suggestion)
    }
    if case PluginRegistryError.factoryNotRegistered(_, _) = error {
      return error.localizedDescription
        + " Check kind's spelling and case (for example openai); custom kinds require their provider plugin to be loaded."
    }
    guard let decoding = error as? DecodingError else { return error.localizedDescription }
    let context: DecodingError.Context
    let missingKey: String?
    switch decoding {
    case .keyNotFound(let key, let details):
      context = details
      missingKey = key.stringValue
    case .typeMismatch(_, let details), .valueNotFound(_, let details), .dataCorrupted(let details):
      context = details
      missingKey = nil
    @unknown default: return error.localizedDescription
    }
    let path = context.codingPath.map(\.stringValue) + (missingKey.map { [$0] } ?? [])
    let field = path.joined(separator: ".")
    let suggestion: String
    switch path.first {
    case "headers":
      suggestion =
        "Use an object of header names to string values, such as {\"X-Tenant\": \"value\"}, or an array of \"Name: value\" strings."
    case "headerEnvironment":
      suggestion =
        "Use an object mapping header names to environment variable names, such as {\"X-Token\": \"TOKEN\"}."
    case "options": suggestion = "Use a JSON object for options, such as {}."
    case "timeout": suggestion = "Use a positive number of seconds, such as 600, or null."
    case "id", "kind": suggestion = "Keep this required field as a non-empty, double-quoted string."
    case "baseURL":
      suggestion = "Use a double-quoted API URL, such as \"https://api.openai.com/v1\"."
    default: suggestion = "Use a double-quoted string, or null for an unused optional field."
    }
    return
      "Invalid value\(field.isEmpty ? "" : " for '\(field)'"): \(context.debugDescription) \(suggestion)"
  }

  static func apiKeyEnvironmentName(for providerID: String) -> String {
    if providerID.lowercased() == "openai" { return "OPENAI_API_KEY" }
    let stem = providerID.uppercased().map { character in
      character.isLetter || character.isNumber ? character : "_"
    }
    return String(stem) + "_API_KEY"
  }
}
