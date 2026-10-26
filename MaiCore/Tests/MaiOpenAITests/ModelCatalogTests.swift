import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import MaiCore
@testable import MaiOpenAI
@testable import MaiTestSupport

@Test("Ollama enriches the portable catalog without hiding models whose metadata fails")
func ollamaModelCatalogEnrichment() async throws {
  let host = "ollama-catalog.example.test"
  StubURLProtocol.install(forHost: host) { request in
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key")
    #expect(request.value(forHTTPHeaderField: "X-Workspace") == "test")
    if request.url?.path == "/proxy/v1/models" {
      return try httpResponse(request, contentType: "application/json",
        body: #"{"data":[{"id":"zeta"},{"id":"alpha"}]}"#)
    }
    #expect(request.url?.path == "/proxy/api/show")
    #expect(request.httpMethod == "POST")
    let body = String(decoding: try requestBodyData(request), as: UTF8.self)
    if body.contains("zeta") {
      return try httpResponse(request, status: 404, contentType: "application/json", body: "{}")
    }
    return try httpResponse(request, contentType: "application/json",
      body: #"{"capabilities":["tools","vision","text-to-speech"],"model_info":{"test.context_length":65536},"voices":["Freya"]}"#)
  }
  defer { StubURLProtocol.reset(host: host) }
  let provider = OpenAICompatibleProvider(configuration: .init(
    displayName: "Ollama", baseURL: URL(string: "https://\(host)/proxy/v1")!, apiKey: "key",
    additionalHeaders: ["X-Workspace": "test"]), session: stubSession())
  let models = try await provider.availableModels()
  #expect(models.map(\.id) == ["alpha", "zeta"])
  #expect(models.first?.contextWindow == 65536)
  #expect(models.first?.capabilities.contains(.nativeToolCalling) == true)
  #expect(models.last?.features.isEmpty == true)
  #expect(try await provider.availableVoices(model: "alpha") == ["Freya"])
}
