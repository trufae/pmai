import MaiCore
import XCTest

@testable import MaiVoice

final class VoiceTests: XCTestCase {
  func testLegacySettingsAndPartialVoiceConfiguration() throws {
    let config = try JSONDecoder().decode(
      MaiConfiguration.self,
      from: Data(#"{"voice":{"language":"ca-ES","mode":"walkie-talkie"}}"#.utf8))
    XCTAssertEqual(config.voice.language, "ca-ES")
    XCTAssertEqual(config.voice.mode, .walkieTalkie)
    XCTAssertEqual(config.voice.input, "system")
    try config.voice.validate()
    XCTAssertEqual(
      try JSONDecoder().decode(MaiConfiguration.self, from: Data("{}".utf8)).voice.output, "system")
    XCTAssertEqual(
      try JSONDecoder().decode(MaiConfiguration.self, from: JSONEncoder().encode(config)), config)
  }
  func testSentenceStreamingAndSpeechFiltering() {
    var buffer = VoiceSentenceBuffer()
    XCTAssertEqual(buffer.append("Done. Next"), ["Done."])
    XCTAssertEqual(buffer.append(" sentence! "), ["Next sentence!"])
    XCTAssertEqual(buffer.finish(), [])
    var url = VoiceSentenceBuffer()
    XCTAssertEqual(url.append("See https://example."), [])
    XCTAssertEqual(url.append("org/a. Then continue. "), ["See", "Then continue."])
    XCTAssertEqual(
      VoiceSentenceBuffer.speechText("**Read** [this](https://example.org) and 123456789 now."),
      "Read this and now.")
  }
  func testInvalidSettingsRejected() {
    var config = ConfiguredVoice()
    config.silenceSeconds = .infinity
    XCTAssertThrowsError(try config.validate())
  }
}

@MainActor private final class TestInput: VoiceInputProvider {
  var receive: (@Sendable (VoiceInputEvent) -> Void)?
  var starts = 0
  var finishes = 0
  var text = "hello from the microphone"
  func start(receive: @escaping @Sendable (VoiceInputEvent) -> Void) async throws {
    starts += 1
    self.receive = receive
  }
  func finish() async throws -> String {
    finishes += 1
    return text
  }
  func stop() { receive = nil }
}

@MainActor private final class TestOutput: VoiceOutputProvider {
  var spoken: [String] = []
  var stopped = false
  func speak(_ text: String) async throws { spoken.append(text) }
  func stop() { stopped = true }
}

private final class TestSubmissions: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  var texts: [String] { lock.withLock { values } }
  func append(_ value: String) { lock.withLock { values.append(value) } }
}

extension VoiceTests {
  @MainActor private func waitFor(
    _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for voice state", file: file, line: line)
  }

  @MainActor func testRealtimeSilenceCommitsAndSpeechStartsBeforeModelEnds() async throws {
    let input = TestInput()
    let output = TestOutput()
    let submitted = TestSubmissions()
    var settings = ConfiguredVoice()
    settings.silenceSeconds = 0.2
    let session = VoiceSession(
      settings: settings, input: input, output: output,
      changed: { _ in }, submit: { submitted.append($0) })
    defer { session.stop() }
    session.start()
    try await waitFor { input.starts == 1 }
    // Background silence alone must never submit an empty turn.
    input.receive?(.level(0))
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(input.finishes, 0)
    input.receive?(.level(0.2))
    try await waitFor { submitted.texts.count == 1 }
    XCTAssertEqual(submitted.texts, [input.text])
    session.beginReply()
    let context = AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "voice", depth: 1)
    session.consume(.provider(context, .textDelta("First sentence. More")))
    try await waitFor { output.spoken.count == 1 }
    XCTAssertEqual(output.spoken, ["First sentence."])
    XCTAssertEqual(input.starts, 1, "Capture stays stopped while the agent is replying")
    session.consume(.provider(context, .textDelta(" follows.")))
    session.finishReply()
    try await waitFor { input.starts == 2 }
    XCTAssertEqual(output.spoken, ["First sentence.", "More follows."])
  }

