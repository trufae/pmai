import Foundation
import Testing

@testable import MaiStandardTools

private func fileBrowserFixture() throws -> (URL, URL) {
  let base = FileManager.default.temporaryDirectory.appendingPathComponent("pmai-browser-\(UUID())")
  let root = base.appendingPathComponent("project")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return (base, root)
}

@Test("Workspace browsing pages through directories, hidden files, and literal filenames")
func workspaceFilesList() async throws {
  let (base, root) = try fileBrowserFixture()
  defer { try? FileManager.default.removeItem(at: base) }
  let files = MaiWorkspaceFiles(configuration: .init(rootURL: root))
  try Data("spaces".utf8).write(to: root.appendingPathComponent(" leading and trailing "))
  try Data().write(to: root.appendingPathComponent(".hidden"))
  _ = try await files.request(.init(.mkdir, path: "folder"))
  let first = try #require(try await files.request(.init(.list, limit: 1)).listing)
  #expect(first.entries.first?.isDirectory == true && first.nextOffset == 1)
  let second = try #require(try await files.request(.init(.list, offset: 1, limit: 1)).listing)
  #expect(second.entries.first?.name == " leading and trailing " && second.nextOffset == nil)
  let hidden = try #require(try await files.request(.init(.list, showHidden: true)).listing)
  #expect(hidden.entries.contains { $0.name == ".hidden" })
  let content = try #require(
    try await files.request(.init(.read, path: " leading and trailing ")).chunk)
  #expect(String(decoding: content.data, as: UTF8.self) == "spaces")
}

@Test("Binary uploads commit only complete sequential chunks and preserve existing files")
func workspaceFilesTransfers() async throws {
  let (base, root) = try fileBrowserFixture()
  defer { try? FileManager.default.removeItem(at: base) }
  let files = MaiWorkspaceFiles(configuration: .init(rootURL: root, temporaryDirectoryURL: base))
  let destination = root.appendingPathComponent("binary.dat")
  let bytes = Data((0..<WorkspaceFileRequest.chunkSize + 17).map { UInt8($0 % 256) })
  let id = try #require(try await files.request(.init(.uploadBegin, path: "binary.dat")).transferID)
  _ = try await files.request(
    .init(.uploadChunk, transferID: id, data: bytes.prefix(WorkspaceFileRequest.chunkSize)))
  #expect(!FileManager.default.fileExists(atPath: destination.path))
  await #expect(throws: WorkspaceFileError.self) {
    _ = try await files.request(.init(.uploadChunk, transferID: id, data: Data([1])))
  }
  _ = try await files.request(
    .init(
      .uploadChunk, offset: WorkspaceFileRequest.chunkSize,
      transferID: id, data: bytes.suffix(17)))
  _ = try await files.request(.init(.uploadFinish, offset: bytes.count, transferID: id))
  #expect(try Data(contentsOf: destination) == bytes)
  let first = try #require(try await files.request(.init(.read, path: "binary.dat")).chunk)
  let last = try #require(
    try await files.request(
      .init(
        .read, path: "binary.dat",
        offset: first.data.count, version: first.version)
    ).chunk)
  #expect(first.data + last.data == bytes)
  await #expect(throws: WorkspaceFileError.self) {
    _ = try await files.request(.init(.uploadBegin, path: "binary.dat"))
  }
  let replace = try #require(
    try await files.request(.init(.uploadBegin, path: "binary.dat", overwrite: true)).transferID)
  _ = try await files.request(.init(.uploadChunk, transferID: replace, data: Data([42])))
  #expect(try Data(contentsOf: destination) == bytes)
  _ = try await files.request(.init(.uploadFinish, offset: 1, transferID: replace))
  #expect(try Data(contentsOf: destination) == Data([42]))
  await #expect(throws: WorkspaceFileError.self) {
    _ = try await files.request(.init(.read, path: "binary.dat", version: first.version))
  }
  let cancel = try #require(
    try await files.request(.init(.uploadBegin, path: "cancelled")).transferID)
  _ = try await files.request(.init(.uploadCancel, transferID: cancel))
  #expect(
    !FileManager.default.fileExists(
      atPath: base.appendingPathComponent("pmai-upload-\(cancel)").path))
  let empty = try #require(try await files.request(.init(.uploadBegin, path: "empty")).transferID)
  _ = try await files.request(.init(.uploadFinish, transferID: empty))
  #expect(try Data(contentsOf: root.appendingPathComponent("empty")).isEmpty)
  _ = try await files.request(.init(.uploadBegin, path: "abandoned"))
  await files.close()
  #expect(try FileManager.default.contentsOfDirectory(atPath: base.path) == ["project"])
}

@Test("The browser retains Files tool confinement and read-only policy")
func workspaceFilesConfinement() async throws {
  let (base, root) = try fileBrowserFixture()
  defer { try? FileManager.default.removeItem(at: base) }
  let outside = base.appendingPathComponent("private.txt")
  try Data("private".utf8).write(to: outside)
  try FileManager.default.createSymbolicLink(
    at: root.appendingPathComponent("escape"), withDestinationURL: base)
  let files = MaiWorkspaceFiles(configuration: .init(rootURL: root))
  for operation in [WorkspaceFileRequest.Operation.read, .uploadBegin, .mkdir] {
    for path in ["../private.txt", "escape/private.txt"] {
      await #expect(throws: (any Error).self) {
        _ = try await files.request(.init(operation, path: path))
      }
    }
  }
  let listing = try #require(try await files.request(.init(.list)).listing)
  #expect(listing.entries.isEmpty)
  let readOnly = MaiWorkspaceFiles(configuration: .init(rootURL: root, writeEnabled: false))
  await #expect(throws: WorkspaceFileError.self) {
    _ = try await readOnly.request(.init(.mkdir, path: "new"))
  }
  try Data().write(to: root.appendingPathComponent("small"))
  await #expect(throws: WorkspaceFileError.self) {
    _ = try await files.request(.init(.read, path: "small", limit: -1))
  }
}
