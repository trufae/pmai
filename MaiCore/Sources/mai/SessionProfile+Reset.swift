import MaiCore

extension SessionProfile {
  /// Restore exactly the agent options exposed by /set, retaining its identity,
  /// provider, model, prompt, generation options and explicit /tools selections.
  mutating func resetSettings() {
    let defaults = SessionProfile(provider: provider, model: model, instructions: instructions, stream: stream)
    options.reasoningEffort = defaults.options.reasoningEffort
    options.reasoningGuidance = defaults.options.reasoningGuidance
    limits = defaults.limits
    retry = defaults.retry
    autocompact = defaults.autocompact
    context = defaults.context
    toolDelegation = defaults.toolDelegation
    toolCallingStrategy = defaults.toolCallingStrategy
    useToolProxy = defaults.useToolProxy
    useSystemOne = defaults.useSystemOne
    proxyExposedTools = defaults.proxyExposedTools
    toolPolicy.automatic = defaults.toolPolicy.automatic
  }
}
