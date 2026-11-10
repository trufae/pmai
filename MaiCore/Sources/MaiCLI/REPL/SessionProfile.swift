import Foundation
import MaiCore
import MaiStandardTools

struct SessionProfile: Sendable {
  var agentID: String
  var displayName: String
  /// Carried through so writing the chat's agent back to the configuration
  /// never erases the setup's purpose or its enabled state.
  var description: String
  var isEnabled: Bool
  var provider: ProviderID
  var model: String
  var instructions: String
  var systemPrompt: String?
  var systemContext: Bool?
  var toolNames: Set<String>
  var toolGroupNames: Set<String>
  var subagentNames: Set<String>
  var stream: Bool
  var limits: AgentRunLimits
  var toolChoice: ToolChoice
  var responseFormat: ResponseFormat
  var options: GenerationOptions
  var toolCallingStrategy: ToolCallingStrategy
  var useToolProxy: Bool
  var useSystemOne: Bool
  var proxyExposedTools: Set<String>?
  var toolPolicy: AgentToolPolicy
  var toolDelegation: AgentToolDelegation
  var retry: AgentRetryPolicy
  var autocompact: AgentAutocompact
  var context: AgentContextMode

  init(definition: AgentDefinition) {
    agentID = definition.id
    displayName = definition.displayName
    description = definition.description
    isEnabled = definition.isEnabled
    provider = definition.provider
    model = definition.model
    instructions = definition.instructions
    systemPrompt = definition.systemPrompt
    systemContext = definition.systemContext
    toolNames = definition.toolNames
    toolGroupNames = definition.toolGroupNames
    subagentNames = definition.subagentNames
    stream = definition.stream
    limits = definition.limits
    toolChoice = definition.toolChoice
    responseFormat = definition.responseFormat
    options = definition.options
    toolCallingStrategy = definition.toolCallingStrategy
    useToolProxy = definition.useToolProxy
    useSystemOne = definition.useSystemOne
    proxyExposedTools = definition.proxyExposedTools
    toolPolicy = definition.toolPolicy
    toolDelegation = definition.toolDelegation
    retry = definition.retry
    autocompact = definition.autocompact
    context = definition.context
  }

  init(provider: ProviderID, model: String, instructions: String, stream: Bool) {
    agentID = "main"
    displayName = "main"
    description = ""
    isEnabled = true
    self.provider = provider
    self.model = model
    self.instructions = instructions
    systemPrompt = nil
    systemContext = nil
    toolNames = Set(
      [
        MaiCurrentTimeTool.name,
        MaiCalculatorTool.name,
        MaiWeatherTool.name,
        MaiWebSearchTool.name,
        MaiWebFetchTool.name,
        MaiVectorDatabaseTool.name,
        MaiMastodonTool.name,
      ] + MaiFileWorkspaceTool.toolNames + MaiRunTool.toolNames + MaiGitHubTool.toolNames
        + MaiTodoTools.toolNames + MaiContextTools.toolNames)
    toolGroupNames = [
      "datetime", "calc", "files", "run", "weather", "web", "mastodon", "github", "todo", "vdb",
      "context", MaiSkillTools.groupID, AgentRuntime.agentToolGroup.id,
    ]
    subagentNames = []
    self.stream = stream
    limits = .init()
    toolChoice = .automatic
    responseFormat = .text
    options = .init(reasoningEffort: ReasoningEffort.low.rawValue)
    toolCallingStrategy = .automatic
    useToolProxy = true
    useSystemOne = false
    proxyExposedTools = nil
    toolPolicy = .init()
    toolDelegation = .inline
    retry = .init()
    autocompact = .init()
    context = .adaptive
  }

  var agentDefinition: AgentDefinition {
    AgentDefinition(
      id: agentID,
      displayName: displayName,
      description: description,
      isEnabled: isEnabled,
      instructions: instructions,
      systemPrompt: systemPrompt,
      systemContext: systemContext,
      provider: provider,
      model: model,
      toolNames: toolNames,
      toolGroupNames: toolGroupNames,
      subagentNames: subagentNames,
      stream: stream,
      limits: limits,
      toolChoice: toolChoice,
      responseFormat: responseFormat,
      options: options,
      toolCallingStrategy: toolCallingStrategy,
      useToolProxy: useToolProxy,
      useSystemOne: useSystemOne,
      proxyExposedTools: proxyExposedTools,
      toolPolicy: toolPolicy,
      toolDelegation: toolDelegation,
      retry: retry,
      autocompact: autocompact,
      context: context)
  }
}
