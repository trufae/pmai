import Foundation
import Testing

@testable import MaiCore

@Test("Context windows decode compatibly and persist as harness settings")
func smallContextConfiguration() throws {
  let old = try JSONDecoder().decode(GenerationOptions.self, from: Data("{}".utf8))
  #expect(old.contextWindowTokens == nil)
  let options = GenerationOptions(maxOutputTokens: 2_048, contextWindowTokens: 32_768)
  #expect(
    try JSONDecoder().decode(GenerationOptions.self, from: JSONEncoder().encode(options)) == options
  )
  #expect(GenerationOptions(contextWindowTokens: 0).contextWindowTokens == nil)
}

@Test("Context diagnostics learn the window without confusing unrelated failures")
func smallContextErrors() {
  func recognize(_ text: String) -> ProviderContextLimitError? {
    ProviderContextLimitError.recognize(
      NSError(
        domain: "fixture", code: 400, userInfo: [NSLocalizedDescriptionKey: text]))
  }
  let error = recognize(
    "This model's maximum context length is 32768 tokens. However, your prompt contains at least 32769 input tokens."
  )
  #expect(error?.contextWindowTokens == 32_768)
  #expect(recognize("maximum context length is 32,768 tokens")?.contextWindowTokens == 32_768)
  #expect(recognize("input exceeds max_model_len: 4096")?.contextWindowTokens == 4_096)
  #expect(recognize("context_length_exceeded") != nil)
  #expect(recognize("HTTP 400: invalid API parameter") == nil)
  #expect(recognize("HTTP 429: too many requests") == nil)
}

@Test("Summary chunks preserve all Unicode text and stay within their byte budget")
func smallContextUnicodeChunks() {
  let source = String(repeating: "🐢 中文 e\u{301}\n", count: 5_000)
  let chunks = AgentRuntime.summaryChunks(source, maxBytes: 1_024)
  #expect(chunks.count > 1)
  #expect(chunks.joined() == source)
  #expect(chunks.allSatisfy { $0.utf8.count <= 1_024 })
}

@Test("A 32k summarizer covers a transcript larger than its window, including one huge message")
func smallContextChunkedSummary() async throws {
  let provider = SmallContextProvider(window: 32_768)
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  let source = (0..<12).map { "KEEP-\($0) " + String(repeating: "evidence ", count: 5_000) }
    .joined(separator: "\n")
  let result = try await runtime.summarize(
    source,
    request: AgentRequest(
      provider: "small", model: "fixture",
      messages: [], options: .init(contextWindowTokens: 32_768)),
    renderPrompt: { "CUSTOM preserve all KEEP identifiers and focus.\nTranscript:\n\($0)" })
  for index in 0..<12 { #expect(result.contains("KEEP-\(index)")) }
  let requests = await provider.requests
  #expect(requests.count > 2)
  #expect(await provider.rejections == 0)
  #expect(requests.allSatisfy { $0.messages.last?.text.hasPrefix("CUSTOM preserve") == true })
  #expect(requests.allSatisfy { $0.tools.isEmpty && $0.toolChoice == .none && !$0.stream })
  #expect(requests.allSatisfy { ($0.options.maxOutputTokens ?? 0) <= 2_048 })
}

@Test(
  "An unknown small window is learned and a rejected summary is split instead of blindly retried")
func smallContextSummaryLearnsLimit() async throws {
  let provider = SmallContextProvider(window: 4_096)
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  let source = "KEEP-1 " + String(repeating: "evidence ", count: 7_000) + " KEEP-2"
  let result = try await runtime.summarize(
    source,
    request: AgentRequest(
      provider: "small", model: "fixture", messages: [],
      retry: .init(attempts: 2, delaySeconds: 0)),
    renderPrompt: { AgentCompactionPrompt.render(transcript: $0, focus: "Keep the task.") })
  #expect(result.contains("KEEP-1"))
  #expect(result.contains("KEEP-2"))
  #expect(await provider.rejections == 1)
  #expect(await runtime.contextWindows["small"]?["fixture"] == 4_096)
  let requests = await provider.requests
  #expect(requests.count > 3)
  #expect(requests[1].messages.last!.text.utf8.count < requests[0].messages.last!.text.utf8.count)
}

@Test("Oversized immutable prompts fail once when compaction is disabled")
func smallContextDoesNotRetryOversizedPrompt() async throws {
  let provider = SmallContextProvider(window: 4_096)
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  await #expect(throws: ProviderContextLimitError.self) {
    try await runtime.run(
      AgentRequest(
        provider: "small", model: "fixture",
        messages: [.user(String(repeating: "large request ", count: 8_000))],
        retry: .init(attempts: 2, delaySeconds: 0), autocompact: .init(tokens: 0)))
  }
  #expect(await provider.requests.count == 1)
}

@Test("Chunk sizing accounts for escaped text and repeated transcript placeholders")
func smallContextEscapedSummary() async throws {
  let provider = SmallContextProvider(window: 4_096)
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  let source = "KEEP-1 " + String(repeating: "\u{1}", count: 12_000) + " KEEP-2"
  let result = try await runtime.summarize(
    source,
    request: AgentRequest(
      provider: "small", model: "fixture", messages: [],
      options: .init(contextWindowTokens: 4_096)),
    renderPrompt: {
      "CUSTOM preserve KEEP identifiers.\nTranscript:\n\($0)\nRepeated evidence:\n\($0)"
    })
  #expect(result.contains("KEEP-1") && result.contains("KEEP-2"))
  #expect(await provider.requests.count > 2)
  #expect(await provider.rejections == 0)
}

@Test(
  "Known windows compact before a chat request and retain instructions and the latest user request")
