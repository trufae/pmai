import Crypto
import Foundation
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

/// Release downloads, verification, and installation stay in the CLI; no remote
/// installer or external download, checksum, or archive tools are needed.
enum CLIUpdater {
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
    #if os(Windows)
      throw Failure.message("Automatic updates support macOS, Linux, and Android.")
    #else
      let fm = FileManager.default
      let platform = try releasePlatform(environment: environment)
      let candidates = executable.contains("/") ? [executable]
        : (environment["PATH"] ?? "").components(separatedBy: ":").map {
          URL(fileURLWithPath: $0.isEmpty ? "." : $0).appendingPathComponent(executable).path
        }
      guard let path = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
        throw CocoaError(.fileNoSuchFile)
      }
      let directory = setting("PMAI_INSTALL_DIR", in: environment).map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent()
      let target = directory.appendingPathComponent("pmai")
      let installedVersion = try? runBinary(target, argument: "--version", environment: environment)
      let oldVersion = normalizedVersion(installedVersion ?? currentVersion)
      let releases = try releaseURL(
        setting("PMAI_RELEASES_URL", in: environment) ?? "https://github.com/trufae/pmai/releases")
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 30
      configuration.timeoutIntervalForResource = 300
      let session = URLSession(configuration: configuration)
      defer { session.invalidateAndCancel() }

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
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      // Stage on the destination filesystem so rename replaces a running binary
      // atomically, including on Linux where writing to its inode is forbidden.
      let staging = directory.appendingPathComponent(".pmai-update-\(UUID().uuidString)")
      try fm.createDirectory(at: staging, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      defer { try? fm.removeItem(at: staging) }
      for file in files {
        let url = staging.appendingPathComponent(file.name)
        try file.data.write(to: url)
        try fm.setAttributes([.posixPermissions: file.mode], ofItemAtPath: url.path)
      }
      let stagedBinary = staging.appendingPathComponent("pmai")
      let verifiedVersion = try runBinary(stagedBinary, argument: "--version", environment: environment)
      guard normalizedVersion(verifiedVersion) == newVersion else {
        throw Failure.message("release version mismatch: expected \(newVersion), got \(verifiedVersion)")
      }
      _ = try runBinary(stagedBinary, argument: "--help", environment: environment)
      for file in files {
        let source = staging.appendingPathComponent(file.name).path
        let destination = directory.appendingPathComponent(file.name).path
        guard rename(source, destination) == 0 else {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
      }
      print("pmai: updated \(oldVersion) → \(newVersion) at \(target.path)")
    #endif
  }

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
