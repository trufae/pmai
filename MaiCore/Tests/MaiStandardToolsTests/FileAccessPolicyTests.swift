import Foundation
import MaiCore
import Testing

@testable import MaiStandardTools

private actor PathConfirmations {
  var urls: [URL] = []
  var approve = true

  func decide(_ url: URL) -> Bool {
    urls.append(url)
    return approve
  }
  func reject() { approve = false }
}

private struct PathFixture {
  let base = FileManager.default.temporaryDirectory.appendingPathComponent("mai-policy-\(UUID())")
  var root: URL { base.appendingPathComponent("workspace") }
  var secret: URL { root.appendingPathComponent("private") }
  var external: URL { base.appendingPathComponent("external") }

  init() throws {
    for url in [root, secret, external] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    for url in [
      root.appendingPathComponent("public.txt"), secret.appendingPathComponent("secret.txt"),
      external.appendingPathComponent("outside.txt"),
    ] {
      try Data("sensitive needle".utf8).write(to: url)
    }
  }

  func tool(_ operation: MaiFileWorkspaceTool.Operation, policy: MaiFileAccessPolicy)
    -> MaiFileWorkspaceTool
  {
    .init(operation: operation, configuration: .init(rootURL: root, pathAccessPolicy: policy))
  }

  func cleanup() { try? FileManager.default.removeItem(at: base) }
}

private func policyCall(_ tool: MaiFileWorkspaceTool, _ args: [String: JSONValue]) async throws
  -> ToolOutput
{
  try await tool.call(
    arguments: .object(args),
    context: .init(
      run: .init(runID: UUID(), parentRunID: nil, agentID: "test", depth: 0), modelTurn: 0))
}

@Test("Path denials apply to existing tool instances, symlink aliases, and searches")
func filePathPolicyDenials() async throws {
  let fixture = try PathFixture()
  defer { fixture.cleanup() }
  let policy = MaiFileAccessPolicy { _, _ in
    Issue.record("A deny must never prompt")
    return true
  }
  let read = fixture.tool(.read, policy: policy)
  #expect(!(try await policyCall(read, ["path": .string("private/secret.txt")])).isError)
  policy.set(.init(url: fixture.secret, access: .deny))
  policy.set(.init(url: fixture.secret.appendingPathComponent("secret.txt"), access: .allow))
  #expect((try await policyCall(read, ["path": .string("private/secret.txt")])).isError)
  try FileManager.default.createSymbolicLink(
    at: fixture.root.appendingPathComponent("alias"), withDestinationURL: fixture.secret)
  #expect((try await policyCall(read, ["path": .string("alias/secret.txt")])).isError)
  for operation in [MaiFileWorkspaceTool.Operation.list, .find, .grep] {
    let output = try await policyCall(
      fixture.tool(operation, policy: policy), ["query": .string("*")])
    #expect(!output.isError)
    #expect(!output.text.contains("private"))
    #expect(!output.text.contains("alias"))
  }
  let grep = try await policyCall(fixture.tool(.grep, policy: policy), ["query": .string("needle")])
  #expect(grep.text.contains("public.txt"))
  #expect(!grep.text.contains("secret.txt"))
  policy.remove(fixture.secret)
  #expect(!(try await policyCall(read, ["path": .string("private/secret.txt")])).isError)
}

