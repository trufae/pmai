import Foundation
import MaiCore

extension MaiCLI {
  @MainActor static func submit(
    _ text: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    process: inout AgentPID?,
    terminal: TerminalWriter,
    promptFileAccess: PromptFileAccess,
    approvalHandler: TerminalApprovalHandler,
    configuration: MaiConfiguration?,
    environment: [String: String],
    checkpoint: (AgentChat) throws -> Void = { _ in }
  ) async -> Bool {
    guard await preparePromptFileAccess(
      for: text, runtime: runtime, configuration: configuration, environment: environment,
      promptFileAccess: promptFileAccess, approvalHandler: approvalHandler, terminal: terminal)
    else { return false }
    var content: [ContentPart] = [.text(text)]
    content.append(contentsOf: session.pendingContent)
    session.pendingContent.removeAll()
    session.history.append(AgentMessage(role: .user, content: content))
    session.refreshTitle(from: text)
    await terminal.resetResponse()
    do {
      session.touch()
      try checkpoint(session.chat)
      let profile = session.profile
      let request = AgentRequest(
        agentID: profile.agentID,
        provider: profile.provider,
        model: profile.model,
        messages: session.history.messages,
        systemContext: profile.systemContext,
        toolNames: profile.toolNames,
        toolGroupNames: profile.toolGroupNames,
        subagentNames: profile.subagentNames,
        toolChoice: profile.toolChoice,
        responseFormat: profile.responseFormat,
        options: profile.options,
        limits: profile.limits,
        stream: profile.stream,
        toolCallingStrategy: profile.toolCallingStrategy,
        useToolProxy: profile.useToolProxy,
        useSystemOne: profile.useSystemOne,
        proxyExposedTools: profile.proxyExposedTools,
        toolPolicy: profile.toolPolicy,
        toolDelegation: profile.toolDelegation,
        retry: profile.retry,
        autocompact: profile.autocompact,
        context: profile.context,
        sessionID: session.sessionID)
      let existingProcess = process
      let result = try await FileAccessLog.$current.withValue(session.fileAccessLog) {
        try await runtime.run(request, process: existingProcess) { event in
          await terminal.consume(event)
        }
      }
      process = await runtime.supervisor.tree().processes.first { $0.runID == result.runID }?.pid
      session.history.replaceAll(with: session.redactor?.unredact(result.transcript) ?? result.transcript)
      if let interruption = result.interruption {
        await terminal.note(
          "⏸ \(interruption.summary) · send another message to continue, or raise \(interruption.settingKey)",
          tone: .warning)
      }
      return true
    } catch {
      if error is CancellationError {
        await terminal.recoverAfterCancellation()
        return false
      }
      await terminal.recoverAfterError(error)
      return false
    }
  }
}
