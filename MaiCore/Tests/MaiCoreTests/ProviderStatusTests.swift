import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import Testing

@testable import MaiCore

@Suite("Provider status")
struct ProviderStatusTests {
  private func data(_ json: String) -> Data { Data(json.utf8) }

  @Test("Legacy session and weekly percentages become limits")
  func legacyLimits() {
    let status = MaiProviderStatusService.decoded(
      data(
        """
        {"included":{"session":{"remaining_percent":33.34,"resets_at":"2026-11-16T18:00:00Z"},
        "weekly":{"remaining_percent":69.81,"resets_at":"2026-11-23T00:00:00Z"}},
        "purchased":{"balance_usd":0}}
        """),
      provider: "ollamacloud", model: nil, plan: "pro")
    #expect(status.plan == "pro")
    #expect(status.limits["session"]?.remainingPercent == 33.34)
    #expect(status.limits["weekly"]?.resetsAt != nil)
    #expect(status.balances == [.purchased(0)])
    let summary = status.summary(
      now: Date(timeIntervalSince1970: 1_763_304_000), providerLabel: "ollamacloud")
    #expect(summary.hasPrefix("ollamacloud · pro · session 33% ("))
    #expect(summary.hasSuffix("$0 credit"))
  }

  @Test("Credit plans report the included balance and its period")
  func credits() {
    let status = MaiProviderStatusService.decoded(
      data(
        """
        {"included":{"balance_usd":"72.50","allowance_usd":100,
        "period":{"from":"2026-09-15T09:30:00Z","until":"2026-10-15T09:30:00Z"}},
        "purchased":{"balance_usd":25}}
        """),
      provider: "ollama", model: nil, plan: nil)
    #expect(status.limits.isEmpty)
    #expect(
      status.balances == [
        .credits(remaining: 72.5, allowance: 100, resetsAt: MaiProviderStatus.date("2026-10-15T09:30:00Z")),
        .purchased(25),
      ])
    #expect(status.summary().contains("$72.50 of $100"))
  }

  @Test("A short line keeps the soonest limit and hides an empty balance")
  func compactSummary() {
    let status = MaiProviderStatus(
      provider: "ollamacloud", plan: "pro",
      limits: [
        "session": .init(remainingPercent: 33),
        "weekly": .init(remainingPercent: 70),
      ], balances: [.purchased(0)], requestsLast7Days: 6233, requestsToday: 597)
    let now = Date()
    #expect(status.summary(now: now, compact: true) == "ollamacloud · pro · session 33%")
    let full = status.summary(now: now)
    #expect(full.contains("session 33%"))
    #expect(full.contains("weekly 70%"))
    #expect(full.contains("6233 req · 597 today"))
  }

  @Test("An hourly percentage stays a percentage")
  func fractionToPercent() {
    let status = MaiProviderStatusService.decoded(
      data(#"{"limits":{"monthly":{"usage":0.4}}}"#), provider: "p", model: nil, plan: nil)
    #expect(status.limits["monthly"]?.remainingPercent == 40)
  }

  @Test("The ACP payload round-trips")
  func payloadRoundTrip() throws {
    let original = MaiProviderStatus(
      provider: "ollamacloud", plan: "pro",
      limits: ["session": .init(remainingPercent: 12, resetsAt: Date(timeIntervalSince1970: 0))],
      balances: [.purchased(3)])
    let encoded = try JSONSerialization.data(withJSONObject: original.payload)
    let wire = try JSONDecoder().decode(JSONValue.self, from: encoded)
    let decoded = try #require(MaiProviderStatus(payload: wire))
    #expect(decoded.provider == original.provider)
    #expect(decoded.plan == original.plan)
    #expect(decoded.limits["session"]?.remainingPercent == 12)
    #expect(decoded.balances == [.purchased(3)])
  }

  @Test("A host that publishes no limits decodes to nil")
  func unsupported() {
    #expect(MaiProviderStatus(payload: .object(["supported": .bool(false)])) == nil)
    #expect(
      MaiProviderStatus(
        payload: .object(["supported": .bool(true), "provider": .string("x"), "error": .string("boom")]))
        == nil)
  }

  @Test("Countdowns read in the unit a person would say")
  func countdowns() {
    #expect(MaiProviderStatus.countdown(30) == "1m")
    #expect(MaiProviderStatus.countdown(3 * 3600 + 7 * 60) == "3h 07m")
    #expect(MaiProviderStatus.countdown(6 * 86_400 + 9 * 3600) == "6d 9h")
    #expect(MaiProviderStatus.countdown(0) == "now")
  }

  @Test("Only Ollama's cloud is queried")
  func hostDetection() {
    #expect(MaiProviderStatusService.isOllamaCloud("ollama.com"))
    #expect(MaiProviderStatusService.isOllamaCloud("api.ollama.com"))
    #expect(!MaiProviderStatusService.isOllamaCloud("127.0.0.1"))
    #expect(!MaiProviderStatusService.isOllamaCloud("notollama.com"))
  }

  @Test("A provider with no key reports it instead of failing silently")
  func missingKey() async {
    let provider = ConfiguredProvider(
      id: "ollamacloud", kind: .openAICompatible, baseURL: URL(string: "https://ollama.com/v1"))
    await #expect(throws: MaiProviderStatusError.missingAPIKey("ollamacloud")) {
      _ = try await MaiProviderStatusService.status(
        for: provider, environment: [:], session: URLSession.shared)
    }
  }

  @Test("A local provider publishes no status")
  func localProvider() async throws {
    let provider = ConfiguredProvider(
      id: "ollama", kind: .openAICompatible, baseURL: URL(string: "http://127.0.0.1:11434/v1"))
    let status = try await MaiProviderStatusService.status(for: provider, environment: [:])
    #expect(status == nil)
  }

  @Test("The tool answers with text and structured content")
  func toolOutput() async throws {
    let status = MaiProviderStatus(
      provider: "ollamacloud", plan: "pro",
      limits: ["session": .init(remainingPercent: 33)])
    let tool = MaiProviderStatusTool { _, _, _ in status }
    let result = try await tool.call(
      arguments: .object([:]), context: ToolExecutionContext(
        run: .init(runID: UUID(), parentRunID: nil, agentID: "main", depth: 0), modelTurn: 0,
        runTimeoutSeconds: nil))
    #expect(result.text.contains("session 33%"))
    #expect(result.structuredContent?.objectValue?["provider"] == .string("ollamacloud"))
    #expect(result.structuredContent?.objectValue?["supported"] == .bool(true))
    #expect(MaiProviderStatus(payload: result.structuredContent ?? .null)?.provider == "ollamacloud")
    #expect(result.isError == false)
    #expect(tool.isHostTool)

    let none = MaiProviderStatusTool { _, _, _ in nil }
    let empty = try await none.call(
      arguments: .object([:]), context: ToolExecutionContext(
        run: .init(runID: UUID(), parentRunID: nil, agentID: "main", depth: 0), modelTurn: 0,
        runTimeoutSeconds: nil))
    #expect(empty.text == "Account quota information is unavailable for this provider.")
  }
}

