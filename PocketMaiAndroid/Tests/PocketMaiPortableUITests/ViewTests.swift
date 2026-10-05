import Foundation
import MaiChat
import PocketMaiPortableUI
import SwiftUICore
import Testing

private func flatten(_ node: RenderNode) -> [RenderNode] {
  [node] + node.children.flatMap(flatten)
}

@Test @MainActor
func portableScreensRenderAndCallbacksEditState() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "pmai-ui-test-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try PortableChat(directory: directory)
  let host = ViewHost(PocketMaiView(store: store))
  let nodes = flatten(host.evaluate())
  let tabs = try #require(nodes.first { $0.type == "TabView" })
  #expect(tabs.children.count == 4)
  let chatNodes = flatten(try #require(tabs.children.first))
  let composer = try #require(
    chatNodes.firstIndex { $0.props["placeholder"] == .string("Message") })
  let messages = try #require(chatNodes.firstIndex { $0.type == "ScrollView" })
  #expect(composer < messages) // An expanding pane must not hide the input.
  #expect(nodes.contains { $0.props["text"] == .string("OpenAI-compatible provider") })
  #expect(nodes.contains { $0.props["text"] == .string("System prompts") })
  let url = try #require(
    nodes.first { $0.props["placeholder"] == .string("Base URL (including /v1)") })
  if case .int(let callback)? = url.props["onChange"] {
    host.callbacks.invokeString(Int64(callback), "http://10.0.2.2:8080/v1")
  } else {
    Issue.record("The URL field has no change callback")
  }
  #expect(store.baseURL == "http://10.0.2.2:8080/v1")
  let secret = try #require(
    nodes.first { $0.props["placeholder"] == .string("API key (optional for local servers)") })
  #expect(secret.props["secure"] == .bool(true))
  let updated = flatten(host.evaluate())
  #expect(updated.contains { $0.props["text"] == .string("http://10.0.2.2:8080/v1") })
}
