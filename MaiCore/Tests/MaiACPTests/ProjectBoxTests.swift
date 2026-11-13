#if os(macOS) || os(Linux)
import Foundation
import MaiCore
import Testing
@testable import MaiACP

@Test("Project boxing persists across launches and follows canonical project and checkout paths")
func projectBoxLookup() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let project = root.appendingPathComponent("project")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  let canonical = project.resolvingSymlinksInPath()
  let boxes = ProjectBoxes(home: AgentHome(rootURL: root.appendingPathComponent("home")))
  #expect(try boxes.find(at: project) == nil)
  var box = ProjectBox(project: canonical.path, baseCommit: String(repeating: "a", count: 40))
  try boxes.save(box)
  let reopened = ProjectBoxes(home: boxes.home)
  #expect(try reopened.find(at: project.appendingPathComponent("src"))?.enabled == true)
  #expect(try reopened.find(at: URL(fileURLWithPath: canonical.path + "-other")) == nil)
  #expect(try reopened.find(at: boxes.workspace(box).appendingPathComponent("src"))?.id == box.id)
  var client = ACPClient.Configuration(command: "pmai", arguments: ["--home", boxes.home.rootURL.path],
    workingDirectory: project, readClientFiles: true)
  client.forwardTools = true
  try client.restrictProjectBoxAccess()
  #expect(!client.readClientFiles && !client.forwardTools)
  #expect(client.command == "/bin/sh")
  #expect(client.remoteWorkingDirectory == canonical.path)
  box.enabled = false
  try reopened.save(box)
  #expect(try boxes.find(at: project)?.enabled == false)
  try Data("broken".utf8).write(to: boxes.directory(box).appendingPathComponent("box.json"))
  #expect(throws: (any Error).self) { try reopened.find(at: project) }
}

@Test("Box creation isolates Git metadata and never mounts the original repository or host control files")
func projectBoxRepository() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
  defer { try? FileManager.default.removeItem(at: root) }
  let bin = root.appendingPathComponent("bin")
  let project = root.appendingPathComponent("project")
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  let engine = bin.appendingPathComponent("docker")
  // A deterministic engine substitute; Git is real. No daemon, downloads or model credentials.
  try Data("#!/bin/sh\nexit 0\n".utf8).write(to: engine)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
  var environment = ProcessInfo.processInfo.environment
  environment["PATH"] = bin.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
  let boxes = ProjectBoxes(home: AgentHome(rootURL: root.appendingPathComponent("home")), environment: environment)
  _ = try await boxes.run("git", ["init", project.path])
  try Data("original\n".utf8).write(to: project.appendingPathComponent("file"))
  _ = try await boxes.run("git", ["-C", project.path, "add", "file"])
  _ = try await boxes.run("git", ["-C", project.path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "base"])
  let base = try await boxes.run("git", ["-C", project.path, "rev-parse", "HEAD"])
  let box = ProjectBox(project: project.path, baseCommit: base)
  // An uncommitted host edit must not enter the guest snapshot.
  try Data("host edit\n".utf8).write(to: project.appendingPathComponent("file"))
  try await boxes.create(box, binary: engine, configuration: Data("{}".utf8))
  let checkout = boxes.workspace(box)
  #expect(try String(contentsOf: checkout.appendingPathComponent("file"), encoding: .utf8) == "original\n")
  try Data("guest edit\n".utf8).write(to: checkout.appendingPathComponent("file"))
  #expect(try String(contentsOf: project.appendingPathComponent("file"), encoding: .utf8) == "host edit\n")
  #expect(!FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".git/objects/info/alternates").path))
  #expect(try await boxes.run("git", ["-C", checkout.path, "remote"]) == "")
  // Execute guest Git in the isolated checkout to verify binary patches and conflict handling.
  let script = "#!/bin/sh\nif [ \"$1\" = exec ]; then shift; shift; cd \"$BOX_TEST_WORKSPACE\" || exit 1; exec \"$@\"; fi\n"
  try Data(script.utf8).write(to: engine)
  environment["BOX_TEST_WORKSPACE"] = checkout.path
  let worker = ProjectBoxes(home: boxes.home, environment: environment)
  await #expect(throws: (any Error).self) { try await worker.apply(box) }
  #expect(try String(contentsOf: project.appendingPathComponent("file"), encoding: .utf8) == "host edit\n")
  try Data("original\n".utf8).write(to: project.appendingPathComponent("file"))
  let bytes = Data([0, 255, 0, 42, 128])
  try bytes.write(to: checkout.appendingPathComponent("binary"))
  try await worker.apply(box)
  #expect(try Data(contentsOf: project.appendingPathComponent("binary")) == bytes)
  #expect(try String(contentsOf: project.appendingPathComponent("file"), encoding: .utf8) == "guest edit\n")
  let args = try boxes.createArguments(box)
  let mounts = args.enumerated().compactMap { index, value in value == "--mount" ? args[index + 1] : nil }
  #expect(mounts.count == 2)
  #expect(mounts.allSatisfy { !$0.contains("src=" + project.path + ",") && !$0.contains("docker.sock") })
  #expect(!args.contains("--privileged"))
  // Shared project history is live state, not a source change to export/apply.
  var shared = box
  shared.sharedConfigurationDirectory = root.appendingPathComponent("config").path
  let metadata = checkout.appendingPathComponent(".pmai")
  try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
  try Data("private conversation\n".utf8).write(to: metadata.appendingPathComponent("chat.json"))
  let sharedPatch = try await worker.diff(shared)
  #expect(!sharedPatch.contains("private conversation"))
  #expect(!sharedPatch.contains(".pmai"))
  #expect(sharedPatch.contains("guest edit"))
  // Container mutations cannot replace host-owned policy.
  #expect(try boxes.find(at: project)?.baseCommit == base)
  try await boxes.destroy(box)
  #expect(try boxes.find(at: project)?.enabled == false)
  #expect(FileManager.default.fileExists(atPath: checkout.path))
}

@Test("Box policies reject unsafe mount roots and ambiguous network settings")
func projectBoxValidation() throws {
  var box = ProjectBox(project: "/project", baseCommit: String(repeating: "b", count: 40))
  for path in ["/", "/opt", "/pmai/home", "/project/../etc", "/project,other"] {
    box.project = path
    #expect(throws: (any Error).self) { try ProjectBoxes.validate(box) }
  }
  box.project = "/project"
  box.network = "host"
  #expect(throws: (any Error).self) { try ProjectBoxes.validate(box) }
  box.network = "none"
  box.ports = ["8080:80"]
  #expect(throws: (any Error).self) { try ProjectBoxes.validate(box) }
  box.network = "bridge"
  try ProjectBoxes.validate(box)
  box.ports = ["0.0.0.0:8080:80"]
  #expect(throws: (any Error).self) { try ProjectBoxes.validate(box) }
}
#endif
