import Foundation
import MaiCore
import MaiDocuments
import Testing

@testable import MaiStandardTools

private struct ArchiveWorkspace {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("mai-archive-\(UUID())")

  init() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func call(
    _ operation: MaiFileWorkspaceTool.Operation, _ path: String, _ destination: String,
    policy: MaiFileAccessPolicy? = nil, writeEnabled: Bool = true
  ) async throws -> ToolOutput {
    try await MaiFileWorkspaceTool(
      operation: operation,
      configuration: .init(
        rootURL: root, writeEnabled: writeEnabled, pathAccessPolicy: policy)
    ).call(
      arguments: .object(["path": .string(path), "destination": .string(destination)]),
      context: .init(
        run: .init(runID: UUID(), parentRunID: nil, agentID: "test", depth: 0), modelTurn: 0))
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test("Files tools round trip XDC contents, including binary and hidden files, without overwriting")
func fileArchivesRoundTrip() async throws {
  let workspace = try ArchiveWorkspace()
  defer { workspace.cleanup() }
  let source = workspace.root.appendingPathComponent("app/.assets")
  try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
  let binary = Data([0, 0xff, 0x80, 42])
  try binary.write(to: source.appendingPathComponent("image.bin"))
  try Data("<html>hello</html>".utf8).write(
    to: source.deletingLastPathComponent().appendingPathComponent("index.html"))
  let packed = try await workspace.call(.zip, "app", "app.xdc")
  #expect(!packed.isError)
  let entries = try ZipArchiveReader.entries(at: workspace.root.appendingPathComponent("app.xdc"))
  #expect(Set(entries.map(\.path)) == ["index.html", ".assets/image.bin"])
  #expect((try await workspace.call(.zip, "app", "app.xdc")).isError)
  #expect(!(try await workspace.call(.unzip, "app.xdc", "unpacked")).isError)
  #expect(
    try Data(contentsOf: workspace.root.appendingPathComponent("unpacked/.assets/image.bin"))
      == binary)
  #expect((try await workspace.call(.unzip, "app.xdc", "unpacked")).isError)
  #expect(!(try await workspace.call(.zip, "unpacked/index.html", "single.zip")).isError)
  #expect(
    try ZipArchiveReader.entries(at: workspace.root.appendingPathComponent("single.zip")).map(
      \.path) == ["index.html"])
}

@Test(
  "Archive extraction rejects traversal and duplicates without leaving partial files",
  arguments: [
    "../escape", "/absolute", "a/../../escape", "a\\evil", "C:/evil", "a/./evil", "a//evil",
    "ok.txt",
  ])
func fileArchivesRejectUnsafeEntries(path: String) async throws {
  let workspace = try ArchiveWorkspace()
  defer { workspace.cleanup() }
  try ZipArchiveWriter.write(
    entries: [
      (path: "ok.txt", data: Data("safe".utf8)),
      (path: path, data: Data("bad".utf8)),
    ], to: workspace.root.appendingPathComponent("bad.zip"))
  #expect((try await workspace.call(.unzip, "bad.zip", "result")).isError)
  #expect(
    !FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("result").path))
}

@Test("Archives honor workspace boundaries, file policy and read-only settings")
func fileArchivesRespectAccess() async throws {
  let workspace = try ArchiveWorkspace()
  defer { workspace.cleanup() }
  try Data("secret".utf8).write(to: workspace.root.appendingPathComponent("secret.txt"))
  let policy = MaiFileAccessPolicy { _, _ in false }
  policy.set(.init(url: workspace.root.appendingPathComponent("secret.txt"), access: .deny))
  #expect((try await workspace.call(.zip, ".", "denied.zip", policy: policy)).isError)
  #expect((try await workspace.call(.zip, "secret.txt", "../escape.zip")).isError)
  #expect(
    (try await workspace.call(.zip, "secret.txt", "readonly.zip", writeEnabled: false)).isError)
  #expect(!(try await workspace.call(.zip, "secret.txt", "secret.zip")).isError)
  policy.set(.init(url: workspace.root.appendingPathComponent("result/secret.txt"), access: .deny))
  #expect((try await workspace.call(.unzip, "secret.zip", "result", policy: policy)).isError)
  #expect((try await workspace.call(.unzip, "secret.zip", "../escape")).isError)
  try FileManager.default.createSymbolicLink(
    at: workspace.root.appendingPathComponent("link"),
    withDestinationURL: workspace.root.appendingPathComponent("secret.txt"))
  #expect((try await workspace.call(.zip, ".", "links.zip")).isError)
}
