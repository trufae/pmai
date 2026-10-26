import Foundation
import Testing

@testable import MaiCore

@Test("Working directory context follows each session without entering its transcript")
func workingDirectoryContext() async throws {
  let runtime = AgentRuntime()
  let provider = ExecutionContextProvider()
  try await runtime.register(provider)
  await runtime.configureWorkingDirectoryContext(true)
  let originalDirectory = FileManager.default.currentDirectoryPath
  let directories = ["/tmp/first repo", "/tmp/second repo"]
  var request = AgentRequest(
    provider: provider.descriptor.id, model: "fixture",
    messages: [.system("Keep these rules."), .user("Check this repository")],
    sessionID: "same-chat")

  for directory in directories {
    let result = try await AgentExecutionScope.$current.withValue(
      AgentExecutionScope(sessionID: "same-chat", workingDirectory: URL(fileURLWithPath: directory))
    ) {
      try await runtime.run(request)
    }
    #expect(!result.transcript.contains { $0.text.contains("<execution_context>") })
    request.messages = result.transcript + [.user("Check the current repository again")]
  }
  let requests = await provider.requests
  for (request, directory) in zip(requests, directories) {
    let context = request.messages.filter { $0.text.contains("<execution_context>") }
    #expect(context.count == 1)
    #expect(context.first?.role == .system)
    #expect(context.first?.text.contains("Current working directory: \(directory)") == true)
    #expect(request.messages.first?.text == "Keep these rules.")
  }
  #expect(FileManager.default.currentDirectoryPath == originalDirectory)

  // Without a session scope the CLI reports process cwd; clearing the
  // host's opt-in leaves generic chat hosts without filesystem context.
  _ = try await runtime.run(request)
  #expect(await provider.requests.last?.messages.contains {
    $0.text.contains("Current working directory: \(originalDirectory)")
  } == true)
  await runtime.configureWorkingDirectoryContext(false)
  _ = try await runtime.run(request)
  #expect(await provider.requests.last?.messages.contains {
    $0.text.contains("<execution_context>")
  } == false)
}

private actor ExecutionContextProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "execution-context", displayName: "Execution context", capabilities: [])
  private(set) var requests: [ProviderRequest] = []

  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws
    -> ProviderResponse
  {
    requests.append(request)
    return ProviderResponse(message: .assistant("done"))
  }
}
