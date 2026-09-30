import AVFoundation
import MaiACP
import SwiftUI
import VisionKit

struct RemoteAgentsView: View {
  @State private var store = RemoteAgentStore.shared
  @State private var adding = false

  var body: some View {
    List {
      Section {
        ForEach(store.connections) { connection in
          NavigationLink {
            RemoteAgentChatView(bookmark: connection)
          } label: {
            VStack(alignment: .leading) {
              Text(connection.name)
              Text(connection.url.absoluteString).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        .onDelete { indices in
          for id in indices.map({ store.connections[$0].id }) { store.remove(id) }
        }
        Button("Add Remote Agent", systemImage: "plus") { adding = true }
      } footer: {
        Text(
          "Connect to an ACP WebSocket gateway. The remote agent runs its own tools on its host. Chats and gateway tokens stay on this device."
        )
      }
      if let error = store.error { Text(error).foregroundStyle(.red) }
    }
    .navigationTitle("Remote Agents")
    .sheet(isPresented: $adding) { RemoteAgentConnectionView() }
  }
}

private struct RemoteAgentConnectionView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var name = "pmai"
  @State private var address = ""
  @State private var token = ""
  @State private var cwd = ""
  @State private var uri = ""
  @State private var scanning = false
  @State private var error: String?

  var body: some View {
    NavigationStack {
      Form {
        Section("Import connection") {
          TextField("Paste pmai-acp:// connection URI", text: $uri, axis: .vertical)
            .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
          Button("Read Connection URI") { apply(uri) }
            .disabled(uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if DataScannerViewController.isSupported {
            Button("Scan Gateway QR", systemImage: "qrcode.viewfinder") {
              Task { await scan() }
            }
          }
        }
        Section("Gateway") {
          TextField("Name", text: $name)
          TextField("wss://host/acp", text: $address).keyboardType(.URL)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          SecureField("Gateway token", text: $token)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          TextField("Absolute workspace on remote host", text: $cwd)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        Section {
          if address.lowercased().hasPrefix("ws://") {
            Label(
              "This connection is unencrypted. Use it only on a trusted private network, or switch to WSS.",
              systemImage: "lock.open")
          }
          Text(
            "The QR contains a reusable gateway credential. Review the host and workspace before saving. A Tailcat worker invite must first be paired on the gateway host with pmai tailcat pair."
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
        if let error { Text(error).foregroundStyle(.red) }
      }
      .navigationTitle("Add Remote Agent")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
      }
      .sheet(isPresented: $scanning) {
        NavigationStack {
          GatewayQRScanner(
            onCode: { text in
              scanning = false
              apply(text)
            },
            onFailure: { message in
              scanning = false
              error = message
            }
          )
          .navigationTitle("Scan Gateway QR")
          .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } }
          }
        }
      }
    }
  }

  private func scan() async {
    let allowed = await AVCaptureDevice.requestAccess(for: .video)
    guard allowed else {
      error = "Allow camera access for PocketMai in iOS Settings to scan a gateway QR."
      return
    }
    guard DataScannerViewController.isAvailable else {
      error = "Camera scanning is currently unavailable. You can paste the connection URI instead."
      return
    }
    error = nil
    scanning = true
  }

  private func apply(_ text: String) {
    do {
      let profile = try ACPRemoteConnection.parse(
        text.trimmingCharacters(in: .whitespacesAndNewlines))
      name = profile.name
      address = profile.url.absoluteString
      token = profile.token
      cwd = profile.cwd
      uri = ""
      error = nil
    } catch { self.error = error.localizedDescription }
  }

  private func save() {
    do {
      guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        error = "Enter the gateway's WebSocket URL."
        return
      }
      let profile = try ACPRemoteConnection(
        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
        url: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines), cwd: cwd)
      try RemoteAgentStore.shared.add(profile)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}

private struct RemoteAgentChatView: View {
  @Environment(\.scenePhase) private var scenePhase
  @EnvironmentObject private var appStore: AppStore
  @State private var chat: RemoteAgentChat
  @State private var draft = ""
  @State private var newChatConfirmation = false

  init(bookmark: RemoteAgentBookmark) {
    _chat = State(initialValue: RemoteAgentChat(bookmark: bookmark))
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        if chat.busy { ProgressView().controlSize(.small) }
        Text(chat.status).font(.caption).foregroundStyle(.secondary)
        Spacer()
        if !chat.connected && !chat.busy {
          Button("Connect") { chat.connect() }.disabled(appStore.settings.airplaneModeEnabled)
        }
      }.padding(.horizontal).padding(.vertical, 8)
      if let error = chat.error {
        Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal)
      }
      if appStore.settings.airplaneModeEnabled {
        Text("Turn off Airplane Mode in Settings to connect to a remote agent.")
          .font(.callout).foregroundStyle(.secondary).padding(.horizontal)
      }
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(chat.messages) { message in
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text(message.role.capitalized).font(.caption.bold())
                  if let status = message.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                  }
                }
                if message.role == "thought" || message.role == "tool" || message.role == "plan" {
                  DisclosureGroup(message.role == "tool" ? "Tool details" : "Details") {
                    Text(message.text).textSelection(.enabled).font(.callout)
                  }
                } else {
                  Text(message.text).textSelection(.enabled)
                }
              }
              .padding(12)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                message.role == "user"
                  ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 12))
            }
            Color.clear.frame(height: 1).id("end")
          }.padding()
        }
        .onChange(of: chat.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
      }
      Divider()
      HStack(alignment: .bottom) {
        TextField("Message remote agent", text: $draft, axis: .vertical)
          .lineLimit(1...6).textFieldStyle(.roundedBorder)
        if chat.busy {
          Button("Stop", systemImage: "stop.circle") { chat.disconnect() }
            .labelStyle(.iconOnly).accessibilityLabel("Stop remote prompt")
        } else {
          Button("Send", systemImage: "arrow.up.circle.fill") {
            chat.send(draft)
            draft = ""
          }
          .labelStyle(.iconOnly).font(.title2)
          .disabled(
            !chat.connected || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }.padding()
    }
    .navigationTitle(chat.bookmark.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button("New Chat", systemImage: "plus") { newChatConfirmation = true }
            .disabled(chat.busy || appStore.settings.airplaneModeEnabled)
          Button("Disconnect", systemImage: "network.slash") { chat.disconnect() }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
    .confirmationDialog(
      "Start a new remote chat? The current chat will remain on the agent host.",
      isPresented: $newChatConfirmation, titleVisibility: .visible
    ) {
      Button("New Chat") { chat.newChat() }
    }
    .sheet(
      item: Binding(
        get: { chat.permissions.first },
        set: { value in
          if value == nil, let first = chat.permissions.first {
            chat.answer(first.id, optionID: nil)
          }
        })
    ) { permission in
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            Text(permission.title).font(.headline)
            Text(permission.details).font(.system(.callout, design: .monospaced)).textSelection(
              .enabled)
            ForEach(permission.options) { option in
              Button(option.name) { chat.answer(permission.id, optionID: option.id) }
                .buttonStyle(.borderedProminent)
                .tint(option.kind.hasPrefix("reject") ? .red : .accentColor)
            }
            Button("Cancel tool request", role: .cancel) {
              chat.answer(permission.id, optionID: nil)
            }
          }.padding()
        }
        .navigationTitle("Remote Tool Permission")
        .navigationBarTitleDisplayMode(.inline)
      }
      .interactiveDismissDisabled()
    }
    .onDisappear { chat.disconnect() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { chat.disconnect() }
    }
    .onChange(of: appStore.settings.airplaneModeEnabled) { _, enabled in
      if enabled { chat.disconnect() }
    }
  }
}

