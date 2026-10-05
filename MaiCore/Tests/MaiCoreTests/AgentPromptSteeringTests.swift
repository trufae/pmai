import Foundation
import Testing

@testable import MaiCore

@Test(
  "Queued steering retains a running task's exact skill and proxy catalog; a new run releases them",
  arguments: [AgentContextMode.cache, .size, .smart, .tools], [false, true])
func promptContextQueuedSteering(contextMode: AgentContextMode, directInvocation: Bool) async throws {
  try await exercisePromptContextSteering(contextMode: contextMode, directInvocation: directInvocation)
}

@Test("A limit-interrupted skill task resumes on the same PID with its exact active instructions",
  arguments: [AgentContextMode.cache, .size, .smart, .tools])
func promptContextResumesSteeredTask(contextMode: AgentContextMode) async throws {
  try await exercisePromptContextSteering(contextMode: contextMode, directInvocation: false, pauseAtLimit: true)
}

private func exercisePromptContextSteering(
  contextMode: AgentContextMode, directInvocation: Bool, pauseAtLimit: Bool = false
) async throws {
  let skill = AgentSkill(
    name: "steering-review", description: "Review the requested file",
    directoryURL: URL(fileURLWithPath: "/tmp/skills/steering-review"),
    body: String(repeating: "EXACT REVIEW STEP.\n", count: 250) + "Answer with STEERING REVIEW FORMAT.")
  let list = ToolCall(id: "catalog", name: ToolProxy.listName, arguments: .object(["keywords": .string("")]))
  let load = ToolCall(
    id: "skill", name: ToolProxy.callName,
    arguments: .object([
      "name": .string(skill.toolName),
      "arguments": .object(["arguments": .string("input.txt")]),
    ]))
  let steer = ToolCall(
    id: "steer", name: ToolProxy.callName,
    arguments: .object(["name": .string("steer"), "arguments": .object([:])]))
  let primary = SteeringPromptProvider(
    id: "steering-primary", responses: [
      .init(message: AgentMessage(role: .assistant, content: (directInvocation ? [list] : [list, load]).map(ContentPart.toolCall))),
      .init(message: AgentMessage(role: .assistant, content: [.toolCall(steer)])),
      .init(message: .assistant("STEERING REVIEW FORMAT")),
      .init(message: .assistant("Independent answer")),
    ])
  let compact = SteeringPromptProvider(
    id: "steering-compact", responses: (0..<4).map { _ in
      .init(message: .assistant("LOSSY BRIEF WITHOUT ANY INSTRUCTIONS OR ARGUMENTS"))
    })
  let runtime = AgentRuntime()
  let supervisor = runtime.supervisor
  try await runtime.register(primary)
  try await runtime.register(compact)
  try await runtime.register(agent: AgentDefinition(
    id: "steering-summarizer", instructions: "Summarize evidence", provider: "steering-compact",
    model: "fixture", retry: .none))
  await runtime.configureTaskAgents(.init(compact: "steering-summarizer"))
  try await runtime.register(tool: MaiSkillTools.makeTool(for: skill) { .init(skills: [skill]) })
  try await runtime.register(tool: ClosureTool(definition: .init(
    name: "steer", description: "STEERING CATALOG SCHEMA: accept a queued correction",
    annotations: .init(approval: .automatic))) { _, toolContext in
      let pid = try #require(toolContext.run.pid)
      await supervisor.post(.user("Use corrected.txt and preserve the required review format."), to: pid)
      return ToolOutput(text: "Correction queued")
    })
  let task = AgentMessage.user(directInvocation
    ? skill.prompt(arguments: "input.txt") : "Review input.txt using steering-review")
  let pid = await runtime.allocateProcess(agentID: "main")
  var request = AgentRequest(
    provider: "steering-primary", messages: [.system("STATIC REVIEW RULES"), task],
    toolNames: [skill.toolName, "steer"], limits: .init(maxModelTurns: pauseAtLimit ? 2 : 4),
    toolCallingStrategy: .native, useToolProxy: true,
    retry: .none, autocompact: .init(tokens: 0), context: contextMode)
  var result = try await runtime.run(request, process: pid)
  if pauseAtLimit {
    #expect(result.interruption != nil)
    #expect(result.transcript.last(where: { $0.role == .user })?.text == "Use corrected.txt and preserve the required review format.")
    request.messages = result.transcript
    request.limits = .init(maxModelTurns: 2)
    result = try await runtime.run(request, process: pid)
    #expect(result.isComplete)
  }
  let requests = await primary.requests
  try #require(requests.count == 3)
  let catalogResult = try #require(result.transcript.flatMap(\.toolResults).first { $0.callID == list.id })
  #expect(!catalogResult.isError)
  let catalog = catalogResult.text
  for request in requests.dropFirst() {
    #expect(request.messages.filter { $0.text.contains(skill.body) }.map(\.role) == [.system])
    #expect(request.messages.filter { $0.text.contains(catalog) }.map(\.role) == [.system])
    #expect(request.messages.filter { $0.role == .user }.contains { $0.text.contains("input.txt") })
    #expect(request.messages.flatMap(\.toolCalls).contains { $0.id == list.id })
    #expect(request.messages.flatMap(\.toolResults).contains { $0.callID == list.id })
  }
  #expect(requests[2].messages.contains {
    $0.role == .user && $0.text == "Use corrected.txt and preserve the required review format."
  })
  let preparations = await compact.requests
  #expect(preparations.allSatisfy { request in
    let text = request.messages.map(\.text).joined(separator: "\n")
    return !text.contains(skill.body) && !text.contains(catalog) && !text.contains("STATIC REVIEW RULES")
  })
  _ = try await runtime.run(AgentRequest(
    provider: "steering-primary", messages: result.transcript + [.user("An independent task")],
    toolNames: [skill.toolName, "steer"], toolCallingStrategy: .native, useToolProxy: true,
    retry: .none, autocompact: .init(tokens: 0), context: contextMode), process: pid)
  let next = try #require(await primary.requests.last)
  #expect(!next.messages.contains { $0.text.contains(skill.body) || $0.text.contains(catalog) })
}

