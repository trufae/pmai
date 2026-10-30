import Foundation
import MaiACP
import Observation

private struct ChatFolder: Codable {
  var id: String
  var name: String
}
private struct FolderSettings: Codable {
  var folders: [ChatFolder] = []
  var assignments: [String: String] = [:]
  var selected = "all"
}

@MainActor @Observable final class ConversationFolders {
  private var settings: FolderSettings
  private let file: URL
  var selected: String { settings.selected }
  init(directory: URL) throws {
    file = directory.appendingPathComponent("folders.json")
    settings = FileManager.default.fileExists(atPath: file.path)
      ? try JSONDecoder().decode(FolderSettings.self, from: Data(contentsOf: file)) : .init()
  }
  func folder(for chat: String) -> String { settings.assignments[chat] ?? "unfiled" }
  func assignNew(_ chat: String) throws {
    if settings.folders.contains(where: { $0.id == selected }) {
      settings.assignments[chat] = selected
      try save()
    }
  }
  func execute(_ command: [String: String]) throws {
    switch command["action"] {
    case "selectFolder": settings.selected = command["id"] ?? "all"
    case "saveFolder":
      let name = (command["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { throw CocoaError(.coderInvalidValue) }
      if let i = settings.folders.firstIndex(where: { $0.id == command["id"] }) { settings.folders[i].name = name }
      else { settings.folders.append(.init(id: UUID().uuidString, name: name)) }
    case "removeFolder":
      let id = command["id"] ?? ""
      settings.folders.removeAll { $0.id == id }
      settings.assignments = settings.assignments.filter { $0.value != id }
      if selected == id { settings.selected = "all" }
    case "moveChat":
      let id = command["folderID"] ?? "unfiled"
      guard id == "unfiled" || settings.folders.contains(where: { $0.id == id }) else { throw CocoaError(.coderInvalidValue) }
      settings.assignments[command["id"] ?? ""] = id
    default: throw CocoaError(.coderInvalidValue)
    }
    try save()
  }
  private func save() throws { try ACPStateFiles.write(settings, to: file) }
  var snapshot: [String: Any] {
    ["selected": selected, "folders": settings.folders.map { ["id": $0.id, "name": $0.name] }]
  }
}
