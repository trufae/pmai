import Foundation
import Testing
@testable import MaiCLI

@Test("Path completion follows command arguments, shell quoting, and directories")
func replPathCompletion() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  for file in ["prompt.txt", "prompt space.txt", ".hidden", "café.txt"] {
    try "fixture".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
  }
  let nested = root.appendingPathComponent("nested folder", isDirectory: true)
  try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
  try "nested".write(to: nested.appendingPathComponent("input.txt"), atomically: true, encoding: .utf8)
  func complete(_ line: String) -> [String] { REPLPathCompletion.candidates(for: line, directory: root) }

  for prefix in [". ", "/skills import ", "/skills import --user ", "/remote pair ",
    "/provider add test --api-key-file ", "/msg last > ", "/msg last >> "]
  {
    #expect(complete(prefix + "prom") == [prefix + "prompt\\ space.txt", prefix + "prompt.txt"].sorted())
    #expect(complete(prefix + "\"prompt s") == [prefix + "\"prompt space.txt\""])
    #expect(complete(prefix + "'prompt s") == [prefix + "'prompt space.txt'"])
  }
  for prefix in ["/import ", "/attach ", "/attach source ", "/attach markdown ", "/attach copy ",
    "/copy ", "/copy 3 ", "/export markdown ", "/export archive ", "/image ocr ",
    "/vdb index ", "/vdb del ", "/path allow ", "/path deny ", "/path ask ", "/path del ",
    "/set debugfile ", "/set debugfile = "]
  {
    #expect(complete(prefix + "prompt s") == [prefix + "prompt space.txt"])
  }
  #expect(complete(". nes") == [". nested\\ folder/"])
  #expect(complete(". nested\\ folder/in") == [". nested\\ folder/input.txt"])
  #expect(complete(". \"nested folder/in") == [". \"nested folder/input.txt\""])
  #expect(complete("/cd nes") == ["/cd nested folder/"])
  #expect(complete("/cd prom").isEmpty)
  #expect(complete("/projects open nes") == ["/projects open nested\\ folder/"])
  #expect(complete("/mcp add --cwd nes") == ["/mcp add --cwd nested\\ folder/"])
  #expect(complete("/mcp add --name test --cwd nes") == ["/mcp add --name test --cwd nested\\ folder/"])
  #expect(complete("/then . prom") == ["/then . prompt\\ space.txt", "/then . prompt.txt"].sorted())
  #expect(complete("/remote serve --path nes") == ["/remote serve --path nested\\ folder/"])
  #expect(complete("/remote serve --path /tmp nes") == ["/remote serve --path /tmp nested\\ folder/"])
  #expect(complete("/remote serve --path nes --port 123").isEmpty)
  #expect(complete(". \(root.path)/caf") == [". \(root.path)/café.txt"])
  let homeDepth = URL(fileURLWithPath: NSHomeDirectory()).pathComponents.filter { $0 != "/" }.count
  let fromHome = "~/" + String(repeating: "../", count: homeDepth) + root.path.dropFirst() + "/"
  #expect(complete(". \(fromHome)caf") == [". \(fromHome)café.txt"])
  #expect(complete(". .h") == [". .hidden"])
  #expect(!complete(". ").contains(". .hidden"))
  for line in ["ordinary prom", "/help prom", "/msg last | prom", ". prompt.txt next", "/image prom", "/copy 3"] {
    #expect(complete(line).isEmpty)
  }
}
