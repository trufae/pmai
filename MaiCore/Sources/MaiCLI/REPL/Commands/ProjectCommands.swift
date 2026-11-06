import Foundation
import MaiCore

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

extension MaiCLI {
  static func handleProjectCommand(
    _ argument: String,
    project: inout AgentProject,
    home: AgentHome,
    store: AgentChatStore,
    terminal: TerminalWriter
  ) async {
    let parts = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = parts.first?.lowercased() ?? "info"
    let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""

    switch action {
    case "info", "show":
      await terminal.line(projectInfo(project, home: home, store: store))
    case "list", "ls", "projects":
      do {
        await terminal.line(
          projectListing(try home.loadProjectIndex(), home: home, currentID: project.id, now: Date()))
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    case "name", "rename":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /project name NAME")
        return
      }
      project.rename(to: rest)
      await saveProject(
        project, home: home, terminal: terminal,
        success: "Project renamed to '\(project.displayName)'.")
    case "tint", "color", "colour":
      let presets = AgentProjectTint.presetNames.joined(separator: ", ")
      guard !rest.isEmpty else {
        await terminal.line(
          "Tint: \(project.tint?.rawValue ?? "none"). Presets: \(presets); or #RRGGBB; none clears it."
        )
        return
      }
      if ["none", "off", "default", "-"].contains(rest.lowercased()) {
        project.tint = nil
        await saveProject(project, home: home, terminal: terminal, success: "Project tint cleared.")
        return
      }
      guard let tint = AgentProjectTint(rawValue: rest) else {
        await terminal.line("Unknown tint '\(rest)'. Use one of \(presets), or #RRGGBB.")
        return
      }
      project.tint = tint
      await saveProject(
        project, home: home, terminal: terminal, success: "Project tint set to \(tint.rawValue).")
    case "del":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /project del INDEX|PATH|NAME")
        return
      }
      do {
        let index = try home.loadProjectIndex()
        guard let target = resolveProject(rest, in: index) else {
          await terminal.line("No project matches '\(rest)'. /project list shows them.")
          return
        }
        guard target.id != project.id else {
          await terminal.line("'\(target.displayName)' is the open project; it stays listed.")
          return
        }
        _ = try home.forgetProject(id: target.id)
        await terminal.line(
          "Forgot '\(target.displayName)'. Its files in \(target.workingDirectory) were left alone."
        )
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    case "help":
      await terminal.line(projectHelp)
    default:
      await terminal.line("Unknown /project action '\(action)'.\n\n\(projectHelp)")
    }
  }

  static func saveProject(
    _ project: AgentProject,
    home: AgentHome,
    terminal: TerminalWriter,
    success: String
  ) async {
    do {
      try home.saveProject(project)
      await terminal.line(success)
    } catch {
      await terminal.line(
        "warning: the project was not saved: \(error.localizedDescription)", to: .standardError)
    }
  }

  static func resolveProject(_ selector: String, in index: AgentProjectIndex)
    -> AgentProject?
  {
    let ordered = index.orderedProjects
    if let position = ListIndex.resolve(selector, count: ordered.count) {
      return ordered[position]
    }
    let path = AgentProject.standardizedPath(selector)
    if let match = index.project(atWorkingDirectory: path) { return match }
    let lowered = selector.lowercased()
    if let match = ordered.first(where: { $0.id.uuidString.lowercased().hasPrefix(lowered) }) {
      return match
    }
    return ordered.first { $0.displayName.lowercased() == lowered }
  }

