import Foundation
import MaiChat
import SwiftUICore
import Testing

@testable import PocketMaiPortableUI

private func flatten(_ node: RenderNode) -> [RenderNode] {
  [node] + node.children.flatMap(flatten)
}

private func callback(_ node: RenderNode, _ kind: String, _ key: String) -> Int64? {
  if case .int(let id)? = node.modifiers.first(where: { $0.kind == kind })?.args[key] {
    return Int64(id)
  }
  return nil
}

@Test @MainActor
func portableScreensRenderAndCallbacksEditState() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "pmai-ui-test-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try PortableChat(directory: directory)
  let remote = PortableRemoteChat(directory: directory.appendingPathComponent("remotes"))
  let host = ViewHost(PocketMaiView(store: store, remote: remote))
  var nodes = flatten(host.evaluate())
  #expect(nodes.contains { $0.type == "NavStack" })

  // The navigation bar is a bottom toolbar of icon destinations.
  let bar = try #require(
    nodes.first { $0.type == "ToolbarItem" && $0.props["placement"] == .string("bottomBar") })
  let tabs = flatten(bar).filter { $0.type == "Image" }
  #expect(
    tabs.map(\.props["systemName"])
      == ["house", "gearshape", "person", "calendar", "square.and.arrow.up"].map { .string($0) })
  func open(_ index: Int) throws {
    let tap = try #require(callback(tabs[index], "onTapGesture", "action"))
    host.callbacks.invokeVoid(tap)
    nodes = flatten(host.evaluate())
  }

  // The composer sits below the message pane, pinned to the bottom.
  let composer = try #require(nodes.firstIndex { $0.props["placeholder"] == .string("Message") })
  let messages = try #require(nodes.firstIndex { $0.type == "ScrollView" })
  #expect(messages < composer)

  try open(1)
  #expect(nodes.contains { $0.props["text"] == .string("OpenAI-compatible provider") })
  let url = try #require(
    nodes.first { $0.props["placeholder"] == .string("Base URL (including /v1)") })
  if case .int(let change)? = url.props["onChange"] {
    host.callbacks.invokeString(Int64(change), "http://10.0.2.2:8080/v1")
  } else {
    Issue.record("The URL field has no change callback")
  }
  #expect(store.baseURL == "http://10.0.2.2:8080/v1")
  let secret = try #require(
    nodes.first { $0.props["placeholder"] == .string("API key (optional for local servers)") })
  #expect(secret.props["secure"] == .bool(true))
  nodes = flatten(host.evaluate())
  #expect(nodes.contains { $0.props["text"] == .string("http://10.0.2.2:8080/v1") })

  try open(2)
  #expect(nodes.contains { $0.props["text"] == .string("System prompts") })
  try open(3)
  #expect(nodes.contains { $0.props["text"] == .string("No saved chats") })
  try open(4)
  #expect(nodes.contains { $0.props["text"] == .string("Remote hosts") })
  let invite = try #require(
    nodes.first { $0.props["placeholder"] == .string("pmai-acp://connect/…") })
  if case .int(let change)? = invite.props["onChange"] {
    host.callbacks.invokeString(Int64(change), "connection-invitation")
  } else {
    Issue.record("The remote invitation field has no change callback")
  }
  #expect(remote.invitation == "connection-invitation")
}

@Test @MainActor
func portableThemePickerPersistsAndPreservesDraft() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "pmai-theme-test-\(UUID())")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let previousBackend = AppStorageStore.backend
  defer {
    AppStorageStore.backend = previousBackend
    try? FileManager.default.removeItem(at: directory)
  }
  AppStorageStore.backend = FileAppStorage(directory: directory.path)
  let store = try PortableChat(directory: directory)
  store.draft = "Keep this draft"
  let host = ViewHost(PocketMaiView(store: store))
  let initial = host.evaluate()
  #expect(initial.modifiers.first { $0.kind == "preferredColorScheme" }?.args.isEmpty == true)
  let settings = try #require(
    flatten(initial).first {
      $0.type == "Image" && $0.props["systemName"] == .string("gearshape")
    })
  host.callbacks.invokeVoid(try #require(callback(settings, "onTapGesture", "action")))

  for theme in ["dark", "light", "system", "dark"] {
    let picker = try #require(
      flatten(host.evaluate()).first {
        $0.type == "Picker" && $0.props["title"] == .string("App theme")
      })
    guard case .int(let id)? = picker.props["onChange"] else {
      Issue.record("The theme picker has no change callback")
      return
    }
    host.callbacks.invokeString(Int64(id), theme)
    let tree = host.evaluate()
    let expected: PropValue? = theme == "system" ? nil : .string(theme)
    #expect(
      tree.modifiers.first { $0.kind == "preferredColorScheme" }?.args["colorScheme"] == expected)
    #expect(store.draft == "Keep this draft")
  }

  AppStorageStore.backend = FileAppStorage(directory: directory.path)
  let reloaded = ViewHost(PocketMaiView(store: try PortableChat(directory: directory))).evaluate()
  #expect(
    reloaded.modifiers.first { $0.kind == "preferredColorScheme" }?.args["colorScheme"]
      == .string("dark"))
}

@Test @MainActor
func markdownRepliesRenderAsBlocks() throws {
  let markdown = """
    # Title

    Use **bold** and *italic* text, see [the docs](https://example.com/docs) or https://ollama.com.

    **Entirely bold**

    - first
    - second

    1. one

    > quoted

    ```swift
    let x = 1
    ```

    | Name | Size |
    |------|------|
    | a | 1 |

    ---
    """
  let nodes = flatten(ViewHost(MarkdownText(markdown)).evaluate())
  func text(_ value: String) -> RenderNode? {
    nodes.first { $0.type == "Text" && $0.props["text"] == .string(value) }
  }
  func font(_ node: RenderNode?) -> [String: PropValue]? {
    node?.modifiers.first { $0.kind == "font" }?.args
  }

  #expect(font(text("Title"))?["size"] == .double(24))
  #expect(font(text("Title"))?["weight"] == .string("bold"))
  // Inline markers are removed; a mixed paragraph stays in the body font.
  let paragraph = text("Use bold and italic text, see the docs or https://ollama.com.")
  #expect(font(paragraph)?["weight"] == nil)
  #expect(font(text("Entirely bold"))?["weight"] == .string("bold"))
  let links = nodes.filter { $0.type == "Link" }.map { $0.props["url"] }
  #expect(links == [.string("https://example.com/docs"), .string("https://ollama.com")])
  #expect(text("↗ the docs") != nil)
  #expect(text("•") != nil && text("first") != nil && text("1.") != nil)
  #expect(text("quoted") != nil)
  #expect(text("let x = 1") != nil && text("swift") != nil)
  #expect(text("Name") != nil && text("a") != nil)
  #expect(nodes.contains { $0.type == "Divider" })
}
