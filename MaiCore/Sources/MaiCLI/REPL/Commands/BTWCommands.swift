import Foundation
import MaiCore

extension MaiCLI {
  /// Builds the throwaway context used by `/btw`: the active agent's system
  /// prompt plus this one question, with none of the chat's transcript or
  /// pending attachments.
  static func btwRequest(_ text: String, profile: SessionProfile, sessionID: String)
    -> AgentRequest?
  {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return nil }
    var messages = AgentChat.initialHistory(for: profile.agentDefinition)
    messages.append(.user(prompt))
    return AgentRequest(
      agentID: profile.agentID,
      provider: profile.provider,
      model: profile.model,
      messages: messages,
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
      context: profile.context, sessionID: sessionID)
  }

  /// Runs an isolated side question for the hosted command runner. The REPL
  /// starts the same request in its event loop to keep approvals and Ctrl+C responsive.
  static func handleBTWCommand(
    _ text: String,
    session: REPLSession,
    runtime: AgentRuntime,
    terminal: TerminalWriter
  ) async {
    guard let request = btwRequest(text, profile: session.profile, sessionID: session.sessionID)
    else {
      await terminal.line("Usage: /btw PROMPT")
      return
    }
    await terminal.resetResponse()
    do {
      let request = try await runtime.taskRequest(.btw, from: request)
      _ = try await runtime.run(request) { event in
        await terminal.consume(event)
      }
    } catch is CancellationError {
      await terminal.recoverAfterCancellation()
    } catch {
      await terminal.recoverAfterError(error)
    }
  }
}
