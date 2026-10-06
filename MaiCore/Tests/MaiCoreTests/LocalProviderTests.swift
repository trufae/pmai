import Foundation
import MaiCore
import Testing
@testable import MaiLocalProviders

@Test("Local text providers retain native tool calls, structured results, and errors")
func localProviderToolInput() throws {
  let messages = try LocalProviderInput.messages([
    .system("Rules"), .user("Inspect it"),
    .init(role: .assistant, content: [.reasoning("Private"), .toolCall(.init(
      id: "call-1", name: "read", arguments: .object(["path": .string("file")])))]),
    .init(role: .tool, content: [.toolResult(.init(
      callID: "call-1", content: [.text("Failed")], structuredContent: .object(["code": .integer(3)]),
      isError: true))]),
  ])
  #expect(messages[2].text.contains("read"))
  #expect(messages[2].text.contains(#"{"path":"file"}"#))
  #expect(!messages[2].text.contains("Private"))
  #expect(messages[3].text.contains("call-1 (error)"))
  #expect(messages[3].text.contains("Failed"))
  #expect(messages[3].text.contains(#"{"code":3}"#))
}

@Test("Local provider factories accept URL-free configurations even on unavailable hosts")
func localProviderFactories() async throws {
  let registry = PluginRegistry()
  try await registry.install(MaiLocalProvidersPlugin())
  let configuration = MaiConfiguration(providers: [
    .init(id: "phone", kind: .apple),
    .init(id: "gpu", kind: .mlx, defaultModel: "org/model"),
  ])
  let decoded = try JSONDecoder().decode(MaiConfiguration.self, from: configuration.encoded())
  for configured in decoded.providers {
    let provider = try await registry.makeProvider(from: configured, environment: [:])
    #expect(provider.descriptor.id.rawValue == configured.id)
    #expect(provider.descriptor.capabilities.contains(.streaming))
    #expect(provider.descriptor.defaultModel == (configured.kind == .apple ? "on-device" : "org/model"))
  }
}

@Test("Shared MLX validation rejects URLs, paths, unsupported hardware, and simulator inference")
func localProviderValidation() {
  #expect(MLXModels.isValid("mlx-community/LFM2-350M-MLX"))
  for invalid in ["", "org", "org/model/extra", "https://host/model", "/tmp/model", "org/../model", "org/mödél"] {
    #expect(!MLXModels.isValid(invalid))
  }
  #expect(MLXAvailability.evaluate(isSimulator: false, gpuName: "A12", supportsApple7: false) == .unsupportedGPU("A12"))
  #expect(MLXAvailability.evaluate(isSimulator: true, gpuName: "M1", supportsApple7: true) == .simulator)
  #expect(MLXAvailability.evaluate(isSimulator: false, gpuName: nil, supportsApple7: true) == .metalUnavailable)
}

#if canImport(MLXLMCommon)
  import MLXLMCommon

  @Test("MLX loads share a queue and a failed load releases it")
  func serializedMLXLoads() async throws {
    let downloader = LocalTestDownloader()
    let provider = MLXProvider(downloader: downloader, availability: .available)
    async let first: Void = provider.load(modelID: "test/first")
    async let second: Void = provider.load(modelID: "test/second")
    do { try await first } catch {}
    do { try await second } catch {}
    #expect(await downloader.maximumActive == 1)
    #expect(await downloader.requests.count == 2)
  }

  @Test("An unavailable MLX device never starts a download")
  func unavailableMLXLoad() async {
    let downloader = LocalTestDownloader()
    let provider = MLXProvider(downloader: downloader, availability: .unsupportedGPU("A12"))
    do {
      try await provider.load(modelID: "test/model")
      Issue.record("Unsupported hardware accepted a model load")
    } catch {}
    #expect(await downloader.requests.isEmpty)
  }

  private actor LocalTestDownloader: Downloader {
    var requests: [String] = []
    var maximumActive = 0
    private var active = 0
    func download(
      id: String, revision: String?, matching patterns: [String], useLatest: Bool,
      progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
      requests.append(id)
      active += 1
      maximumActive = max(maximumActive, active)
      defer { active -= 1 }
      try await Task.sleep(for: .milliseconds(20))
      throw URLError(.notConnectedToInternet)
    }
  }
#endif
