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
            if hosts != nil || onSelectHost != nil { Divider() }
            if let hosts, hosts.selectedHostID == connection.id || hosts.isConnected(connection.id)
            {
              Button("Disconnect", systemImage: "network.slash") { hosts.disconnect(connection.id) }
            }
            if onSelectHost != nil {
              Button("Reconnect", systemImage: "arrow.clockwise") {
                if let hosts {
                  hosts.reconnect(connection.id, isOffline: appStore.settings.isOffline)
                } else {
                  store.reconnect(connection.id)
                }
              }
              .disabled(appStore.settings.isOffline)
            }
            Divider()
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
          "Connect to pmai or OpenCode over your local network or OpenTunnel. The remote agent runs its tools on its host. Chats and credentials stay on this device."
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
  @EnvironmentObject private var appStore: AppStore
  @State private var name = "pmai"
  @State private var address = ""
  @State private var token = ""
  @State private var cwd = ""
  @State private var uri = ""
  @State private var scanning = false
  @State private var error: String?
  @State private var accentColor: String?
  @State private var requiresApproval: Bool?
  @State private var forwirohInvitation: String?
  @State private var connectionProtocol: ACPRemoteProtocol = .local
  @State private var backend: RemoteAgentBackend = .acp
  @State private var importing = false
  @State private var importTask: Task<Void, Never>?

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
          TextField("Paste pmai connection or OpenCode pairing link", text: $uri, axis: .vertical)
            .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
          Button("Read Connection") { apply(uri) }
            .disabled(importing || uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if importing { ProgressView("Pairing with OpenCode…") }
          if DataScannerViewController.isSupported {
            Button("Scan Host QR", systemImage: "qrcode.viewfinder") {
              Task { await scan() }
            }
            .disabled(importing)
          }
        }
        Section("Server") {
          Picker("Server type", selection: $backend) {
            Text("pmai / ACP").tag(RemoteAgentBackend.acp)
            Text("OpenCode").tag(RemoteAgentBackend.openCode)
          }
          if backend == .openCode {
            Text("Run `opencode pair --remote` and scan its QR.")
              .font(.footnote).foregroundStyle(.secondary)
          }
          if backend == .acp {
            Picker("Connection", selection: $connectionProtocol) {
              ForEach(ACPRemoteProtocol.allCases, id: \.self) { kind in
                Text(kind.displayName).tag(kind)
              }
            }
          }
          TextField(backend == .openCode ? "https://host" : "wss://host/acp", text: $address)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          SecureField(
            backend == .openCode ? "OpenCode session token or password" : "Gateway token",
            text: $token
          )
          .textInputAutocapitalization(.never).autocorrectionDisabled()
          TextField(
            backend == .openCode
              ? "Workspace (optional; discovered after pairing)"
              : "Absolute workspace on remote host", text: $cwd
          )
          .textInputAutocapitalization(.never).autocorrectionDisabled()
        }

        if backend == .acp && connectionProtocol == .tailcat {
          Section("Set up Tailcat") {
            Text(
              "PocketMai connects to Tailcat workers through an ACP gateway. On the worker, run:")
            Text("pmai tailcat serve --name workstation")
              .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            Text("On your gateway computer, pair the worker's invite:")
            Text("pmai tailcat pair workstation '<worker invite>'")
              .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            Text(
              "Then start the gateway using the worker's workspace and your gateway's reachable address:"
            )
            Text(
              "pmai acp-gateway --host 0.0.0.0 --cwd /absolute/workspace --url ws://gateway.local:19283/acp --name workstation --qr gateway.png -- pmai tailcat connect workstation"
            )
            .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            Text(
              "Scan gateway.png here. The worker's Tailcat enrollment QR is used on the gateway computer."
            )
          }
        }

        Section {
          if address.lowercased().hasPrefix("ws://") || address.lowercased().hasPrefix("http://") {
            Label(
              "This connection is unencrypted. Use it only on a trusted private network, or use HTTPS / WSS.",
              systemImage: "lock.open")
          }
          if backend == .acp {
            Text(
              "For pmai, run /remote serve (Forwiroh by default), scan its QR, then accept with /remote accept. Forwiroh asks for device approval followed by ACP chat approval. Use --protocol local for direct LAN access or --protocol opentunnel for OpenTunnel. Use /remote qr for a fresh invitation when adding another device."
            )
            .font(.footnote).foregroundStyle(.secondary)
          }
        }
        if let error { Text(error).foregroundStyle(.red) }
      }
      .navigationTitle(initialHost == nil ? "Add Remote Host" : "Edit Remote Host")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }.disabled(importing)
        }
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
          .navigationTitle("Scan Host QR")
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
          forwirohInvitation = host.forwirohInvitation
          connectionProtocol = host.connectionProtocol ?? .local
          backend = host.backend ?? .acp
          do { token = try RemoteAgentStore.shared.token(for: host.id) } catch {
            self.error = error.localizedDescription
          }
        }
        if scanOnAppear { await scan() }
      }
      .onDisappear { importTask?.cancel() }
    }
  }

  private func scan() async {
    let allowed = await AVCaptureDevice.requestAccess(for: .video)
    guard allowed else {
      error = "Allow camera access for PocketMai in iOS Settings to scan a host QR."
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
    guard !importing else { return }
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("pmai-tailcat://") {
      backend = .acp
      connectionProtocol = .tailcat
      error =
        "Pair this Tailcat invite on your gateway computer with pmai tailcat pair. Then scan the ACP gateway QR here. See Set up Tailcat below."
      return
    }
    if !text.hasPrefix("pmai-acp://") {
      do {
        let link = try OpenCodePairingLink.parse(text)
        guard !appStore.settings.isOffline else {
          error = "Turn off Airplane Mode in Settings to pair with OpenCode."
          return
        }
        importing = true
        error = nil
        importTask = Task {
          defer {
            importing = false
            importTask = nil
          }
          do {
            let profile = try await link.redeem()
            try Task.checkCancellation()
            backend = .openCode
            name = initialHost?.name ?? profile.name
            address = profile.url.absoluteString
            token = profile.token
            cwd = initialHost?.cwd ?? profile.cwd
            requiresApproval = false
            uri = ""
          } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
          }
        }
      } catch { self.error = error.localizedDescription }
      return
    }
    do {
      let profile = try ACPRemoteConnection.parse(text)
      backend = .acp
      name = profile.name
      address = profile.url.absoluteString
      token = profile.token
      cwd = profile.cwd
      requiresApproval = profile.requiresApproval
      forwirohInvitation = profile.forwirohInvitation
      connectionProtocol =
        profile.connectionProtocol ?? (connectionProtocol == .tailcat ? .tailcat : .local)
      uri = ""
      error = nil
    } catch { self.error = error.localizedDescription }
  }

  private func save() {
    do {
      guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        error = "Enter the server URL."
        return
      }
      if backend == .openCode {
        let profile = try OpenCodeConnection(
          name: name.trimmingCharacters(in: .whitespacesAndNewlines),
          url: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines), cwd: cwd)
        let id = try RemoteAgentStore.shared.add(
          profile, replacing: initialHost?.id, accentColor: accentColor)
        dismiss()
        onAdded?(id)
        return
      }
      var profile = try ACPRemoteConnection(
        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
        url: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines), cwd: cwd,
        connectionProtocol: connectionProtocol)
      profile.requiresApproval = requiresApproval
      profile.forwirohInvitation = connectionProtocol == .forwiroh ? forwirohInvitation : nil
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