  static func projectInfo(
    _ project: AgentProject,
    home: AgentHome,
    store: AgentChatStore
  ) -> String {
    let summaries = (try? store.loadSummaries()) ?? []
    let archived = summaries.filter(\.isArchived).count
    let nameNote =
      project.hasCustomName ? "" : " (from the directory; /project name NAME renames it)"
    return [
      "Name:      \(project.displayName)\(nameNote)",
      "Directory: \(project.workingDirectory)",
      "Tint:      \(project.tint?.rawValue ?? "none")",
      "Chats:     \(summaries.count - archived) active, \(archived) archived",
      "Storage:   \(store.directoryURL.path)",
      "Index:     \(home.projectIndexURL.path)",
      "ID:        \(project.id.uuidString)",
      "Created:   \(ChatDatePresentation.timestamp(project.createdAt))",
      "Opened:    \(ChatDatePresentation.timestamp(project.lastOpenedAt))",
    ].joined(separator: "\n")
  }

  static func projectListing(
    _ index: AgentProjectIndex,
    home: AgentHome,
    currentID: UUID?,
    now: Date
  ) -> String {
    let projects = index.orderedProjects
    guard !projects.isEmpty else {
      return "No projects yet. pmai registers the directory it is started in."
    }
    var lines = ["Projects, most recently opened first:"]
    lines.append([
      "   #", padded("Project", width: 24), padded("Disk", width: 8),
      padded("Directory", width: 44), padded("Notes", width: 12), "Opened",
    ].joined(separator: "  "))
    for (offset, project) in projects.enumerated() {
      let marker = project.id == currentID ? "*" : " "
      let number = offset < 9 ? " \(offset + 1)" : "\(offset + 1)"
      var notes: [String] = []
      if let tint = project.tint { notes.append(tint.rawValue) }
      if !project.workingDirectoryExists { notes.append("missing") }
      lines.append(
        [
          "\(marker) \(number)", padded(project.displayName, width: 24),
          padded(projectDiskUsage(at: home.storageDirectory(for: project)), width: 8),
          padded(abbreviatedPath(project.workingDirectory), width: 44),
          padded(notes.joined(separator: ", "), width: 12),
          ChatDatePresentation.compactTimestamp(project.lastOpenedAt, relativeTo: now),
        ].joined(separator: "  "))
    }
    return lines.joined(separator: "\n")
  }

  /// Like du: count allocated blocks, including hidden files and directories,
  /// without following symlinks or counting hard-linked files more than once.
  private static func projectDiskUsage(at directory: URL) -> String {
    let manager = FileManager.default
    guard let attributes = try? manager.attributesOfItem(atPath: directory.path) else { return "-" }
    var bytes: Int64 = 0
    var seen = Set<String>()
    func add(_ url: URL) -> Bool {
      #if os(Windows)
        guard let values = try? url.resourceValues(forKeys: [
          .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        ]), let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize
        else { return false }
        bytes += Int64(size)
      #else
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        if info.st_nlink > 1,
          !seen.insert("\(info.st_dev):\(info.st_ino)").inserted { return true }
        bytes += Int64(info.st_blocks) * 512
      #endif
      return true
    }
    guard add(directory) else { return "-" }
    if attributes[.type] as? FileAttributeType == .typeDirectory {
      var failed = false
      guard let entries = manager.enumerator(
        at: directory, includingPropertiesForKeys: nil,
        errorHandler: { _, _ in failed = true; return false }) else { return "-" }
      for case let url as URL in entries {
        guard add(url) else { return "-" }
      }
      guard !failed else { return "-" }
    }
    let units = ["B", "K", "M", "G", "T", "P", "E"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024 && unit < units.count - 1 {
      value /= 1024
      unit += 1
    }
    return unit == 0 ? "\(bytes)B" : String(format: "%.1f%@", value, units[unit])
  }

  /// Shortens a path the way shells print it: `~` for home, and the head
  /// elided when it is still too long, keeping the tail people recognize.
  static func abbreviatedPath(_ path: String, width: Int = 44) -> String {
    var shown = path
    let home = AgentHome.userHomeDirectory().path
    if shown == home {
      shown = "~"
    } else if shown.hasPrefix(home + "/") {
      shown = "~" + shown.dropFirst(home.count)
    }
    guard shown.count > width else { return shown }
    return "…" + shown.suffix(width - 1)
  }
}
