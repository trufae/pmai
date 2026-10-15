import AVFoundation
import MaiACP
import MaiCore
import SwiftUI
import VisionKit

struct RemoteAgentsView: View {
  var hosts: HostNavigationStore? = nil
  var onSelectHost: ((UUID) -> Void)? = nil
  @EnvironmentObject private var appStore: AppStore
  @State private var store = RemoteAgentStore.shared
  @State private var adding = false
  @State private var editing: RemoteAgentBookmark?
  @State private var renaming: RemoteAgentBookmark?

  var body: some View {
    List {
      Section {
        ForEach(store.connections) { connection in
          Button {
            editing = connection
          } label: {
            VStack(alignment: .leading) {
              Text(connection.name)
              Text(connection.url.absoluteString).font(.caption).foregroundStyle(.secondary)
              Text(connection.cwd).font(.caption).foregroundStyle(.secondary)
            }
          }
          .foregroundStyle(.primary)
          .contextMenu {
            Button("Rename", systemImage: "character.cursor.ibeam") { renaming = connection }
            Button("Edit Host", systemImage: "pencil") { editing = connection }
            if let hosts, hosts.selectedHostID == connection.id || hosts.isConnected(connection.id)
            {
              Button("Disconnect", systemImage: "network.slash") { hosts.disconnect(connection.id) }
            }
            if let onSelectHost {
              Button("Reconnect", systemImage: "arrow.clockwise") {
                if let hosts {
                  hosts.reconnect(connection.id, isOffline: appStore.settings.isOffline)
                } else {
                  store.reconnect(connection.id)
                }
                onSelectHost(connection.id)
              }
              .disabled(appStore.settings.isOffline)
            }
            Button("Remove Host", systemImage: "trash", role: .destructive) {
              store.remove(connection.id)
            }
          }
        }
        .onDelete { indices in
          for id in indices.map({ store.connections[$0].id }) { store.remove(id) }
        }
        Button("Add Remote Host", systemImage: "plus") { adding = true }
      } footer: {
        Text(
          "Connect to pmai over your local network or OpenTunnel. The remote agent runs its tools on its host. Chats and credentials stay on this device."
        )
      }
      if let error = store.error { Text(error).foregroundStyle(.red) }
    }
    .navigationTitle("Remote Hosts")
    .sheet(isPresented: $adding) { RemoteAgentConnectionView(onAdded: onSelectHost) }
    .sheet(item: $editing) { host in RemoteAgentConnectionView(initialHost: host) }
    .sheet(item: $renaming) { host in RemoteHostRenameView(host: host) }
  }
}

struct RemoteHostRenameView: View {
  let host: RemoteAgentBookmark
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var error: String?

  init(host: RemoteAgentBookmark) {
    self.host = host
    _name = State(initialValue: host.name)
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField("Name", text: $name)
        if let error { Text(error).foregroundStyle(.red) }
      }
      .navigationTitle("Rename Host")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            do {
              try RemoteAgentStore.shared.rename(host.id, to: name)
              dismiss()
            } catch { self.error = error.localizedDescription }
          }
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    .presentationDetents([.medium])
  }
}

struct RemoteAgentConnectionView: View {
  var onAdded: ((UUID) -> Void)? = nil
  var scanOnAppear = false
  var initialHost: RemoteAgentBookmark? = nil
  @Environment(\.dismiss) private var dismiss
  @State private var name = "pmai"
  @State private var address = ""
  @State private var token = ""
  @State private var cwd = ""
  @State private var uri = ""
  @State private var scanning = false
  @State private var error: String?
  @State private var accentColor: String?
  @State private var requiresApproval: Bool?
  @State private var connectionProtocol: ACPRemoteProtocol = .local

  var body: some View {
    NavigationStack {
      Form {
        Section("Appearance") {
          TextField("Name", text: $name)
          Picker("Accent color", selection: $accentColor) {
            Text("App default").tag(String?.none)
            ForEach(AgentProjectTint.presetNames, id: \.self) { name in
              Text(name.capitalized).tag(Optional(name))
            }
            if let accentColor, !AgentProjectTint.presetNames.contains(accentColor) {
              Text("Custom").tag(Optional(accentColor))
            }
          }
          ColorPicker(
            "Custom accent",
            selection: Binding(
              get: {
                accentColor.flatMap { ConversationFolderTint(rawIdentifier: $0) }?.color
                  ?? .accentColor
              },
              set: { accentColor = $0.folderTintHex.map { "custom:" + $0 } }),
            supportsOpacity: false)
        }
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
          Picker("Connection", selection: $connectionProtocol) {
            ForEach(ACPRemoteProtocol.allCases, id: \.self) { kind in
              Text(kind.displayName).tag(kind)
            }
          }
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
            "On the host, run /remote serve --protocol local or /remote serve --protocol opentunnel, then scan its QR. Accept pairing there with /remote accept. Review the host and workspace before saving."
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
        if let error { Text(error).foregroundStyle(.red) }
      }
      .navigationTitle(initialHost == nil ? "Add Remote Host" : "Edit Remote Host")
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
      .task {
        if let host = initialHost {
          name = host.name
          address = host.url.absoluteString
          cwd = host.cwd
          accentColor = host.accentColor
          requiresApproval = host.requiresApproval
          connectionProtocol = host.connectionProtocol ?? .local
          do { token = try RemoteAgentStore.shared.token(for: host.id) } catch {
            self.error = error.localizedDescription
          }
        }
        if scanOnAppear { await scan() }
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
      requiresApproval = profile.requiresApproval
      connectionProtocol = profile.connectionProtocol ?? .local
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
      var profile = try ACPRemoteConnection(
        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
        url: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines), cwd: cwd,
        connectionProtocol: connectionProtocol)
      profile.requiresApproval = requiresApproval
      let id = try RemoteAgentStore.shared.add(
        profile, replacing: initialHost?.id, accentColor: accentColor)
      dismiss()
      onAdded?(id)
    } catch { self.error = error.localizedDescription }
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