@Test("Hidden path defaults prompt for new dotfiles, directories, and symlink aliases")
func filePathPolicyHiddenDefaults() async throws {
  let fixture = try PathFixture()
  defer { fixture.cleanup() }
  let confirmations = PathConfirmations()
  let policy = MaiFileAccessPolicy(hidden: .ask) { url, _ in await confirmations.decide(url) }
  let read = fixture.tool(.read, policy: policy)
  let hidden = fixture.root.appendingPathComponent(".env")
  try Data("hidden secret".utf8).write(to: hidden)
  let directory = fixture.root.appendingPathComponent("private/.credentials")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try Data("nested secret".utf8).write(to: directory.appendingPathComponent("key"))
  try FileManager.default.createSymbolicLink(
    at: fixture.root.appendingPathComponent("visible-alias"), withDestinationURL: hidden)
  try FileManager.default.createSymbolicLink(
    at: fixture.root.appendingPathComponent(".hidden-alias"),
    withDestinationURL: fixture.root.appendingPathComponent("public.txt"))
  for path in [".env", ".env", "private/.credentials/key", "visible-alias", ".hidden-alias"] {
    #expect(!(try await policyCall(read, ["path": .string(path)])).isError)
  }
  #expect(await confirmations.urls.count == 5)
  #expect(!(try await policyCall(
    fixture.tool(.write, policy: policy),
    ["path": .string(".new-secret"), "content": .string("new secret")])).isError)
  #expect(await confirmations.urls.count == 6)
  policy.set(.init(url: hidden, access: .ask, descendants: false))
  #expect(!(try await policyCall(
    fixture.tool(.find, policy: policy), ["query": .string("*")])).isError)
  #expect(await confirmations.urls.count == 6)
  await confirmations.reject()
  let rejected = try await policyCall(read, ["path": .string(".env")])
  #expect(rejected.isError)
  #expect(!rejected.text.contains("hidden secret"))
  policy.set(.init(url: hidden, access: .allow, descendants: false))
  #expect(!(try await policyCall(read, ["path": .string(".env")])).isError)
  policy.remove(hidden)
  policy.setHidden(.deny)
  #expect((try await policyCall(read, ["path": .string(".env")])).isError)
}

@Test("Directory mutations authorize hidden descendants, including through visible symlinks")
func filePathPolicyHiddenTreeMutations() async throws {
  let fixture = try PathFixture()
  defer { fixture.cleanup() }
  let confirmations = PathConfirmations()
  let policy = MaiFileAccessPolicy(hidden: .ask) { url, _ in await confirmations.decide(url) }
  let hidden = fixture.secret.appendingPathComponent(".key")
  try Data("hidden secret".utf8).write(to: hidden)
  try FileManager.default.createSymbolicLink(
    at: fixture.root.appendingPathComponent("alias"), withDestinationURL: fixture.secret)
  await confirmations.reject()
  for (operation, path) in [(MaiFileWorkspaceTool.Operation.delete, "private"),
    (.rename, "private"), (.rename, "alias")] {
    let result = try await policyCall(
      fixture.tool(operation, policy: policy),
      ["path": .string(path), "new_path": .string("moved"), "recursive": .bool(true)])
    #expect(result.isError)
    #expect(FileManager.default.fileExists(atPath: hidden.path))
  }
  #expect(await confirmations.urls.count == 3)
  policy.set(.init(url: hidden, access: .deny, descendants: false))
  #expect((try await policyCall(
    fixture.tool(.rename, policy: policy),
    ["path": .string("alias"), "new_path": .string("moved")])).isError)
  #expect(await confirmations.urls.count == 3)
  policy.remove(hidden)
  policy.setHidden(.deny)
  #expect((try await policyCall(
    fixture.tool(.delete, policy: policy),
    ["path": .string("private"), "recursive": .bool(true)])).isError)
  #expect(await confirmations.urls.count == 3)
  policy.set(.init(url: hidden, access: .allow, descendants: false))
  #expect((try await policyCall(
    fixture.tool(.rename, policy: policy),
    ["path": .string("private"), "new_path": .string("moved")])).isError)
  policy.setHidden(.allow)
  #expect(!(try await policyCall(
    fixture.tool(.rename, policy: policy),
    ["path": .string("private"), "new_path": .string("moved")])).isError)
  #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("moved/.key").path))
}

