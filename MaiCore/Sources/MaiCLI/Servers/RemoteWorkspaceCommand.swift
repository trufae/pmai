import Foundation
import MaiACP
import MaiStandardTools

enum RemoteWorkspaceCommand {
  static func run(_ action: String, arguments: [String], connection: WorkspaceConnection,
    directory: URL, terminal: TerminalWriter
  ) async throws {
    do {
      switch action {
      case "ls":
        guard arguments.count <= 1 else { throw WorkspaceFileError("Usage: /remote ls HOST [PATH]") }
        var offset = 0
        while true {
          let response = try await connection.request(.init(.list, path: arguments.first ?? ".",
            offset: offset, limit: 500, showHidden: true))
          guard let listing = response.listing else { throw WorkspaceFileError("Invalid directory listing.") }
          for entry in listing.entries { await terminal.line(entry.name + (entry.isDirectory ? "/" : "")) }
          guard let next = listing.nextOffset else { break }
          guard next > offset else { throw WorkspaceFileError("Invalid directory page.") }
          offset = next
        }
      case "get":
        guard (1...2).contains(arguments.count) else { throw WorkspaceFileError("Usage: /remote get HOST REMOTE [LOCAL]") }
        let name = URL(fileURLWithPath: arguments[0]).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw WorkspaceFileError("Choose a file to download.") }
        var destination = local(arguments.count == 2 ? arguments[1] : name, directory: directory)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
          destination.appendPathComponent(name)
        }
        let data = try await connection.read(arguments[0], maximumSize: 32_000_000)
        try Task.checkCancellation()
        try data.write(to: destination, options: .atomic)
        await terminal.line("Downloaded \(data.count) bytes to \(destination.path)")
      case "put":
        guard (1...2).contains(arguments.count) else { throw WorkspaceFileError("Usage: /remote put HOST LOCAL [REMOTE]") }
        let source = local(arguments[0], directory: directory)
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 32_000_000 else { throw WorkspaceFileError("Files are limited to 32 MB.") }
        var destination = arguments.count == 2 ? arguments[1] : source.lastPathComponent
        if destination.hasSuffix("/") { destination += source.lastPathComponent }
        let data = try Data(contentsOf: source)
        guard data.count <= 32_000_000 else { throw WorkspaceFileError("Files are limited to 32 MB.") }
        try await connection.write(destination, data: data)
        await terminal.line("Uploaded \(data.count) bytes to \(destination)")
      case "run":
        guard arguments.count == 1, !arguments[0].isEmpty else { throw WorkspaceFileError("Usage: /remote run HOST COMMAND") }
        let result = try await connection.run(arguments[0])
        await terminal.line(result.text, to: result.isError ? .standardError : .standardOutput)
      default: throw WorkspaceFileError("Unknown remote workspace command.")
      }
      await connection.close()
    } catch {
      await connection.close()
      throw error
    }
  }

  private static func local(_ path: String, directory: URL) -> URL {
    URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, relativeTo: directory).standardized
  }
}
