import Foundation
import MaiACP
import MaiCore
import Observation

// One shell owns its connection independently of navigation and chat requests.
@MainActor @Observable final class MobileShell {
  let id: String
  private(set) var status = "Connecting…"
  private(set) var error = ""
  private(set) var interactive = false
  private var remoteID: String
  private var remoteOffset: Int
  private var sequence = 0
  private var pending = Data()
  private var consumed: CheckedContinuation<Void, Never>?
  private var reader: Task<Void, Never>?
  private var writer: Task<Void, Never>?
  private var workspace: WorkspaceConnection?
  private var shell: RemoteTerminalSession?
  private let profile: RemoteHostConnection?
  private let cwd: String
  private let preparation: Task<Void, Error>?
  private var columns = 80
  private var rows = 24
  private var closed = false
  let command = MobileTerminal()
  #if os(macOS) || os(Linux) || os(Android)
  private var local: RemotePTY?
  #endif

  init(id: String, cwd: String, profile: RemoteHostConnection?, preparation: Task<Void, Error>?,
    remoteID: String = "", offset: Int = 0) {
    self.id = id
    self.cwd = cwd
    self.profile = profile
    self.preparation = preparation
    self.remoteID = remoteID
    remoteOffset = max(0, offset)
  }

  func connect() {
    guard reader == nil, workspace == nil, shell == nil, !closed else { return }
    reader = Task { [self] in
      defer { reader = nil }
      repeat {
        do {
          error = ""
          status = "Connecting…"
          if let profile {
            if profile.backend != .openCode { try await preparation?.value }
            try Task.checkCancellation()
            let connection = try profile.workspace(cwd: cwd, resumeID: id)
            workspace = connection
            interactive = try await connection.supportsInteractiveTerminal()
            if !interactive { status = "Command mode"; return }
            if remoteID.isEmpty { remoteID = try await connection.terminalIDs().first ?? "" }
            var attached = remoteID.isEmpty ? nil : try await connection.attachTerminal(id: remoteID)
            if attached == nil {
              attached = try await connection.openTerminal(columns: columns, rows: rows)
              remoteOffset = 0
              remoteID = attached!.id
              await deliver(Data("\u{1b}c".utf8))
            }
            let session = attached!
            shell = session
            try await session.resize(columns: columns == 1000 ? 999 : columns + 1, rows: rows)
            try await session.resize(columns: columns, rows: rows)
            status = "Connected"
            while !Task.isCancelled {
              let chunk = try await session.read(after: remoteOffset)
              try Task.checkCancellation()
              remoteOffset = chunk.offset ?? remoteOffset + chunk.data.count
              if !chunk.data.isEmpty { await deliver(chunk.data) }
              if let exit = chunk.exitCode {
                status = "Exited (\(exit))"
                await session.close()
                shell = nil
                remoteID = ""
                await connection.close()
                workspace = nil
                return
              }
            }
          } else {
            #if os(macOS) || os(Linux) || os(Android)
            try Task.checkCancellation()
            let terminal = try RemotePTY(cwd: URL(fileURLWithPath: cwd), columns: columns, rows: rows)
            local = terminal
            interactive = true
            status = "Android shell · app permissions"
            while !Task.isCancelled {
              let chunk = try await terminal.readOutput()
              try Task.checkCancellation()
              if !chunk.data.isEmpty { await deliver(chunk.data) }
              if let exit = chunk.exitCode { status = "Exited (\(exit))"; local = nil; return }
            }
            #else
            throw WorkspaceFileError("Local interactive shells are unavailable on this platform.")
            #endif
          }
        } catch {
          if !Task.isCancelled && !closed { self.error = error.localizedDescription; status = "Disconnected" }
        }
        shell = nil
        await workspace?.close()
        workspace = nil
        guard profile != nil, !Task.isCancelled, !closed else { return }
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
      } while !Task.isCancelled && !closed
    }
  }

  private func deliver(_ data: Data) async {
    guard !closed, !Task.isCancelled else { return }
    // Acknowledgement applies backpressure across the JNI snapshot boundary.
    // Bytes are never decoded as text, so split UTF-8 and ANSI sequences survive.
    await withCheckedContinuation { continuation in
      consumed = continuation
      pending = data
      sequence += 1
    }
  }

  func acknowledge(_ value: Int) {
    guard value == sequence else { return }
    pending = Data()
    let continuation = consumed
    consumed = nil
    continuation?.resume()
  }

  func send(_ data: Data) {
    guard !closed, !data.isEmpty, data.count <= 16 * 1024 else { return }
    enqueue { [self] in
      if let shell { try await shell.send(data) }
      #if os(macOS) || os(Linux) || os(Android)
      if let local { try local.send(data) }
      #endif
    }
  }

  func resize(columns: Int, rows: Int) {
    self.columns = max(2, min(1000, columns))
    self.rows = max(2, min(1000, rows))
    enqueue { [self] in
      if let shell { try await shell.resize(columns: self.columns, rows: self.rows) }
      #if os(macOS) || os(Linux) || os(Android)
      if let local { try local.resize(columns: self.columns, rows: self.rows) }
      #endif
    }
  }

  private func enqueue(_ action: @escaping @MainActor () async throws -> Void) {
    let previous = writer
    writer = Task { [self] in
      await previous?.value
      guard !closed, !Task.isCancelled else { return }
      do { try await action() } catch { self.error = error.localizedDescription }
    }
  }

  func run(id: String, script: String) {
    guard !interactive, let workspace else { return }
    command.run(id: id) { [self] in
      try await workspace.run(script) { [weak self] output in
        await self?.command.update(id: id, output: output)
      }
    }
  }

  func close() async {
    guard !closed else { return }
    closed = true
    status = "Closing…"
    command.close()
    reader?.cancel()
    writer?.cancel()
    acknowledge(sequence)
    await reader?.value
    await writer?.value
    #if os(macOS) || os(Linux) || os(Android)
    await local?.stop()
    local = nil
    #endif
    // Resume first when offline so closing cannot silently orphan a host shell.
    do {
      if let profile, profile.backend != .openCode {
        let connection = try profile.workspace(cwd: cwd, resumeID: id)
        defer { Task { await connection.close() } }
        if case .remote(let client, _) = connection, try await client.terminalSupported() {
          _ = try await client.terminal(["action": .string("close_all")])
        }
      } else { await shell?.close() }
      await workspace?.close()
      workspace = nil
      shell = nil
      status = "Closed"
    } catch {
      self.error = "Could not close the host session: \(error.localizedDescription)"
      status = "Disconnected"
      closed = false
    }
  }

  var snapshot: [String: Any] {
    ["id": id, "status": status, "error": error, "interactive": interactive,
      "remoteID": remoteID, "offset": remoteOffset, "sequence": sequence,
      "data": pending.base64EncodedString(), "command": command.snapshot]
  }
}