@Test("Directory removal and rename cannot bypass protected descendants or destinations")
func filePathPolicyTreeMutations() async throws {
  let fixture = try PathFixture()
  defer { fixture.cleanup() }
  let policy = MaiFileAccessPolicy { _, _ in
    Issue.record("A deny must never prompt")
    return true
  }
  let file = fixture.secret.appendingPathComponent("secret.txt")
  policy.set(.init(url: file, access: .deny, descendants: false))
  for operation in [MaiFileWorkspaceTool.Operation.delete, .rename] {
    let result = try await policyCall(
      fixture.tool(operation, policy: policy),
      [
        "path": .string("private"), "new_path": .string("moved"), "recursive": .bool(true),
      ])
    #expect(result.isError)
    #expect(FileManager.default.fileExists(atPath: file.path))
  }
  let rename = try await policyCall(
    fixture.tool(.rename, policy: policy),
    [
      "path": .string("public.txt"), "new_path": .string("private/secret.txt"),
    ])
  #expect(rename.isError)
  let write = try await policyCall(
    fixture.tool(.write, policy: policy),
    [
      "path": .string("private/secret.txt"), "content": .string("changed"),
      "mode": .string("overwrite"),
    ])
  #expect(write.isError)
  #expect(try String(contentsOf: file, encoding: .utf8) == "sensitive needle")
}

@Test("Ask rules prompt on every call, including allowed roots and searches")
func filePathPolicyAsksEveryTime() async throws {
  let fixture = try PathFixture()
  defer { fixture.cleanup() }
  let confirmations = PathConfirmations()
  let policy = MaiFileAccessPolicy { url, _ in await confirmations.decide(url) }
  policy.set(.init(url: fixture.secret, access: .ask))
  let read = fixture.tool(.read, policy: policy)
  for _ in 0..<2 {
    #expect(!(try await policyCall(read, ["path": .string("private/secret.txt")])).isError)
  }
  #expect(await confirmations.urls.count == 2)
  #expect(
    !(try await policyCall(fixture.tool(.grep, policy: policy), ["query": .string("needle")]))
      .isError)
  #expect(await confirmations.urls.count == 3)
  await confirmations.reject()
  let rejected = try await policyCall(read, ["path": .string("private/secret.txt")])
  #expect(rejected.isError)
  #expect(!rejected.text.contains("sensitive needle"))
}

@Test("Outside ask grants apply to one operation; allow and revoke keep file boundaries")
func filePathPolicyOutsideScope() async throws {
  let fixture = try PathFixture()
  defer { fixture.cleanup() }
  let confirmations = PathConfirmations()
  let policy = MaiFileAccessPolicy(outside: .ask) { url, _ in await confirmations.decide(url) }
  let read = fixture.tool(.read, policy: policy)
  let file = fixture.external.appendingPathComponent("outside.txt")
  for _ in 0..<2 {
    #expect(!(try await policyCall(read, ["path": .string(file.path)])).isError)
  }
  #expect(await confirmations.urls.count == 2)
  policy.setOutside(.deny)
  #expect((try await policyCall(read, ["path": .string(file.path)])).isError)
  policy.set(.init(url: file, access: .allow, descendants: false))
  #expect(!(try await policyCall(read, ["path": .string(file.path)])).isError)
  #expect(
    (try await policyCall(
      fixture.tool(.list, policy: policy), ["path": .string(fixture.external.path)])).isError)
  policy.remove(file)
  #expect((try await policyCall(read, ["path": .string(file.path)])).isError)
  #expect(await confirmations.urls.count == 2)
}

@Test("External symlink targets require their own authorization and sibling prefixes do not match")
func filePathPolicySymlinkScope() async throws {
  let fixture = try PathFixture()
  defer { fixture.cleanup() }
  let confirmations = PathConfirmations()
  let policy = MaiFileAccessPolicy(outside: .ask) { url, _ in await confirmations.decide(url) }
  let file = fixture.external.appendingPathComponent("outside.txt")
  try FileManager.default.createSymbolicLink(
    at: fixture.root.appendingPathComponent("link.txt"), withDestinationURL: file)
  #expect(
    !(try await policyCall(fixture.tool(.read, policy: policy), ["path": .string("link.txt")]))
      .isError)
  #expect(await confirmations.urls == [file.standardizedFileURL.resolvingSymlinksInPath()])
  policy.setOutside(.deny)
  policy.set(.init(url: fixture.external, access: .allow))
  let sibling = fixture.base.appendingPathComponent("external-other.txt")
  try Data("not allowed".utf8).write(to: sibling)
  #expect(
    (try await policyCall(fixture.tool(.read, policy: policy), ["path": .string(sibling.path)]))
      .isError)
}