  @MainActor func testWalkieTalkieNeedsSendAndPauseDiscardsOldCaptureCallbacks() async throws {
    let input = TestInput()
    let output = TestOutput()
    let submitted = TestSubmissions()
    var settings = ConfiguredVoice()
    settings.mode = .walkieTalkie
    settings.silenceSeconds = 0.2
    let session = VoiceSession(
      settings: settings, input: input, output: output,
      changed: { _ in }, submit: { submitted.append($0) })
    defer { session.stop() }
    session.start()
    try await waitFor { input.starts == 1 }
    let staleCallback = input.receive
    input.receive?(.level(0.2))
    try await Task.sleep(for: .milliseconds(350))
    XCTAssertTrue(submitted.texts.isEmpty)
    session.send()
    try await waitFor { submitted.texts.count == 1 }
    session.finishReply()
    XCTAssertEqual(session.state, .paused)
    XCTAssertEqual(input.starts, 1)
    session.record()
    try await waitFor { input.starts == 2 }
    staleCallback?(.failure("obsolete error"))
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(session.state, .listening)
    session.pause()
    input.receive?(.ended)
    XCTAssertEqual(session.state, .paused)
    XCTAssertTrue(output.stopped)
  }

  func testPluginVoiceFactoryRegistration() async throws {
    let registry = PluginRegistry()
    try await registry.install(MaiVoicePlugin())
    for kind in ["system", "command", "openai"] {
      let factory = try await registry.voiceFactory(kind: kind)
      XCTAssertEqual(factory.kind, kind)
    }
  }

  func testVoiceAgentToolsCanReadAndMessageSiblingsButNotAnotherChat() async throws {
    let supervisor = AgentSupervisor()
    let root = await supervisor.register(
      runID: UUID(), parent: nil, agentID: "text", displayName: "Text", task: "conversation",
      depth: 0)
    let voice = await supervisor.register(
      runID: UUID(), parent: root, agentID: "voice", displayName: "Voice", task: "voice", depth: 1)
    let sibling = await supervisor.register(
      runID: UUID(), parent: root, agentID: "worker", displayName: "Worker", task: "work", depth: 1)
    let other = await supervisor.register(
      runID: UUID(), parent: nil, agentID: "other", displayName: "Other", task: "private", depth: 0)
    let context = ToolExecutionContext(
      run: .init(runID: UUID(), parentRunID: nil, agentID: "voice", depth: 1, pid: voice),
      modelTurn: 0)
    let tools = VoiceAgentTools.tools(supervisor: supervisor)
    let list = try await tools[0].call(arguments: .object([:]), context: context)
    XCTAssertTrue(list.text.contains("\(root) text"))
    XCTAssertTrue(list.text.contains("\(sibling) worker"))
    XCTAssertFalse(list.text.contains("\(other) other"))
    let sent = try await tools[1].call(
      arguments: .object(["pid": .integer(sibling.rawValue), "text": .string("please check")]),
      context: context)
    XCTAssertFalse(sent.isError)
    let inbox = await supervisor.queuedMessages(for: sibling)
    XCTAssertEqual(inbox.first?.message.text, "please check")
    let blocked = try await tools[0].call(
      arguments: .object(["pid": .integer(other.rawValue)]), context: context)
    XCTAssertTrue(blocked.isError)
    let malformed = try await tools[1].call(
      arguments: .object(["pid": .number(1e99), "text": .string("invalid")]), context: context)
    XCTAssertTrue(malformed.isError)
  }
}

#if os(macOS) || os(Linux)
  extension VoiceTests {
    func testProgramArgumentsAreLiteralAndCancellationStopsChild() async throws {
      let literal = "hello; $(touch /tmp/this-must-not-run) `whoami`"
      let command = VoiceProcess(
        VoiceCommand("/bin/echo", arguments: ["{text}"]),
        environment: ProcessInfo.processInfo.environment, values: ["text": literal])
      let result = try await command.run()
      XCTAssertEqual(String(decoding: result, as: UTF8.self), literal + "\n")
      let sleeping = VoiceProcess(
        VoiceCommand("/bin/sleep", arguments: ["30"]),
        environment: ProcessInfo.processInfo.environment)
      let task = Task { try await sleeping.run() }
      try await Task.sleep(for: .milliseconds(30))
      task.cancel()
      do {
        _ = try await task.value
        XCTFail("Expected cancellation")
      } catch is CancellationError {}
      XCTAssertFalse(sleeping.process.isRunning)
      let earlyExit = VoiceProcess(
        VoiceCommand("/bin/false"),
        environment: ProcessInfo.processInfo.environment)
      do {
        _ = try await earlyExit.run(input: String(repeating: "x", count: 100_000))
        XCTFail("Expected a program failure")
      } catch {}
      XCTAssertFalse(earlyExit.process.isRunning)
    }
  }
#endif
