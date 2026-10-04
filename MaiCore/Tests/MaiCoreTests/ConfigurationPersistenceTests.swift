import Foundation
import Testing

@testable import MaiCore

@Test("Configurations save atomically and create their parent directory")
func configurationSaveRoundTrip() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("maicore-config-\(UUID().uuidString)", isDirectory: true)
  let url = root.appendingPathComponent("nested/pmai.json")
  let configuration = MaiConfiguration(
    defaultAgent: "local",
    providers: [
      ConfiguredProvider(
        id: "endpoint",
        kind: .openAICompatible,
        baseURL: URL(string: "http://127.0.0.1:1234/v1"))
    ],
    mcpServers: [
      ConfiguredMCPServer(id: "tools", url: URL(string: "https://example.com/mcp"))
    ],
    agents: [
      AgentDefinition(
        id: "local",
        instructions: "Be concise.",
        systemPrompt: "concise",
        provider: "endpoint",
        model: "local-model")
    ],
    prompts: ConfiguredPrompts(
      compact: "Summarize this conversation:\n\n{{transcript}}",
      system: ["concise": "Be concise."]),
    ui: ConfiguredTerminalUI(
      title: "review parser",
      backgroundLine: "magenta",
      foreground: "bright-white",
      promptForeground: "cyan",
      toolResultForeground: "bright-yellow",
      bold: true,
      toolResultLines: .lines(7)))

  try configuration.save(to: url)

  #expect(FileManager.default.fileExists(atPath: url.path))
  #expect(try MaiConfiguration.load(from: url) == configuration)
}

