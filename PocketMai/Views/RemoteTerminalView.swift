import MaiACP
import MaiCore
import SwiftUI

struct RemoteTerminalLocation: Identifiable {
  let host: RemoteAgentBookmark
  let cwd: String

  var id: String { [host.id.uuidString, host.revision?.uuidString ?? "", cwd].joined(separator: ":") }
  var title: String { "\(host.name) · \(URL(fileURLWithPath: cwd).lastPathComponent)" }
}

private struct RemoteTerminalEntry: Identifiable {
  let id = UUID()
  let command: String
  var output: String?
  var isError = false
}

@MainActor
private final class RemoteTerminalSession: ObservableObject {
  @Published var entries: [RemoteTerminalEntry] = []
  @Published var isRunning = false

  private let location: RemoteTerminalLocation
  private var client: ACPClient?
  private var workspace: OpenCodeWorkspace?
  private var operation: Task<Void, Never>?

  init(location: RemoteTerminalLocation) {
    self.location = location
  }

  func run(_ command: String, offline: Bool) {
    let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty, !isRunning else { return }
    let entry = RemoteTerminalEntry(command: command)
    entries.append(entry)
    isRunning = true

    operation = Task { [weak self] in
      guard let self else { return }
      defer { isRunning = false; operation = nil }
      do {
        guard !offline else { throw InternetAccessError.offline }
        let result: ToolResult
        if location.host.backend == .openCode {
          if workspace == nil {
            workspace = try OpenCodeWorkspace(connection: .init(
              name: location.host.name, url: location.host.url,
              token: RemoteAgentStore.shared.token(for: location.host.id), cwd: location.cwd))
          }
          result = try await workspace!.run(command) { [weak self] output in
            await self?.finish(entry.id, output: output, isError: false)
          }
        } else {
          result = try await connectedClient().runTool(
            cwd: location.cwd,
            call: .init(id: entry.id.uuidString, name: "run_shell", arguments: .object([
              "script": .string(command),
            ])))
        }
        finish(entry.id, output: result.text, isError: result.isError)
      } catch {
        finish(entry.id, output: "Error: \(error.localizedDescription)", isError: true)
      }
    }
  }

  func clear() { entries.removeAll() }

  func close() {
    let operation = operation
    operation?.cancel()
    let client = client
    let workspace = workspace
    self.client = nil
    self.workspace = nil
    Task {
      await client?.disconnect()
      await operation?.value
      await workspace?.close()
    }
  }

  private func connectedClient() throws -> ACPClient {
    if let client { return client }
    guard location.host.requiresApproval != true else {
      throw JSONRPCError.invalidParams("Approve this device on the remote host first.")
    }
    let client = ACPClient(
      configuration: .init(
        command: location.host.name, permission: .reject, remoteWorkingDirectory: location.cwd,
        readClientFiles: false, webSocketURL: location.host.url,
        bearerToken: try RemoteAgentStore.shared.token(for: location.host.id)))
    self.client = client
    return client
  }

  private func finish(_ id: UUID, output: String, isError: Bool) {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    entries[index].output = output
    entries[index].isError = isError
  }
}

struct RemoteTerminalView: View {
  @EnvironmentObject private var appStore: AppStore
  @Environment(\.dismiss) private var dismiss
  let location: RemoteTerminalLocation
  @StateObject private var terminal: RemoteTerminalSession
  @State private var command = ""
  @FocusState private var commandFocused: Bool

  init(location: RemoteTerminalLocation) {
    self.location = location
    _terminal = StateObject(wrappedValue: RemoteTerminalSession(location: location))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
              Text("$ cd \(location.cwd)")
                .foregroundStyle(.green)
              Text("Each command starts in this project directory.")
                .font(.caption).foregroundStyle(.secondary)
              ForEach(terminal.entries) { entry in
                VStack(alignment: .leading, spacing: 8) {
                  Text("$ \(entry.command)").foregroundStyle(.green)
                  if let output = entry.output {
                    Text(output.isEmpty ? "(no output)" : output)
                      .foregroundStyle(entry.isError ? .red : .primary)
                      .textSelection(.enabled)
                  } else {
                    ProgressView("Running…").controlSize(.small)
                  }
                }
                .id(entry.id)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.system(.body, design: .monospaced))
            .padding()
          }
          .background(Color(uiColor: .secondarySystemBackground))
          .onChange(of: terminal.entries.last?.id) { _, id in
            if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
          }
        }

        Divider()
        HStack(alignment: .bottom, spacing: 10) {
          TextField("Command", text: $command, axis: .vertical)
            .font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($commandFocused)
            .onSubmit(submit)
          Button("Run", action: submit)
            .buttonStyle(.borderedProminent)
            .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || terminal.isRunning)
        }
        .padding()
      }
      .navigationTitle("Terminal")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Clear", systemImage: "trash", action: terminal.clear)
            .disabled(terminal.entries.isEmpty || terminal.isRunning)
        }
      }
      .onAppear { commandFocused = true }
      .onDisappear { terminal.close() }
    }
  }

  private func submit() {
    let next = command
    command = ""
    terminal.run(next, offline: appStore.settings.isOffline)
  }
}
