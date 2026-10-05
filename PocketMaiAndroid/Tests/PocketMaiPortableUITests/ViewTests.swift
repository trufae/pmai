import Foundation
import MaiChat
@testable import PocketMaiPortableUI
import SwiftUICore
import Testing

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
  let host = ViewHost(PocketMaiView(store: store))
  var nodes = flatten(host.evaluate())
  #expect(nodes.contains { $0.type == "NavStack" })

  // The navigation bar is a bottom toolbar of icon destinations.
  let bar = try #require(
    nodes.first { $0.type == "ToolbarItem" && $0.props["placement"] == .string("bottomBar") })
  let tabs = flatten(bar).filter { $0.type == "Image" }
  #expect(
    tabs.map(\.props["systemName"])
      == ["house", "gearshape", "person", "calendar"].map { .string($0) })
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
