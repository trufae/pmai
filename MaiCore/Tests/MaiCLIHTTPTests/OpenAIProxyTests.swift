import Foundation
import MaiACPGateway
import MaiCore
import Testing

@testable import MaiCLI

private func proxyFixture() async throws -> (AgentRuntime, AgentDefinition) {
  let runtime = AgentRuntime()
  try await runtime.register(HelloProvider())
  let agent = AgentDefinition(id: "fixture", instructions: "", provider: .hello, model: "hello")
  try await runtime.register(agent: agent)
  return (runtime, agent)
}

@Test("HTTP chat routes through the configured agent runtime with isolated messages")
func httpProxyChatRoute() async throws {
  let (runtime, agent) = try await proxyFixture()
  let input = Data(#"{"messages":[{"role":"user","content":"hello"}]}"#.utf8)
  let response = try await OpenAIProxy.respond(
    .init(method: "POST", path: "/v1/chat/completions", body: input),
    runtime: runtime, agent: agent, configuration: nil, environment: [:], allowTools: false)
  #expect(response.status == 200)
  let root = try JSONDecoder().decode(JSONValue.self, from: response.body)
  #expect(root.objectValue?["model"]?.stringValue == "agent:fixture")
  #expect(
    root.objectValue?["choices"]?.arrayValue?.first?.objectValue?["message"]?.objectValue?[
      "content"]?.stringValue?.isEmpty == false)
}

@Test("HTTP streamed chat emits OpenAI SSE chunks and a completion marker")
func httpProxyStreamingRoute() async throws {
  let (runtime, agent) = try await proxyFixture()
  let input = Data(
    #"{"stream":true,"model":"agent:fixture","messages":[{"role":"user","content":"hello"}]}"#.utf8)
  let response = try await OpenAIProxy.respond(
    .init(method: "POST", path: "/v1/chat/completions", body: input),
    runtime: runtime, agent: agent, configuration: nil, environment: [:], allowTools: false)
  #expect(response.contentType == "text/event-stream")
  var data = Data()
  for try await chunk in try #require(response.stream) { data.append(chunk) }
  let events = String(decoding: data, as: UTF8.self)
  #expect(events.contains("chat.completion.chunk"))
  #expect(events.hasSuffix("data: [DONE]\n\n"))
}

@Test("HTTP models advertise configured agents and reject unknown audio providers")
func httpProxyCatalogAndValidation() async throws {
  let (runtime, agent) = try await proxyFixture()
  let catalog = try await OpenAIProxy.respond(
    .init(method: "GET", path: "/v1/models"),
    runtime: runtime, agent: agent, configuration: nil, environment: [:], allowTools: false)
  let root = try JSONDecoder().decode(JSONValue.self, from: catalog.body)
  #expect(
    root.objectValue?["data"]?.arrayValue?.contains {
      $0.objectValue?["id"]?.stringValue == "agent:fixture"
    } == true)
  await #expect(throws: (any Error).self) {
    _ = try await OpenAIProxy.respond(
      .init(
        method: "POST", path: "/v1/audio/speech",
        body: Data(#"{"model":"missing::model","input":"hello","voice":"default"}"#.utf8)),
      runtime: runtime, agent: agent, configuration: nil, environment: [:], allowTools: false)
  }
  let missing = try await OpenAIProxy.respond(
    .init(method: "GET", path: "/missing"),
    runtime: runtime, agent: agent, configuration: nil, environment: [:], allowTools: false)
  #expect(missing.status == 404)
}