@Test("VDB respects revoked source paths and protected index files")
func filePathPolicyVectorDatabase() async throws {
  let fixture = try PathFixture()
  defer { fixture.cleanup() }
  let policy = MaiFileAccessPolicy { _, _ in
    Issue.record("A deny must never prompt")
    return true
  }
  let tool = MaiVectorDatabaseTool(
    configuration: .init(rootURL: fixture.root, pathAccessPolicy: policy))
  let context = ToolExecutionContext(
    run: .init(runID: UUID(), parentRunID: nil, agentID: "test", depth: 0), modelTurn: 0)
  #expect(
    !(try await tool.call(arguments: .object(["action": .string("index")]), context: context))
      .isError)
  policy.set(.init(url: fixture.secret, access: .deny))
  let queried = try await tool.call(
    arguments: .object(["query": .string("needle")]), context: context)
  #expect(!queried.text.contains("private/secret.txt"))
  policy.set(.init(url: fixture.root.appendingPathComponent(".pmai"), access: .deny))
  #expect(
    (try await tool.call(arguments: .object(["action": .string("status")]), context: context))
      .isError)
}

@Test("Exact new-file grants cannot create unapproved parent directories")
func filePathPolicyNewFiles() async throws {
  let fixture = try PathFixture()
  defer { fixture.cleanup() }
  let policy = MaiFileAccessPolicy { _, _ in
    Issue.record("Explicit grants do not prompt")
    return false
  }
  let file = fixture.external.appendingPathComponent("new.txt")
  policy.set(.init(url: file, access: .allow, descendants: false))
  let write = fixture.tool(.write, policy: policy)
  #expect(
    !(try await policyCall(write, ["path": .string(file.path), "content": .string("new")])).isError)
  let nested = fixture.external.appendingPathComponent("unapproved/new.txt")
  policy.set(.init(url: nested, access: .allow, descendants: false))
  #expect(
    (try await policyCall(write, ["path": .string(nested.path), "content": .string("new")])).isError
  )
  #expect(!FileManager.default.fileExists(atPath: nested.deletingLastPathComponent().path))
}

@Test("Policy changes invalidate outstanding one-operation confirmations")
func filePathPolicyChangesDuringConfirmation() async throws {
  let fixture = try PathFixture()
  defer { fixture.cleanup() }
  let policy = MaiFileAccessPolicy(outside: .ask) { _, _ in true }
  let configuration = MaiFileWorkspaceConfiguration(rootURL: fixture.root, pathAccessPolicy: policy)
  let authorized = try await configuration.authorizing(
    paths: [fixture.external.path], operation: "test")
  let file = fixture.external.appendingPathComponent("outside.txt")
  #expect(authorized.permits(file))
  policy.set(.init(url: file, access: .ask, descendants: false))
  #expect(!authorized.permits(file))
}

@Test("Rebuilding standard tools retains host Files restrictions")
func filePathPolicyFactoryConfiguration() async throws {
  let fixture = try PathFixture()
  defer { fixture.cleanup() }
  let policy = MaiFileAccessPolicy { _, _ in false }
  policy.set(.init(url: fixture.secret, access: .deny))
  let factory = MaiStandardToolFactory(configureFiles: { files in
    var files = files
    files.pathAccessPolicy = policy
    return files
  })
  let tools = try await factory.makeTools(context: .init(
    id: "test", options: ["filesRoot": .string(fixture.root.path)]))
  let read = try #require(tools.compactMap { $0 as? MaiFileWorkspaceTool }.first { $0.operation == .read })
  #expect(read.configuration.pathAccessPolicy === policy)
  #expect((try await policyCall(read, ["path": .string("private/secret.txt")])).isError)
  let vector = try #require(tools.compactMap { $0 as? MaiVectorDatabaseTool }.first)
  #expect(vector.configuration.pathAccessPolicy === policy)
}
