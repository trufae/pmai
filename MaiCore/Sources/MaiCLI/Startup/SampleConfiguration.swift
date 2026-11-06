import Foundation
import MaiCore
import MaiLocalProviders
import MaiStandardTools
import MaiVisionOCR

extension MaiCLI {
  static func sampleConfiguration() -> MaiConfiguration {
    var configuration = MaiConfiguration(
      defaultAgent: "hello",
      plugins: [
        ConfiguredPlugin(path: "./plugins/example.dylib", enabled: false)
      ],
      providers: [
        ConfiguredProvider(id: "hello", kind: .hello),
        ConfiguredProvider(
          id: "openai",
          kind: .openAICompatible,
          baseURL: URL(string: "https://api.openai.com/v1"),
          apiKeyEnvironment: "OPENAI_API_KEY"),
      ] + MaiLocalProvidersPlugin.defaultProviders,
      toolSources: [
        ConfiguredToolSource(
          id: "standard-tools",
          kind: MaiStandardToolsPlugin.factoryKind,
          options: [
            "webSearchProvider": .string(MaiWebSearchProvider.exa.rawValue),
            "weatherLocation": .string(""),
            "githubAPIKeyEnvironment": .string("GITHUB_TOKEN"),
            "mastodonInstance": .string("mastodon.social"),
            "mastodonAPIKeyEnvironment": .string("MASTODON_API_KEY"),
            "mastodonWriteEnabled": .bool(false),
          ]),
        ConfiguredToolSource(id: "example-tools", kind: "example", enabled: false),
      ],
      ocrProviders: [
        ConfiguredOCRProvider(
          id: MaiVisionOCRPlugin.preferredFactoryKind,
          kind: MaiVisionOCRPlugin.preferredFactoryKind)
      ],
      mcpServers: [
        ConfiguredMCPServer(
          id: "remote",
          enabled: false,
          displayName: "Example MCP",
          url: URL(string: "https://your-mcp.example/mcp")!,
          bearerTokenEnvironment: "MCP_API_KEY",
          toolNamePrefix: "remote",
          defaultApproval: .confirm),
        ConfiguredMCPServer(
          id: "local",
          kind: "stdio",
          enabled: false,
          displayName: "Example local MCP",
          command: "your-mcp-server",
          args: ["--stdio"],
          cwd: ".",
          toolNamePrefix: "local",
          defaultApproval: .confirm),
      ],
      agents: [
        AgentDefinition(
          id: "hello",
          description: "Offline smoke test; no tools and no network.",
          instructions: "Exercise the offline MaiCore provider.",
          systemPrompt: "hello",
          provider: "hello",
          model: ""),
        AgentDefinition(
          id: "main",
          description: "General assistant with the full tool set.",
          instructions: SystemPrompt.defaultInstructions,
          systemPrompt: "main",
          provider: "openai",
          model: "your-model",
          toolNames: Set(
            [
              MaiCalculatorTool.name,
              MaiCurrentTimeTool.name,
              MaiWeatherTool.name,
              MaiWebSearchTool.name,
              MaiWebFetchTool.name,
              MaiVectorDatabaseTool.name,
              MaiMastodonTool.name,
            ] + MaiFileWorkspaceTool.toolNames + MaiRunTool.toolNames + MaiGitHubTool.toolNames
              + MaiTodoTools.toolNames + MaiContextTools.toolNames),
          toolGroupNames: [
            "datetime", "calc", "files", "run", "weather", "web", "mastodon",
            "github", "todo", "context", "vdb", AgentRuntime.agentToolGroup.id,
          ],
          subagentNames: ["researcher"],
          limits: AgentRunLimits(),
          options: GenerationOptions(reasoningEffort: ReasoningEffort.low.rawValue)),
        AgentDefinition(
          id: "researcher",
          description: "Investigates one question and answers in a few lines.",
          instructions: "Investigate the delegated task and return a concise result.",
          systemPrompt: "researcher",
          provider: "openai",
          model: "your-model",
          toolNames: [MaiCurrentTimeTool.name],
          toolGroupNames: ["datetime"]),
      ],
      prompts: ConfiguredPrompts(
        delegation: AgentDelegationPrompt.template,
        worker: AgentDelegationPrompt.workerInstructions,
        memory: AgentMemoryPrompt.template,
        system: [
          "hello": "Exercise the offline MaiCore provider.",
          "main": SystemPrompt.defaultInstructions,
          "researcher": "Investigate the delegated task and return a concise result.",
        ]),
      memory: ConfiguredMemory(),
      approvals: ConfiguredApprovals())
    MaiAgentPresets.install(in: &configuration)
    return configuration
  }
}