@Test("Active-run boundaries protect instructions and the initiating task after queued steering")
func promptContextQueuedSteeringProtection() throws {
  let task = AgentMessage.user("Review original.txt using steering-review")
  let load = ToolCall(
    id: "load", name: ToolProxy.callName,
    arguments: .object(["name": .string("skills_steering-review"), "arguments": .object([:])]))
  let list = ToolCall(id: "list", name: ToolProxy.listName, arguments: .object([:]))
  let sibling = ToolCall(id: "read", name: "files_read", arguments: .object(["path": .string("original.txt")]))
  let messages: [AgentMessage] = [
    .system("STATIC RULES"), .developer("DEVELOPER RULES"),
    .user(String(repeating: "Old task evidence.\n", count: 2000)), .assistant("Old task finished"),
    task,
    AgentMessage(role: .assistant, content: [.toolCall(load), .toolCall(list), .toolCall(sibling)]),
    AgentMessage(role: .tool, content: [.toolResult(.init(callID: load.id, text: String(repeating: "EXACT SKILL INSTRUCTIONS\n", count: 250)))]),
    AgentMessage(role: .tool, content: [.toolResult(.init(callID: list.id, text: String(repeating: "EXACT CATALOG SCHEMA\n", count: 250)))]),
    AgentMessage(role: .tool, content: [.toolResult(.init(callID: sibling.id, content: [
      .file(.init(name: "original.txt", mimeType: "text/plain", text: String(repeating: "SIBLING READ EVIDENCE\n", count: 250))),
    ]))]),
    .user("Use corrected.txt instead"), .assistant("Proceeding with corrected scope"),
  ]
  let protected = Array(messages[4...9]) + Array(messages[0...1])
  let ids = protected.map(\.id)
  for edit in [AgentTranscriptEdit.remove(messageIDs: ids), .compact(messageIDs: ids, summary: "Lossy summary")] {
    let edited = AgentTranscriptEditor.apply([edit], to: messages, activeTaskID: task.id)
    #expect(edited.messages == messages && edited.report.isEmpty)
  }
  let rewrites = ids.map { AgentTranscriptEdit.rewrite(messageID: $0, text: "Lossy rewrite") }
  #expect(AgentTranscriptEditor.apply(rewrites, to: messages, activeTaskID: task.id).messages == messages)
  let view = MaiContextTools.ContextView(messages: messages, activeTaskID: task.id)
  for number in [1, 2, 5, 6, 7, 8, 9, 10] {
    #expect(throws: (any Error).self) { try view.select(String(number)) }
  }
  let selection = try #require(AgentAutocompaction.selection(
    in: messages, preservingRecentTokens: 0, activeTaskID: task.id))
  #expect(Set(selection).isDisjoint(with: ids))
  let compacted = AgentTranscriptEditor.apply(
    [.compact(messageIDs: selection, summary: "Earlier task finished")], to: messages, activeTaskID: task.id)
  #expect(protected.allSatisfy { compacted.messages.contains($0) })
  var outputPruned = messages
  #expect(AgentContextPruning.pruneToolOutput(&outputPruned, activeTaskID: task.id) == nil)
  #expect(outputPruned == messages)
  var readPruned = messages
  #expect(AgentContextPruning.prune(&readPruned, activeTaskID: task.id) == nil)
  #expect(readPruned == messages)
}

private actor SteeringPromptProvider: ChatProvider {
  nonisolated let descriptor: ProviderDescriptor
  var responses: [ProviderResponse]
  private(set) var requests: [ProviderRequest] = []

  init(id: ProviderID, responses: [ProviderResponse]) {
    descriptor = ProviderDescriptor(id: id, displayName: id.rawValue, capabilities: [.nativeToolCalling])
    self.responses = responses
  }

  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws -> ProviderResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw SteeringPromptFixtureError.unexpectedCall }
    return responses.removeFirst()
  }
}

private enum SteeringPromptFixtureError: Error { case unexpectedCall }
