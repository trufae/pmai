import Crypto
import Foundation
import MaiCore
import MaiDocuments

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif
#if os(Windows)
  import WinSDK
#endif

/// Release downloads, verification, and installation stay in the CLI; no remote
/// installer or external download, checksum, or archive tools are needed.
enum CLIUpdater {
  // Keep the session alive until process exit: FoundationNetworking's libcurl
  // cleanup can retain _MultiHandle from its own deinit on Linux/musl.
  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 300
    return URLSession(configuration: configuration)
  }()

  private enum Failure: LocalizedError {
    case message(String)
    case http(Int, URL)

    var errorDescription: String? {
      switch self {
      case .message(let message): message
      case .http(let status, let url): "HTTP \(status) downloading \(url.lastPathComponent)"
      }
    }
  }

  static func run(currentVersion: String, executable: String, environment: [String: String]) async throws {
    let fm = FileManager.default
    let platform = try releasePlatform(environment: environment)
    #if os(Windows)
    let path = try windowsExecutablePath()
    let binaryName = "pmai.exe"
    #else
    let binaryName = "pmai"
    guard let path = try? LocalExecutable.resolve(executable, environment: environment) else {
      throw CocoaError(.fileNoSuchFile)
    }
    #endif
    let directory = setting("PMAI_INSTALL_DIR", in: environment).map { URL(fileURLWithPath: $0) }
      ?? URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent()
    #if os(Windows)
    cleanWindowsBackups(in: directory)
    #endif
    let target = directory.appendingPathComponent(binaryName)
    let installedVersion = try? runBinary(target, argument: "--version", environment: environment)
    let oldVersion = normalizedVersion(installedVersion ?? currentVersion)
    let releases = try releaseURL(
      setting("PMAI_RELEASES_URL", in: environment) ?? "https://github.com/trufae/pmai/releases")
    var tag = setting("PMAI_VERSION", in: environment) ?? "latest"
    if tag == "latest" {
      var request = URLRequest(url: releases.appendingPathComponent("latest"))
      request.httpMethod = "HEAD"
      let response: HTTPURLResponse
      do {
        (_, response) = try await fetch(request, session: session)
      } catch {
        throw Failure.message("could not check the latest release: \(error.localizedDescription)")
      }
      guard let url = response.url,
        url.scheme == releases.scheme, url.host == releases.host, url.port == releases.port,
        url.deletingLastPathComponent().path == releases.appendingPathComponent("tag").path
      else { throw Failure.message("could not determine the latest release version") }
      tag = url.lastPathComponent
    }
    guard !tag.isEmpty, tag != ".", tag != "..",
      tag.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
        || (48...57).contains($0) || [45, 46, 95].contains($0) })
    else { throw Failure.message("PMAI_VERSION contains unsupported characters") }
    let newVersion = normalizedVersion(tag)
    if installedVersion != nil && oldVersion == newVersion {
      print("pmai: \(oldVersion) is up to date (No updates available)")
      return
    }
    print("pmai: updating \(oldVersion) → \(newVersion)")
    let base = try setting("PMAI_RELEASE_BASE", in: environment).map(releaseURL)
      ?? releases.appendingPathComponent("download").appendingPathComponent(tag)
    var asset = "pmai-\(platform).zip"
    print("pmai: downloading \(asset)")
    let archive: Data
    do {
      archive = try await download(base.appendingPathComponent(asset), session: session)
    } catch Failure.http(404, _) where platform.hasPrefix("macos-") {
      asset = "pmai-macos-universal.zip"
      print("pmai: trying universal macOS release")
      archive = try await download(base.appendingPathComponent(asset), session: session)
    }
    let checksums = try await download(base.appendingPathComponent("SHA256SUMS"), session: session)
    let expected = String(decoding: checksums, as: UTF8.self).split(whereSeparator: \.isNewline)
      .compactMap { line -> String? in
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, fields[1] == asset || fields[1] == "*" + asset else { return nil }
        return String(fields[0]).lowercased()
      }.first
    guard let expected else { throw Failure.message("no checksum was published for \(asset)") }
    let actual = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
    guard actual == expected else { throw Failure.message("checksum verification failed for \(asset)") }

    let entries = try ZipArchiveReader.entries(in: archive)
    func entry(_ name: String, required: Bool = true) throws -> Data? {
      let matches = entries.filter { $0.path.split(separator: "/").last == Substring(name) }
      guard matches.count <= 1 else { throw Failure.message("the release contains multiple \(name) files") }
      if required && matches.isEmpty { throw Failure.message("the release archive does not contain \(name)") }
      return matches.first?.data
    }
    // Only these known files are written; archive paths never become destinations.
    var files: [(name: String, data: Data, mode: Int)] = []
    #if os(Windows)
    files = try windowsReleaseFiles(entries)
    #else
    if platform.hasPrefix("android-") {
      files.append(("libc++_shared.so", try entry("libc++_shared.so")!, 0o644))
      files.append(("pmai-android", try entry("pmai")!, 0o755))
      let wrapper = """
        #!/bin/sh
        pmai_bindir=$(CDPATH= cd "$(dirname "$0")" && pwd)
        LD_LIBRARY_PATH="$pmai_bindir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        export LD_LIBRARY_PATH
        exec "$pmai_bindir/pmai-android" "$@"

        """
      files.append(("pmai", Data(wrapper.utf8), 0o755))
    } else {
      if let shader = try entry("mlx.metallib", required: false) {
        files.append(("mlx.metallib", shader, 0o644))
      }
      files.append(("pmai", try entry("pmai")!, 0o755))
    }
    #endif
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    // Stage on the destination filesystem so rename replaces a running binary
    // atomically, including on Linux where writing to its inode is forbidden.
    let staging = directory.appendingPathComponent(".pmai-update-\(UUID().uuidString)")
    #if os(Windows)
    try fm.createDirectory(at: staging, withIntermediateDirectories: false)
    #else
    try fm.createDirectory(at: staging, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    #endif
    defer { try? fm.removeItem(at: staging) }
    for file in files {
      let url = staging.appendingPathComponent(file.name)
      try file.data.write(to: url)
      #if !os(Windows)
      try fm.setAttributes([.posixPermissions: file.mode], ofItemAtPath: url.path)
      #endif
    }
    let stagedBinary = staging.appendingPathComponent(binaryName)
    let verifiedVersion = try runBinary(stagedBinary, argument: "--version", environment: environment)
    guard normalizedVersion(verifiedVersion) == newVersion else {
      throw Failure.message("release version mismatch: expected \(newVersion), got \(verifiedVersion)")
    }
    _ = try runBinary(stagedBinary, argument: "--help", environment: environment)
    #if os(Windows)
    try installWindowsFiles(files.map(\.name), from: staging, into: directory)
    #else
    for file in files {
      let source = staging.appendingPathComponent(file.name).path
      let destination = directory.appendingPathComponent(file.name).path
      guard rename(source, destination) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
    }
    #endif
    print("pmai: updated \(oldVersion) → \(newVersion) at \(target.path)")
  }

  #if os(Windows)
  private static func windowsExecutablePath() throws -> String {
    var buffer = [WCHAR](repeating: 0, count: 32768)
    let count = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
    guard count > 0, Int(count) < buffer.count else {
      throw Failure.message("Cannot determine the running executable path (Windows error \(GetLastError())).")
    }
    return String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
  }

  private static func windowsReleaseFiles(_ entries: [ZipArchiveEntry]) throws
    -> [(name: String, data: Data, mode: Int)]
  {
    let binaries = entries.filter {
      let name = $0.path.split(separator: "/").last?.lowercased() ?? ""
      return name == "pmai.exe" || name.hasSuffix(".dll")
    }
    guard let executable = binaries.first(where: {
      $0.path.split(separator: "/").last?.lowercased() == "pmai.exe"
    }) else { throw Failure.message("the release archive does not contain pmai.exe") }
    let root = executable.path.split(separator: "/").dropLast()
    var names = Set<String>()
    return try binaries.map { entry in
      let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
      let name = String(parts.last ?? "")
      // Extract only sibling binaries. Never interpret ZIP paths as destinations,
      // and reject Windows path aliases, device names and alternate data streams.
      let stem = name.split(separator: ".").first?.uppercased() ?? ""
      let reserved = ["CON", "PRN", "AUX", "NUL"]
        + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
      guard parts.dropLast().elementsEqual(root),
        parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".."
          && !$0.contains("\\") && !$0.contains(":") }),
        name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
          || (48...57).contains($0) || [45, 46, 95, 43].contains($0) }),
        !reserved.contains(stem), names.insert(name.lowercased()).inserted
      else { throw Failure.message("invalid or duplicate Windows release file: \(entry.path)") }
      return (name.lowercased() == "pmai.exe" ? "pmai.exe" : name, entry.data, 0o755)
    }
  }

  private static func cleanWindowsBackups(in directory: URL) {
    let fm = FileManager.default
    for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
      let prefix = ".pmai-backup-"
      guard url.lastPathComponent.hasPrefix(prefix),
        UUID(uuidString: String(url.lastPathComponent.dropFirst(prefix.count))) != nil,
        fm.fileExists(atPath: url.appendingPathComponent(".installed").path)
      else { continue }
      // Loaded images cannot be deleted until the previous pmai exits.
      removeWindowsBackup(at: url)
    }
  }

  private static func removeWindowsBackup(at directory: URL) {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
    var removed = true
    for file in files where file.lastPathComponent != ".installed" {
      do { try fm.removeItem(at: file) } catch { removed = false }
    }
    // Keep the completion marker while any mapped image remains locked.
    if removed { try? fm.removeItem(at: directory) }
  }

  private static func installWindowsFiles(_ names: [String], from staging: URL, into directory: URL) throws {
    let fm = FileManager.default
    let backup = directory.appendingPathComponent(".pmai-backup-\(UUID().uuidString)")
    try fm.createDirectory(at: backup, withIntermediateDirectories: false)
    var saved: [String] = []
    var installed: [String] = []
    do {
      // Windows permits renaming a mapped executable or DLL, but not overwriting
      // or deleting it. Move the old images aside before installing replacements.
      for name in names {
        let destination = directory.appendingPathComponent(name)
        if fm.fileExists(atPath: destination.path) {
          let attributes = try fm.attributesOfItem(atPath: destination.path)
          guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw Failure.message("Cannot replace a non-file at \(destination.path)")
          }
          try windowsMove(destination, to: backup.appendingPathComponent(name))
          saved.append(name)
        }
      }
      for name in names {
        try windowsMove(staging.appendingPathComponent(name), to: directory.appendingPathComponent(name))
        installed.append(name)
      }
    } catch {
      let failure = error
      do {
        for name in installed.reversed() {
          try windowsMove(directory.appendingPathComponent(name), to: staging.appendingPathComponent(name))
        }
        for name in saved.reversed() {
          try windowsMove(backup.appendingPathComponent(name), to: directory.appendingPathComponent(name))
        }
      } catch {
        throw Failure.message("Update failed: \(failure.localizedDescription). Recovery failed: \(error.localizedDescription). Original files remain in \(backup.path).")
      }
      try? fm.removeItem(at: backup)
      throw failure
    }
    // Only completed installations may be cleaned on a future invocation;
    // preserve recovery files if rollback itself ever fails.
    try? Data().write(to: backup.appendingPathComponent(".installed"))
    removeWindowsBackup(at: backup)
  }

  private static func windowsMove(_ source: URL, to destination: URL) throws {
    let moved = source.path.withCString(encodedAs: UTF16.self) { sourcePath in
      destination.path.withCString(encodedAs: UTF16.self) { destinationPath in
        MoveFileExW(sourcePath, destinationPath, 0)
      }
    }
    guard moved else {
      throw Failure.message("Cannot move \(source.path) to \(destination.path) (Windows error \(GetLastError())).")
    }
  }
  #endif

  private static func setting(_ name: String, in environment: [String: String]) -> String? {
    environment[name].flatMap { $0.isEmpty ? nil : $0 }
  }

  private static func normalizedVersion(_ version: String) -> String {
    version.hasPrefix("v") ? String(version.dropFirst()) : version
  }

  private static func releaseURL(_ value: String) throws -> URL {
    guard let url = URL(string: value),
      url.isFileURL || (["http", "https"].contains(url.scheme ?? "") && url.host != nil)
    else { throw Failure.message("invalid release URL: \(value)") }
    return url
  }

  private static func download(_ url: URL, session: URLSession) async throws -> Data {
    if url.isFileURL { return try Data(contentsOf: url) }
    return try await fetch(URLRequest(url: url), session: session).0
  }

  private static func fetch(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
    for attempt in 0...2 {
      do {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(response.statusCode) else {
          throw Failure.http(response.statusCode, request.url!)
        }
        return (data, response)
      } catch {
        let retry: Bool
        if case Failure.http(let status, _) = error {
          retry = status == 408 || status == 429 || (500...599).contains(status)
        } else if let error = error as? URLError {
          retry = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet]
            .contains(error.code)
        } else {
          retry = false
        }
        guard retry && attempt < 2 else { throw error }
        try await Task.sleep(for: .seconds(attempt + 1))
      }
    }
    throw URLError(.unknown)
  }

  private static func runBinary(_ url: URL, argument: String, environment: [String: String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = url
    process.arguments = [argument]
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw Failure.message("\(url.lastPathComponent) failed its startup check (\(argument))")
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func releasePlatform(environment: [String: String]) throws -> String {
    #if arch(arm64)
      let architecture = "arm64"
    #elseif arch(x86_64)
      let architecture = "x64"
    #else
      throw Failure.message("unsupported CPU architecture")
    #endif
    #if os(Android)
      guard architecture == "arm64" else { throw Failure.message("Android releases currently support arm64 devices") }
      return "android-\(architecture)"
    #elseif os(macOS)
      return "macos-\(architecture)"
    #elseif os(Windows)
      return "windows-\(architecture)"
    #elseif os(Linux)
      #if canImport(Musl)
        let defaultLibc = "musl"
      #else
        let defaultLibc = "glibc"
      #endif
      switch setting("PMAI_LIBC", in: environment) ?? defaultLibc {
      case "musl": return "linux-\(architecture)-musl"
      case "glibc", "gnu": return "linux-\(architecture)"
      default: throw Failure.message("PMAI_LIBC must be musl or glibc")
      }
    #else
      throw Failure.message("Automatic updates support macOS, Linux, and Android.")
    #endif
  }
}
