/// Tracks the last successful load/save, including an empty document.
struct TextDocumentDraft {
  var text = ""
  private var savedText: String?

  var isLoaded: Bool { savedText != nil }
  var hasChanges: Bool { isLoaded && text != savedText }

  mutating func load(using read: () throws -> String) throws {
    guard !isLoaded else { return }
    let loaded = try read()
    text = loaded
    savedText = loaded
  }

  @discardableResult
  mutating func save(using write: (String) throws -> Void) throws -> Bool {
    guard isLoaded else { return false }
    try write(text)
    savedText = text
    return true
  }
}
