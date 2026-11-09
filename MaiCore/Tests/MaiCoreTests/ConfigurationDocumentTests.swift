import Foundation
import Testing
@testable import MaiCore

@Test("Settings edits retain unknown configuration and provider fields")
func configurationDocumentPreservesFields() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("pmai.json")
  try Data(#"{"future":{"enabled":true},"providers":[{"id":"test","kind":"hello","futureCredential":"keep","options":{"custom":7}}],"prompts":{"future":"keep","user":{"hello":"Hi"}}}"#.utf8).write(to: url)
  var document = try ConfigurationDocument(url: url)
  var configuration = document.configuration
  configuration.providers[0].defaultModel = "hello"
  configuration.setUserPrompt("review", text: "Review $ARGUMENTS")
  try document.save(configuration)
  let saved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
  #expect(saved.objectValue?["future"]?.objectValue?["enabled"] == .bool(true))
  #expect(saved.objectValue?["providers"]?.arrayValue?.first?.objectValue?["futureCredential"] == .string("keep"))
  #expect(saved.objectValue?["prompts"]?.objectValue?["future"] == .string("keep"))
  #expect(try MaiConfiguration.load(from: url).providers[0].defaultModel == "hello")
  #expect(try MaiConfiguration.load(from: url).userPromptName(matching: "review") == "review")
}

@Test("An open Settings editor cannot overwrite an external configuration edit")
func configurationDocumentConflict() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("config.json")
  try Data("{}".utf8).write(to: url)
  var document = try ConfigurationDocument(url: url)
  var configuration = document.configuration
  configuration.setUserPrompt("new", text: "New")
  let external = Data(#"{"prompts":{"user":{"external":"Keep me"}}}"#.utf8)
  try external.write(to: url, options: .atomic)
  #expect(throws: MaiConfigurationError.self) { try document.save(configuration) }
  #expect(try Data(contentsOf: url) == external)
}

@Test("New workspace settings inherit their template and reject invalid saves")
func configurationDocumentCreation() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("pmai.json")
  let seed = Data(#"{"future":42,"providers":[{"id":"local","kind":"hello"}]}"#.utf8)
  var document = try ConfigurationDocument(url: url, initialData: seed)
  #expect(!FileManager.default.fileExists(atPath: url.path))
  var configuration = document.configuration
  configuration.setUserPrompt("new", text: "New")
  try document.save(configuration)
  #expect(try MaiConfiguration.load(from: url).providers.map(\.id) == ["local"])
  let saved = try Data(contentsOf: url)
  #expect(try JSONDecoder().decode(JSONValue.self, from: saved).objectValue?["future"] == .integer(42))
  configuration.defaultAgent = "missing"
  #expect(throws: MaiConfigurationError.self) { try document.save(configuration) }
  #expect(try Data(contentsOf: url) == saved)
}