@Test("Configurations without prompt templates keep using built-in defaults")
func configurationPromptDefaults() throws {
  let configuration = try JSONDecoder().decode(
    MaiConfiguration.self,
    from: Data(#"{"version":1}"#.utf8))

  #expect(configuration.prompts == nil)
  #expect(configuration.ui.title.isEmpty)
  #expect(configuration.documentExport == DocumentExportOptions())
}

@Test("Document export options default off and persist independently")
func documentExportOptionsPersist() throws {
  let decoder = JSONDecoder()
  #expect(try decoder.decode(DocumentExportOptions.self, from: Data("{}".utf8)) == .init())
  #expect(try decoder.decode(DocumentExportOptions.self,
    from: Data(#"{"includeThinking":true}"#.utf8)) == .init(includeThinking: true))
  let configuration = MaiConfiguration(documentExport: .init(includeToolCalls: true, includeThinking: true))
  #expect(try decoder.decode(MaiConfiguration.self,
    from: JSONEncoder().encode(configuration)).documentExport == configuration.documentExport)
}

@Test("The terminal editor setting is optional and round-trips")
func terminalEditorSetting() throws {
  let unset = try JSONDecoder().decode(ConfiguredTerminalUI.self, from: Data(#"{}"#.utf8))
  #expect(unset.editor.isEmpty)

  let configured = try JSONDecoder().decode(
    ConfiguredTerminalUI.self, from: Data(#"{"editor":"code -w"}"#.utf8))
  #expect(configured.editor == "code -w")

  let saved = try JSONEncoder().encode(configured)
  #expect(try JSONDecoder().decode(ConfiguredTerminalUI.self, from: saved) == configured)
}

@Test("Compact prompt templates require the transcript placeholder")
func compactPromptRequiresTranscript() {
  let configuration = MaiConfiguration(
    prompts: ConfiguredPrompts(compact: "Summarize the chat."))

  #expect(
    throws: MaiConfigurationError.missingPromptPlaceholder(
      prompt: "compact", placeholder: "{{transcript}}")
  ) {
    try configuration.validate()
  }
}

@Test("Inline agent instructions migrate to associated reusable prompts")
func inlineInstructionsBecomeSystemPrompts() {
  var configuration = MaiConfiguration(
    providers: [ConfiguredProvider(id: "hello", kind: .hello)],
    agents: [
      AgentDefinition(
        id: "main",
        instructions: "Be concise.",
        provider: "hello",
        model: "")
    ])

  let didMigrate = configuration.associateSystemPrompts()
  #expect(didMigrate)
  #expect(configuration.agents[0].systemPrompt == "main")
  #expect(configuration.prompts?.system["main"] == "Be concise.")

  configuration.prompts?.system["main"] = "Be extremely concise."
  let didRefresh = configuration.associateSystemPrompts()
  #expect(didRefresh)
  #expect(configuration.agents[0].instructions == "Be extremely concise.")
}

@Test("Prompt and agent catalog edits keep the file consistent")
func catalogEditsStayConsistent() throws {
  var configuration = MaiConfiguration(
    providers: [ConfiguredProvider(id: "hello", kind: .hello)],
    agents: [
      AgentDefinition(id: "main", instructions: "Be concise.", provider: "hello", model: "")
    ])
  configuration.associateSystemPrompts()

  // A new prompt is unused until an agent points at it.
  let unused = configuration.setSystemPrompt("reviewer", text: "Review diffs.")
  #expect(unused == [])
  #expect(configuration.agentsUsingSystemPrompt("reviewer") == [])
  let assigned = configuration.assignSystemPrompt("reviewer", to: "main")
  #expect(assigned)
  #expect(configuration.agents[0].systemPrompt == "reviewer")
  #expect(configuration.agents[0].instructions == "Review diffs.")
  let missingPrompt = configuration.assignSystemPrompt("missing", to: "main")
  let missingAgent = configuration.assignSystemPrompt("reviewer", to: "nobody")
  #expect(!missingPrompt)
  #expect(!missingAgent)

  // Rewriting a prompt reaches every agent using it.
  let refreshed = configuration.setSystemPrompt("reviewer", text: "Review diffs carefully.")
  #expect(refreshed == ["main"])
  #expect(configuration.agents[0].instructions == "Review diffs carefully.")

  // A prompt in use cannot be dropped; an unused one can.
  let keptInUse = configuration.removeSystemPrompt("reviewer")
  let droppedUnused = configuration.removeSystemPrompt("main")
  #expect(!keptInUse)
  #expect(droppedUnused)
  #expect(configuration.prompts?.system["main"] == nil)
  let droppedTwice = configuration.removeSystemPrompt("main")
  #expect(!droppedTwice)

  // Saving an agent writes its instructions to its prompt and refreshes the
  // others sharing it; the first agent saved becomes the default.
  configuration.defaultAgent = nil
  let helper = AgentDefinition(
    id: "helper", instructions: "Review diffs briefly.", systemPrompt: "reviewer",
    provider: "hello", model: "", toolGroupNames: ["files"])
  let changed = configuration.upsertAgent(helper)
  #expect(changed == ["helper", "main"])
  #expect(configuration.prompts?.system["reviewer"] == "Review diffs briefly.")
  #expect(
    configuration.agents.map(\.instructions) == ["Review diffs briefly.", "Review diffs briefly."])
  #expect(configuration.defaultAgent == "helper")
  try configuration.validate()

  // Removing an agent clears every reference to it.
  configuration.agents[0].subagentNames = ["helper"]
  let removed = configuration.removeAgent("helper")
  #expect(removed)
  #expect(configuration.agents.map(\.id) == ["main"])
  #expect(configuration.agents[0].subagentNames.isEmpty)
  #expect(configuration.defaultAgent == "main")
  let removedTwice = configuration.removeAgent("helper")
  #expect(!removedTwice)
  try configuration.validate()
}

@Test("Approval mode is saved and legacy booleans migrate")
func approvalModePersists() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("maicore-config-\(UUID().uuidString)", isDirectory: true)
  let url = root.appendingPathComponent("pmai.json")
  let configuration = MaiConfiguration(approvals: ConfiguredApprovals(mode: .smart))

  try configuration.save(to: url)

  #expect(try MaiConfiguration.load(from: url).approvals.mode == .smart)
  let legacy = try JSONDecoder().decode(
    MaiConfiguration.self, from: Data(#"{"approvals":{"confirm":"allow"}}"#.utf8))
  #expect(legacy.approvals.mode == .ask)
  #expect(ConfiguredApprovals().mode == .yolo)
  let migrated = try JSONDecoder().decode(
    ConfiguredApprovals.self, from: Data(#"{"yolo":false}"#.utf8))
  #expect(migrated.mode == .ask)
  #expect(!String(decoding: try JSONEncoder().encode(migrated), as: UTF8.self).contains("yolo"))
}

@Test(
  "A provider's API key comes from its environment variable, else its key file, else the literal")
func providerAPIKeyFile() throws {
  let files = FileManager.default
  let keyFile = files.temporaryDirectory.appendingPathComponent("key-\(UUID().uuidString).txt")
  defer { try? files.removeItem(at: keyFile) }
  try "  sk-from-file\n".write(to: keyFile, atomically: true, encoding: .utf8)

  let provider = ConfiguredProvider(
    id: "remote", kind: .openAICompatible, apiKey: "literal",
    apiKeyEnvironment: "TEST_KEY", apiKeyFile: keyFile.path)
  #expect(try provider.resolvedAPIKey(environment: ["TEST_KEY": "from-env"]) == "from-env")
  #expect(try provider.resolvedAPIKey(environment: ["TEST_KEY": ""]) == nil)
  #expect(try provider.resolvedAPIKey(environment: [:]) == "sk-from-file")

  var fileOnly = provider
  fileOnly.apiKeyEnvironment = nil
  #expect(try fileOnly.resolvedAPIKey(environment: ["TEST_KEY": "ignored"]) == "sk-from-file")

  var literalOnly = provider
  literalOnly.apiKeyEnvironment = nil
  literalOnly.apiKeyFile = nil
  #expect(try literalOnly.resolvedAPIKey(environment: [:]) == "literal")

  var missing = fileOnly
  missing.apiKeyFile = keyFile.path + ".missing"
  #expect(throws: MaiConfigurationError.unreadableAPIKeyFile(keyFile.path + ".missing")) {
    try missing.resolvedAPIKey(environment: [:])
  }

  // The file path survives a round trip through the configuration file.
  let data = try JSONEncoder().encode(fileOnly)
  let decoded = try JSONDecoder().decode(ConfiguredProvider.self, from: data)
  #expect(decoded.apiKeyFile == keyFile.path)
  #expect(decoded == fileOnly)
}

@Test("Provider headers decode from an object, from lines, or from one line")
func providerHeaderForms() throws {
  func decode(_ headers: String) throws -> ConfiguredProvider {
    try JSONDecoder().decode(
      ConfiguredProvider.self,
      from: Data(#"{"id":"p","kind":"openAICompatible","headers":\#(headers)}"#.utf8))
  }
  let expected = ["x-opencode-session": "{{session}}", "X-Tenant": "acme"]
  #expect(
    try decode(#"{"x-opencode-session":"{{session}}","X-Tenant":"acme"}"#).headers
      == expected)
  #expect(
    try decode(
      ##"["x-opencode-session: {{session}}", " X-Tenant:acme ", "# note", "junk", ""]"##
    ).headers == expected)
  #expect(try decode(#""X-Tenant: acme""#).headers == ["X-Tenant": "acme"])
  #expect(try decode("[]").headers == [:])
  #expect(
    try JSONDecoder().decode(
      ConfiguredProvider.self, from: Data(#"{"id":"p","kind":"openAICompatible"}"#.utf8)
    ).headers == [:])
  #expect(throws: DecodingError.self) { try decode("42") }

  // Saving writes the object form, which reads back unchanged.
  let saved = try JSONEncoder().encode(try decode(#"["X-Tenant: acme"]"#))
  #expect(
    try JSONDecoder().decode(ConfiguredProvider.self, from: saved).headers == ["X-Tenant": "acme"])

  #expect(
    ProviderHeaders.lines(expected) == ["x-opencode-session: {{session}}", "X-Tenant: acme"])
  #expect(
    ProviderHeaders.parse("X-A: 1\n\nX-B: two: three\n") == ["X-A": "1", "X-B": "two: three"])
  #expect(
    ProviderHeaders.expand(expected, sessionID: "chat-1")
      == ["x-opencode-session": "chat-1", "X-Tenant": "acme"])
}