func smallContextPreflight() async throws {
  let provider = SmallContextProvider(window: 32_768)
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  let latest = AgentMessage.user("Finish my task exactly.")
  var messages: [AgentMessage] = [.system("Permanent instructions.")]
  for index in 0..<8 {
    messages += [
      .user("Old task \(index)"),
      .assistant("KEEP-\(index) " + String(repeating: "evidence ", count: 4_000)),
    ]
  }
  messages.append(latest)
  let result = try await runtime.run(
    AgentRequest(
      provider: "small", model: "fixture", messages: messages,
      options: .init(contextWindowTokens: 32_768)))
  #expect(result.response.text == "done")
  #expect(result.transcript.first == messages.first)
  #expect(result.transcript.contains(latest))
  #expect(result.transcript.count < messages.count)
  #expect(await provider.rejections == 0)
}

@Test("A context rejection recovers by compacting before another chat call")
func smallContextRecoversOverflow() async throws {
  let provider = SmallContextProvider(window: 4_096)
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  let latest = AgentMessage.user("Continue working.")
  let messages: [AgentMessage] = [
    .user("Old task"), .assistant("KEEP-1 " + String(repeating: "evidence ", count: 6_000)),
    .user("Second task"), .assistant("KEEP-2 " + String(repeating: "evidence ", count: 6_000)),
    latest,
  ]
  let result = try await runtime.run(
    AgentRequest(
      provider: "small", model: "fixture", messages: messages,
      retry: .init(attempts: 2, delaySeconds: 0)))
  #expect(result.response.text == "done")
  #expect(result.transcript.contains(latest))
  #expect(await provider.rejections == 1)
  let requests = await provider.requests
  let chats = requests.filter { $0.stream }
  #expect(chats.count == 2)
  #expect(AgentRuntime.contextTokens(chats[1]) < AgentRuntime.contextTokens(chats[0]))
}

@Test("Failed or truncated partial summaries leave the runtime transcript intact")
func smallContextFailedSummaryKeepsHistory() async throws {
  let provider = SmallContextProvider(window: 32_768, truncatesSummary: true)
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  let messages: [AgentMessage] = [
    .user("Old task"), .assistant(String(repeating: "evidence ", count: 500)), .user("Latest task"),
  ]
  let result = try await runtime.run(
    AgentRequest(
      provider: "small", model: "fixture", messages: messages,
      autocompact: .init(tokens: 100, preserveRecentTokens: 0)))
  #expect(Array(result.transcript.prefix(messages.count)) == messages)
  #expect(result.response.text == "done")
}

@Test("Chunked summaries stop at the shared token budget")
func smallContextSummaryTokenBudget() async throws {
  let provider = SmallContextProvider(window: 4_096)
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  do {
    _ = try await runtime.summarize(
      String(repeating: "evidence ", count: 10_000),
      request: AgentRequest(
        provider: "small", model: "fixture", messages: [],
        options: .init(contextWindowTokens: 4_096), limits: .init(maxTotalTokens: 10)),
      renderPrompt: { AgentCompactionPrompt.render(transcript: $0) })
    Issue.record("Expected the token budget to stop summarization")
  } catch {
    #expect(error.localizedDescription.contains("token budget"))
  }
  #expect(await provider.requests.count == 1)
}

@Test("Keeping context after an overflow does not resend the rejected request")
func smallContextOverflowRespectsKeep() async throws {
  let provider = SmallContextProvider(window: 4_096)
  let runtime = AgentRuntime(approvalHandler: KeepSmallContext())
  try await runtime.register(provider)
  await #expect(throws: ProviderContextLimitError.self) {
    try await runtime.run(
      AgentRequest(
        provider: "small", model: "fixture",
        messages: [
          .user("Old task"), .assistant(String(repeating: "evidence ", count: 6_000)),
          .user("Continue"),
        ], retry: .init(attempts: 2, delaySeconds: 0)))
  }
  #expect(await provider.requests.count == 1)
}

private struct KeepSmallContext: ApprovalHandler {
  func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    .deny(reason: "No tools needed")
  }
  func decideCompaction(_ request: AutocompactionRequest) async throws -> AutocompactionDecision {
    .continueWithoutCompacting
  }
}

private actor SmallContextProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(id: "small", displayName: "Small context fixture")
  let window: Int
  let truncatesSummary: Bool
  private(set) var requests: [ProviderRequest] = []
  private(set) var rejections = 0

  init(window: Int, truncatesSummary: Bool = false) {
    self.window = window
    self.truncatesSummary = truncatesSummary
  }

  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws
    -> ProviderResponse
  {
    requests.append(request)
    let input = request.messages.map(\.text).joined(separator: "\n")
    let tokens = input.utf8.count / 4 + (request.options.maxOutputTokens ?? 512)
    if tokens > window {
      rejections += 1
      throw NSError(
        domain: "fixture", code: 400,
        userInfo: [
          NSLocalizedDescriptionKey:
            "This model's maximum context length is \(window) tokens. However, your prompt contains at least \(tokens) input tokens."
        ])
    }
    if !request.stream {
      let expression = try NSRegularExpression(pattern: #"KEEP-\d+"#)
      let matches = expression.matches(in: input, range: NSRange(input.startIndex..., in: input))
      let markers = matches.compactMap { Range($0.range, in: input).map { String(input[$0]) } }
      let summary = "Saved facts: " + Set(markers).sorted().joined(separator: " ")
      return ProviderResponse(
        message: .assistant(summary),
        usage: .init(inputTokens: input.count / 4, outputTokens: summary.count / 4),
        stopReason: truncatesSummary ? .length : .stop)
    }
    return ProviderResponse(message: .assistant("done"), stopReason: .stop)
  }
}
