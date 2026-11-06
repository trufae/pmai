import AVFoundation
import MaiCore
import MaiOpenAI
import SwiftUI

@MainActor
private enum TTSVoiceCache {
  static var voices: [AVSpeechSynthesisVoice] {
    SystemLanguageSupport.textToSpeechVoices.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  static var languages: [String] { SystemLanguageSupport.textToSpeechLanguageIdentifiers }

  static var primaryLanguages: [String] {
    let primaries = Set(languages.compactMap(SystemLanguageSupport.primaryLanguageCode))
    return Array(primaries).sorted {
      SystemLanguageSupport.primaryLanguageDisplayName($0)
        .localizedCaseInsensitiveCompare(SystemLanguageSupport.primaryLanguageDisplayName($1)) == .orderedAscending
    }
  }

  static func voiceOptions(for language: String) -> [AVSpeechSynthesisVoice] {
    let normalized = SystemLanguageSupport.canonicalLanguageIdentifier(language)
    let filtered =
      normalized.isEmpty
      ? voices
      : voices.filter {
        SystemLanguageSupport.canonicalLanguageIdentifier($0.language) == normalized
      }
    return filtered.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  static func variants(forPrimary primary: String) -> [String] {
    languages
      .filter { SystemLanguageSupport.primaryLanguageCode($0) == primary }
      .sorted {
        SystemLanguageSupport.variantDisplayName($0)
          .localizedCaseInsensitiveCompare(SystemLanguageSupport.variantDisplayName($1)) == .orderedAscending
      }
  }
}

private enum VoiceTestPhrases {
  // Keyed by primary BCP-47 subtag (e.g. "es" for "es-ES").
  static let phrases: [String: String] = [
    "en": "Hello, this is a voice test.",
    "es": "Hola, esta es una prueba de voz.",
    "ca": "Hola, això és una prova de veu.",
    "fr": "Bonjour, ceci est un test vocal.",
    "de": "Hallo, das ist ein Stimmtest.",
    "it": "Ciao, questa è una prova vocale.",
    "pt": "Olá, este é um teste de voz.",
    "nl": "Hallo, dit is een stemtest.",
    "sv": "Hej, det här är ett rösttest.",
    "no": "Hei, dette er en stemmetest.",
    "da": "Hej, dette er en stemmetest.",
    "fi": "Hei, tämä on äänitesti.",
    "pl": "Cześć, to jest test głosu.",
    "tr": "Merhaba, bu bir ses testidir.",
    "ru": "Привет, это проверка голоса.",
    "uk": "Привіт, це перевірка голосу.",
    "ja": "こんにちは、これは音声テストです。",
    "zh": "你好，这是一次语音测试。",
    "ko": "안녕하세요, 이것은 음성 테스트입니다.",
    "ar": "مرحبًا، هذا اختبار للصوت.",
    "he": "שלום, זוהי בדיקת קול.",
    "hi": "नमस्ते, यह आवाज़ का परीक्षण है।",
    "th": "สวัสดี นี่คือการทดสอบเสียง",
    "vi": "Xin chào, đây là một bài kiểm tra giọng nói.",
    "id": "Halo, ini adalah tes suara.",
    "el": "Γειά σας, αυτή είναι μια δοκιμή φωνής.",
    "cs": "Ahoj, toto je hlasový test.",
    "ro": "Salut, acesta este un test de voce.",
    "hu": "Helló, ez egy hangteszt.",
  ]

  static func phrase(forLanguageTag tag: String) -> String {
    let primary = tag.split(separator: "-").first.map(String.init)?.lowercased() ?? ""
    if let exact = phrases[primary] { return exact }
    return phrases["en"] ?? "Hello, this is a voice test."
  }
}

private enum VoiceTest {
  static func tag(for role: VoiceRole) -> String {
    "settings-test:\(role.rawValue)"
  }

  static func effectiveLanguage(for voice: RoleVoiceSettings) -> String {
    if voice.provider == .openAICompatible { return Locale.current.identifier }
    if !voice.language.isEmpty { return voice.language }
    if !voice.voiceIdentifier.isEmpty,
      let v = AVSpeechSynthesisVoice(identifier: voice.voiceIdentifier)
    {
      return v.language
    }
    return Locale.current.identifier
  }

  @MainActor
  static func toggle(
    role: VoiceRole,
    voice: RoleVoiceSettings,
    openAIEndpoints: [OpenAIEndpoint],
    player: TTSPlayer
  ) {
    let tag = tag(for: role)
    if player.isPlaying(tag: tag) {
      player.stop()
      return
    }
    let phrase = VoiceTestPhrases.phrase(forLanguageTag: effectiveLanguage(for: voice))
    player.speak(
      text: phrase,
      voice: voice,
      role: role,
      title: "Voice Test",
      tag: tag,
      openAIEndpoints: openAIEndpoints)
  }
}

private enum VoiceProviderSelection: Hashable {
  case system
  case unavailable
  case openAI(UUID)
}

struct RoleVoiceSettingsView: View {
  @EnvironmentObject private var store: AppStore
  @EnvironmentObject private var ttsPlayer: TTSPlayer
  let role: VoiceRole
  @Binding var voice: RoleVoiceSettings
  @State private var draftSpeechEndpoint = OpenAIEndpoint(name: "OpenAI Speech")
  @State private var voiceRefreshGeneration = 0
  @State private var isRefreshingVoices = false
  @State private var voiceDiscoveryError: String?

  var body: some View {
    Form {
      Section {
        Picker("Provider", selection: providerBinding) {
          Text("System").tag(VoiceProviderSelection.system)
          if voice.provider == .openAICompatible, voice.openAIEndpointID == nil {
            Text("Select a provider").tag(VoiceProviderSelection.unavailable)
          }
          if let id = voice.openAIEndpointID,
            !store.settings.openAIEndpoints.contains(where: { $0.id == id })
          {
            Text("Unavailable saved provider").tag(VoiceProviderSelection.openAI(id))
          }
          ForEach(openAIVoiceEndpoints) { endpoint in
            Text(endpoint.displayName + (endpoint.isSelectableForSpeech ? "" : " (unavailable)"))
              .tag(VoiceProviderSelection.openAI(endpoint.id))
              .disabled(store.settings.isOffline || !endpoint.isSelectableForSpeech)
          }
        }
      } footer: {
        Text(
          store.settings.isOffline
            ? "Airplane Mode is on. Provider voices are unavailable."
            : "Choose System or an OpenAI API-compatible speech provider. Chat and speech can use different providers."
        )
      }

      Section {
        if store.settings.openAIEndpoints.contains(where: { $0.kind == .chatGPT }) {
          Text(OpenAIEndpoint.chatGPTSpeechUnavailableMessage)
            .font(.callout)
        }
        DisclosureGroup("Browse Built-in Voices") {
          ForEach(OpenAISpeech.voices, id: \.self) { name in
            Text(name)
          }
          Text(
            "Available with \(OpenAISpeech.defaultModel). Older speech models have fewer voices."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        NavigationLink("Add OpenAI Speech Provider") {
          EndpointDetailView(endpoint: $draftSpeechEndpoint) { endpoint in
            if let index = store.settings.openAIEndpoints.firstIndex(where: { $0.id == endpoint.id }
            ) {
              store.settings.openAIEndpoints[index] = endpoint
            } else {
              store.settings.openAIEndpoints.append(endpoint)
            }
            voice.selectSpeechProvider(
              endpoint, discovered: store.endpointVoices[endpoint.id] ?? [])
          }
        }
        .disabled(store.settings.isOffline)
      } header: {
        Text("OpenAI Voices")
      } footer: {
        Text(
          "OpenAI speech requires an API key and is billed separately from a ChatGPT subscription.")
      }

      if showsOpenAIVoiceSettings {
        Section {
          if let endpoint = selectedOpenAIEndpoint {
            FilteredModelPicker(
              selection: speechModelBinding, models: speechCatalog(endpoint), endpoint: nil,
              title: "Speech Model", emptySelectionTitle: "Provider default",
              initialFeatures: [.voice], requiredCapabilities: [.audioOutput],
              refresh: { await store.refreshEndpoint(endpoint, force: true) })
              .task(id: endpoint.connectionSignature) { await store.refreshEndpoint(endpoint) }
          }
        } footer: {
          Text(
            "The speech model is shared by voices using this provider and is separate from its chat model."
          )
        }
        Section {
          openAIVoicePicker
          if selectedOpenAIEndpoint?.isSelectableForSpeech == true,
            selectedOpenAIEndpoint?.isDirectOpenAI != true
          {
            TextField("Voice ID", text: voiceBinding(\.openAIVoice))
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            Button {
              voiceRefreshGeneration += 1
            } label: {
              if isRefreshingVoices {
                HStack {
                  ProgressView()
                  Text("Refreshing Voices...")
                }
              } else {
                Label("Refresh Voices", systemImage: "arrow.clockwise")
              }
            }
            .disabled(isRefreshingVoices)
          }
        } footer: {
          if selectedOpenAIEndpoint?.isDirectOpenAI == true {
            Text(
              "OpenAI voices are AI-generated. Test Voice sends a paid synthesis request using your provider credentials."
            )
          } else if selectedEndpointVoices.isEmpty {
            Text(
              "Refresh voices or enter a voice ID from your speech provider. Some providers do not offer voice discovery."
            )
          } else {
            Text("Provider voices are requested as WAV audio from /v1/audio/speech.")
          }
        }
        if let issue = providerVoiceIssue {
          Section { Text(issue).foregroundStyle(.red) }
        }
        if let voiceDiscoveryError {
          Section("Voice Discovery") {
            Text(voiceDiscoveryError).foregroundStyle(.secondary)
          }
        }
      } else {
        Section {
          Picker("Language", selection: voicePrimaryLanguageBinding) {
            Text("System Default").tag("")
            ForEach(TTSVoiceCache.primaryLanguages, id: \.self) { primary in
              Text(SystemLanguageSupport.primaryLanguageDisplayName(primary)).tag(primary)
            }
          }

          let variants = TTSVoiceCache.variants(
            forPrimary: voicePrimaryLanguageBinding.wrappedValue)
          if variants.count > 1 {
            Picker("Region", selection: voiceBinding(\.language)) {
              ForEach(variants, id: \.self) { id in
                Text(SystemLanguageSupport.variantDisplayName(id)).tag(id)
              }
            }
          }

          Picker("Voice", selection: voiceBinding(\.voiceIdentifier)) {
            Text("Default Voice").tag("")
            ForEach(TTSVoiceCache.voiceOptions(for: voice.language), id: \.identifier) { option in
              Text(option.name).tag(option.identifier)
            }
          }
        }

        Section {
          LabeledContent("Rate") {
            Slider(value: voiceBinding(\.rate), in: 0...1, step: 0.05)
          }

          LabeledContent("Pitch") {
            Slider(value: voiceBinding(\.pitch), in: 0.5...2, step: 0.05)
          }
        }
      }

      Section {
        Button {
          VoiceTest.toggle(
            role: role,
            voice: effectiveVoice,
            openAIEndpoints: store.settings.isOffline
              ? [] : store.settings.openAIEndpoints,
            player: ttsPlayer)
        } label: {
          let isPlaying = ttsPlayer.isPlaying(tag: VoiceTest.tag(for: role))
          Label(
            isPlaying ? "Stop Test" : "Test Voice",
            systemImage: isPlaying ? "stop.circle" : "play.circle")
        }
        .disabled(
          !ttsPlayer.isPlaying(tag: VoiceTest.tag(for: role))
            && showsOpenAIVoiceSettings && providerVoiceIssue != nil)
      }
      if let error = ttsPlayer.errorMessage {
        Section("Speech Error") {
          Text(error).foregroundStyle(.red)
          Button("Dismiss") { ttsPlayer.dismissError() }
        }
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .task(id: voiceDiscoveryKey) { await refreshSelectedVoices() }
    .onChange(of: voice.language) { _, newLanguage in
      guard effectiveVoice.provider == .system else { return }
      guard !newLanguage.isEmpty,
        let selectedVoice = TTSVoiceCache.voices.first(where: {
          $0.identifier == voice.voiceIdentifier
        }),
        selectedVoice.language != newLanguage
      else { return }
      voice.voiceIdentifier = ""
    }
  }

  private var title: String {
    switch role {
    case .user: "User"
    case .assistant: "Assistant"
    }
  }

  private var effectiveVoice: RoleVoiceSettings {
    store.settings.isOffline ? voice.withoutOnlineProvider() : voice
  }

  private var showsOpenAIVoiceSettings: Bool {
    effectiveVoice.provider == .openAICompatible
  }

  private func voiceBinding<Value>(_ keyPath: WritableKeyPath<RoleVoiceSettings, Value>)
    -> Binding<Value>
  {
    Binding(
      get: { voice[keyPath: keyPath] },
      set: { newValue in
        var copy = voice
        copy[keyPath: keyPath] = newValue
        voice = copy
      })
  }

  private var voicePrimaryLanguageBinding: Binding<String> {
    Binding(
      get: {
        let lang = voice.language
        if lang.isEmpty { return "" }
        return SystemLanguageSupport.primaryLanguageCode(lang) ?? ""
      },
      set: { newPrimary in
        var copy = voice
        if newPrimary.isEmpty {
          copy.language = ""
        } else {
          let variants = TTSVoiceCache.variants(forPrimary: newPrimary)
          if !variants.contains(copy.language) {
            copy.language = variants.first ?? ""
          }
        }
        voice = copy
      })
  }

  private var providerBinding: Binding<VoiceProviderSelection> {
    Binding(
      get: {
        guard !store.settings.isOffline else { return .system }
        if voice.provider == .openAICompatible {
          return voice.openAIEndpointID.map(VoiceProviderSelection.openAI) ?? .unavailable
        }
        return .system
      },
      set: { selection in
        var copy = voice
        switch selection {
        case .system:
          copy.provider = .system
        case .unavailable:
          return
        case .openAI(let id):
          guard !store.settings.isOffline,
            let endpoint = store.settings.openAIEndpoints.first(where: { $0.id == id })
          else { return }
          copy.selectSpeechProvider(endpoint, discovered: store.endpointVoices[id] ?? [])
        }
        voice = copy
      })
  }

  @ViewBuilder
  private var openAIVoicePicker: some View {
    Picker("Voice", selection: voiceBinding(\.openAIVoice)) {
      Text("Select a voice").tag("")
      ForEach(openAIVoiceOptions, id: \.self) { option in
        Text(option).tag(option)
      }
    }
  }

  private var openAIVoiceOptions: [String] {
    var options = selectedEndpointVoices
    let current = voice.openAIVoice.trimmingCharacters(in: .whitespacesAndNewlines)
    if !current.isEmpty && !options.contains(current) {
      options.insert(current, at: 0)
    }
    return options
  }

  private var selectedEndpointVoices: [String] {
    guard !store.settings.isOffline else { return [] }
    guard voice.provider == .openAICompatible,
      let id = voice.openAIEndpointID
    else { return [] }
    return selectedOpenAIEndpoint?.speechVoices(discovered: store.endpointVoices[id] ?? []) ?? []
  }

  private var openAIVoiceEndpoints: [OpenAIEndpoint] {
    guard !store.settings.isOffline else { return [] }
    return store.settings.openAIEndpoints.filter { endpoint in
      endpoint.isSelectableForSpeech
        || endpoint.id == voice.openAIEndpointID
    }
  }

  private var selectedOpenAIEndpoint: OpenAIEndpoint? {
    guard let id = voice.openAIEndpointID else { return nil }
    return store.settings.openAIEndpoints.first(where: { $0.id == id })
  }

  private var voiceDiscoveryKey: [String] {
    [
      selectedOpenAIEndpoint?.effectiveSpeechModel ?? "",
      effectiveVoice.provider.rawValue,
      selectedOpenAIEndpoint?.id.uuidString ?? "",
      selectedOpenAIEndpoint?.connectionSignature ?? "",
      String(selectedOpenAIEndpoint?.isEnabled == true),
      String(voiceRefreshGeneration),
    ]
  }

  private func speechCatalog(_ endpoint: OpenAIEndpoint) -> [MaiCore.ModelDescriptor] {
    var models = store.endpointModelDescriptors[endpoint.id] ?? []
    for id in endpoint.availableSpeechModels where !models.contains(where: { $0.id == id }) {
      models.append(.init(id: id, capabilities: [.audioOutput]))
    }
    // Built-in speech catalogs have authoritative task metadata even when /models omits it.
    for index in models.indices where endpoint.availableSpeechModels.contains(models[index].id) {
      models[index].capabilities.insert(.audioOutput)
    }
    return models
  }

  private var speechModelBinding: Binding<String> {
    Binding(
      get: { selectedOpenAIEndpoint?.speechModel ?? "" },
      set: { value in
        guard
          let index = store.settings.openAIEndpoints.firstIndex(where: {
            $0.id == voice.openAIEndpointID
          })
        else { return }
        store.settings.openAIEndpoints[index].speechModel = value
        store.saveSettings()
      })
  }

  private var providerVoiceIssue: String? {
    guard let endpoint = selectedOpenAIEndpoint else {
      return "The saved voice provider is missing or disabled. Select an enabled provider."
    }
    if let reason = endpoint.speechUnavailableReason { return reason }
    let selectedVoice = voice.openAIVoice.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !selectedVoice.isEmpty else { return "Select a voice before speaking." }
    if endpoint.isDirectOpenAI {
      do {
        try OpenAISpeech.validate(voice: selectedVoice, model: endpoint.effectiveSpeechModel)
      } catch { return error.localizedDescription }
    }
    return nil
  }

  private func refreshSelectedVoices() async {
    voiceDiscoveryError = nil
    isRefreshingVoices = false
    guard showsOpenAIVoiceSettings, let endpoint = selectedOpenAIEndpoint,
      endpoint.isSelectableForSpeech, !endpoint.isDirectOpenAI
    else { return }
    isRefreshingVoices = true
    let requestKey = voiceDiscoveryKey
    do {
      let voices = try await OpenAICompatibleProvider.fetchVoices(endpoint: endpoint)
      try Task.checkCancellation()
      guard requestKey == voiceDiscoveryKey else { return }
      store.endpointVoices[endpoint.id] = voices
      if voice.openAIVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        voice.selectSpeechProvider(endpoint, discovered: voices)
      }
    } catch {
      guard !Task.isCancelled, requestKey == voiceDiscoveryKey else { return }
      voiceDiscoveryError =
        "Could not load voices: \(error.localizedDescription) You can still enter a voice ID manually."
    }
    isRefreshingVoices = false
  }
}
