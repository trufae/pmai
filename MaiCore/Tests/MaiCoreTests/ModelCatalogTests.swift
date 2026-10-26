import Foundation
import Testing
@testable import MaiCore

@Test("Catalog extensions preserve declared capabilities and unknowns")
func modelCatalogMetadata() throws {
  let data = Data(#"{"id":"multi","capabilities":["tools","vision","thinking","decision","text-to-speech"],"model_info":{"llama.context_length":131072},"voices":["Freya"],"architecture":{"modality":"text+image->audio"}}"#.utf8)
  let object = try #require(JSONDecoder().decode(JSONValue.self, from: data).objectValue)
  let model = try #require(ModelDescriptor.catalogEntry(object))
  #expect(Set(model.features) == Set(ModelFeature.allCases))
  #expect(model.capabilities.contains(.audioOutput))
  #expect(model.contextWindow == 131072)
  #expect(model.voices == ["Freya"])
  #expect(model.inputModalities == ["text", "image"])
  #expect(model.outputModalities == ["audio"])
  #expect(try JSONDecoder().decode(ModelDescriptor.self, from: JSONEncoder().encode(model)) == model)
  let unknown = try #require(ModelDescriptor.catalogEntry(["id": .string("unknown")]))
  #expect(unknown.features.isEmpty)
  #expect(unknown.contextWindow == nil)
  let old = try JSONDecoder().decode(ModelDescriptor.self, from: Data(#"{"id":"legacy"}"#.utf8))
  #expect(old.id == "legacy" && old.contextWindow == nil && old.outputModalities == nil)
}

@Test("Catalog filters intersect features, search terms and context, then sort alphabetically")
func modelCatalogFiltering() {
  let models = [
    ModelDescriptor(id: "Zulu-free", capabilities: [.nativeToolCalling, .imageInput], contextWindow: 131072),
    ModelDescriptor(id: "alpha", capabilities: [.nativeToolCalling, .imageInput], contextWindow: 32768),
    ModelDescriptor(id: "beta", capabilities: [.nativeToolCalling]),
    ModelDescriptor(id: "speech", capabilities: [.audioOutput]),
    ModelDescriptor(id: "listen", capabilities: [.audioInput]),
  ]
  #expect(ModelCatalogFilter().applying(to: models).map(\.id) == ["alpha", "beta", "listen", "speech", "Zulu-free"])
  #expect(ModelCatalogFilter(search: "ZULU tools", features: [.tools, .vision], minimumContextWindow: 131072)
    .applying(to: models).map(\.id) == ["Zulu-free"])
  #expect(ModelCatalogFilter(features: [.voice], requiredCapabilities: [.audioOutput])
    .applying(to: models).map(\.id) == ["speech"])
  #expect(!ModelCatalogFilter(features: [.decision]).matches(models[0]))
}

@Test("False capability flags are not advertised as supported")
func modelCatalogFalseCapabilities() throws {
  let object = try #require(JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":"plain","capabilities":{"image_input":{"supported":false},"tools":false,"reasoning":{"supported":true}},"supported_parameters":["tools"],"context_length":8192}"#.utf8)).objectValue)
  let model = try #require(ModelDescriptor.catalogEntry(object))
  #expect(!model.capabilities.contains(.imageInput))
  #expect(model.inputModalities == ["text"])
  #expect(model.features == [.tools, .reasoning])
}