@Suite("Provider status usage counts")
struct ProviderStatusUsageTests {
  @Test("The request history counts a week and today, and never fails the status")
  func requests() async {
    let empty = await MaiProviderStatusService.usageRequests(apiKey: "k", session: .shared)
    #expect(empty.last7Days == 0)
  }
}

#if os(macOS) || os(Linux) || os(Windows)
  @Suite("Metered agent status")
  struct MeteredAgentStatusTests {
    @Test("A command line names its backend")
    func backend() {
      #expect(MeteredAgentStatus.backend(command: "codex-acp") == "codex")
      #expect(MeteredAgentStatus.backend(command: "/usr/local/bin/claude-agent-acp") == "claude")
      #expect(MeteredAgentStatus.backend(command: "opencode") == nil)
      #expect(MeteredAgentStatus.usageCommand(for: "codex") == "/status")
      #expect(MeteredAgentStatus.usageCommand(for: "claude") == "/usage")
    }

    @Test("Claude's answer becomes a session and a week, with its own words for the reset")
    func claudeText() {
      let text = """
        **5-hour limit** — **46%** · Resets Nov 16, 9:10 PM GMT+1
        **Weekly · all models** — **51%** · Resets Nov 18, 4:00 AM GMT+1
        **Weekly · Fable** — **74%** · Resets Nov 18, 4:00 AM GMT+1
        """
      let status = MeteredAgentStatus.parseClaude(text, provider: "claude")
      #expect(status.limits["session"]?.remainingPercent == 54)
      #expect(status.limits["session"]?.resetsText == "Nov 16, 9:10 PM GMT+1")
      #expect(status.limits["weekly"]?.remainingPercent == 49)
      #expect(status.limits["week fable"]?.remainingPercent == 26)
      #expect(status.summary(providerLabel: "claude").hasPrefix("claude · session 54% (Nov 16"))
    }

    @Test("Codex reports what is left, so its percentage is used as it stands")
    func codexText() {
      let text = """
        **Account:** ChatGPT pro (pancake@example.com)
        **codex Weekly limit:** 0% left (resets 08:15 on Nov 18)
        **codex Credits:** 42236.9185690000
        """
      let status = MeteredAgentStatus.parseCodex(text, provider: "codex")
      #expect(status.plan == "ChatGPT pro")
      #expect(status.limits["weekly"]?.remainingPercent == 0)
      #expect(status.limits["weekly"]?.resetsText == "08:15 on Nov 18")
      // Credits are not dollars, so they stay out of the balances.
      #expect(status.balances.isEmpty)
    }
  }
#endif

@Test("Usage warnings use consumed quota, rearm after reset and never invent unknown capacity")
func usageWarningThresholds() throws {
  let now = Date(timeIntervalSince1970: 1000)
  let context = ContextUsage(usedTokens: 800, windowTokens: 1000)
  let quota = MaiProviderStatus(provider: "test", limits: [
    "weekly": .init(remainingPercent: 20, resetsAt: now.addingTimeInterval(60)),
    "expired": .init(remainingPercent: 0, resetsAt: now),
  ], balances: [.credits(remaining: 10, allowance: 100, resetsAt: nil)])
  #expect(UsageWarnings.messages(context: context, quota: quota, now: now).count == 3)
  #expect(UsageWarnings.messages(context: context, quota: quota, threshold: 95, now: now).isEmpty)
  #expect(UsageWarnings.messages(context: context, quota: quota, threshold: 0, now: now).isEmpty)
  #expect(UsageWarnings.messages(context: ContextUsage(usedTokens: 100000)).isEmpty)
  #expect(UsageWarnings.messages(context: ContextUsage(usedTokens: 900, windowTokens: 1000, isPartial: true)).isEmpty)
  #expect(UsageWarnings.messages(context: ContextUsage(usedTokens: 799, windowTokens: 1000)).isEmpty)
  let legacy = try JSONDecoder().decode(ConfiguredTerminalUI.self, from: Data("{}".utf8))
  #expect(legacy.usageWarningPercent == 80)
  let restored = try JSONDecoder().decode(ConfiguredTerminalUI.self,
    from: JSONEncoder().encode(ConfiguredTerminalUI(usageWarningPercent: 90)))
  #expect(restored.usageWarningPercent == 90)
}
