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

@Test("Captured model listings stay readable without ANSI escapes")
func replModelListPlainText() async {
  let terminal = TerminalWriter(capturesOutput: true)
  let row = await terminal.modelCatalogRow(.init(id: "example", capabilities: [.nativeToolCalling, .audioOutput], contextWindow: 32768), selected: true)
  #expect(row.contains("[Tools]") && row.contains("[Voice]") && row.contains("[32K context]"))
  #expect(row.hasPrefix("* example"))
  #expect(!row.contains("\u{1b}"))
}