private struct GatewayQRScanner: UIViewControllerRepresentable {
  let onCode: (String) -> Void
  let onFailure: (String) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode, onFailure: onFailure) }
  func makeUIViewController(context: Context) -> DataScannerViewController {
    let controller = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.qr])],
      qualityLevel: .balanced, recognizesMultipleItems: false, isGuidanceEnabled: true,
      isHighlightingEnabled: true)
    controller.delegate = context.coordinator
    let coordinator = context.coordinator
    Task { @MainActor in
      do { try controller.startScanning() } catch {
        coordinator.onFailure(error.localizedDescription)
      }
    }
    return controller
  }
  func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
  static func dismantleUIViewController(
    _ controller: DataScannerViewController, coordinator: Coordinator
  ) {
    controller.stopScanning()
  }
  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    let onCode: (String) -> Void
    let onFailure: (String) -> Void
    var delivered = false
    init(onCode: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
      self.onCode = onCode
      self.onFailure = onFailure
    }
    func dataScanner(
      _ scanner: DataScannerViewController,
      becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
    ) {
      scanner.stopScanning()
      onFailure(error.localizedDescription)
    }
    func dataScanner(
      _ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
      allItems: [RecognizedItem]
    ) {
      guard !delivered else { return }
      for case .barcode(let barcode) in addedItems {
        if let text = barcode.payloadStringValue {
          delivered = true
          scanner.stopScanning()
          onCode(text)
          return
        }
      }
    }
  }
}
