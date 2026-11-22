import MaiCore
import Testing
@testable import MaiCLI

@Test("/models combines provider, feature, context and text filters")
func replModelListFilters() throws {
  let options = try REPLModelListOptions("ollama --vision --tools --context 128K llama", current: .openAI, providers: [.openAI, "ollama"])
  #expect(options.provider == "ollama")
  #expect(options.filter.features == [.tools, .vision])
  #expect(options.filter.search == "llama")
  #expect(options.filter.minimumContextWindow == 131072)
  let search = try REPLModelListOptions("llama --voice", current: .openAI, providers: [.openAI])
  #expect(search.provider == .openAI && search.filter.search == "llama")
  #expect(throws: REPLModelListOptions.Invalid.self) {
    try REPLModelListOptions("--context 9999999999999999999M", current: .openAI, providers: [])
  }
  #expect(throws: REPLModelListOptions.Invalid.self) {
    try REPLModelListOptions("--wat", current: .openAI, providers: [])
  }
}

@Test("Model tables show reported metadata and omit unavailable fields")
func replModelListPlainText() async {
  let pricing = ModelPricing(catalog: .object(["prompt": .integer(0)]))
  let model = ModelDescriptor(id: "example", capabilities: [.nativeToolCalling, .audioOutput],
    contextWindow: 32768, pricing: pricing)
  let bare = ModelDescriptor(id: "plain | **model**")
  let table = MaiCLI.modelCatalogTable([model, bare], selected: "example")
  #expect(table.headers == ["Model", "Features", "Context", "Input $/1M"])
  #expect(table.rows[0].last == "0")
  #expect(table.rows[1].dropFirst().allSatisfy { $0.isEmpty })
  #expect(MaiCLI.modelCatalogTable([bare], selected: nil).headers == ["Model"])
  let terminal = TerminalWriter(capturesOutput: true)
  await terminal.table(table)
  let output = await terminal.drainCaptured()
  #expect(output.contains("Tools, Voice") && output.contains("32K context"))
  #expect(output.contains("* example") && output.contains("plain | **model**"))
  #expect(!output.contains("unknown") && !output.contains("\u{1b}"))
}
