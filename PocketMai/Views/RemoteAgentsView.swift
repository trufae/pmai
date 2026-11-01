import AVFoundation
import MaiACP
import MaiCore
import SwiftUI
import VisionKit

struct RemoteAgentsView: View {
  @EnvironmentObject private var appStore: AppStore
  @State private var store = RemoteAgentStore.shared
  @State private var adding = false
  @State private var editing: RemoteAgentBookmark?
  @State private var renaming: RemoteAgentBookmark?
  @State private var terminalLocation: RemoteTerminalLocation?

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
            RemoteHostMenu(
              host: connection, store: store, isOffline: appStore.settings.isOffline,
              rename: { renaming = connection },
              terminal: { if let cwd = connection.terminalWorkingDirectory { terminalLocation = .init(host: connection, cwd: cwd) } },
              edit: { editing = connection })
          }
        }
        Button("Add Remote Host", systemImage: "plus") { adding = true }
      } footer: {
        Text(
          "Tools run on the remote host. Connection credentials and cached chats stay on this device."
        )
      }
      if let error = store.error { Text(error).foregroundStyle(.red) }
    }
    .navigationTitle("Remote Hosts")
    .sheet(isPresented: $adding) { RemoteAgentConnectionView() }
    .sheet(item: $editing) { host in RemoteAgentConnectionView(initialHost: host) }
    .fullScreenCover(item: $terminalLocation) { RemoteTerminalView(location: $0).environmentObject(appStore) }
    .modifier(RemoteHostRenameModifier(host: $renaming))
  }
}

struct RemoteHostMenu: View {
  let host: RemoteAgentBookmark
  let store: RemoteAgentStore
  let isOffline: Bool
  let rename: () -> Void
  var connect: (() -> Void)?
  var terminal: (() -> Void)?
  let edit: () -> Void

  var body: some View {
    Button("Rename", systemImage: "character.cursor.ibeam", action: rename)
    Button(
      store.isHostPinned(host.id) ? "Unpin" : "Pin",
      systemImage: store.isHostPinned(host.id) ? "pin.slash" : "pin"
    ) { store.toggleHostPin(host.id) }
    if let connect {
      Divider()
      Button("Connect", systemImage: "network", action: connect).disabled(isOffline)
    }
    if let terminal, host.terminalWorkingDirectory != nil, host.requiresApproval != true {
      Button("Terminal", systemImage: "terminal", action: terminal).disabled(isOffline)
    }
    Divider()
    Button("Edit Host", systemImage: "pencil", action: edit)
  }
}

struct RemoteHostRenameModifier: ViewModifier {
  @Binding var host: RemoteAgentBookmark?
  @State private var name = ""
  @State private var showing = false
  @State private var error: String?

  func body(content: Content) -> some View {
    content
      .onChange(of: host?.id) { _, id in
        guard id != nil else { return }
        name = host?.name ?? ""
        showing = true
      }
      .onChange(of: showing) { _, showing in if !showing { host = nil } }
      .alert("Rename Host", isPresented: $showing, presenting: host) { host in
        TextField("Name", text: $name)
        Button("Cancel", role: .cancel) {}
        Button("Rename") {
          do { try RemoteAgentStore.shared.rename(host.id, to: name) } catch {
            self.error = error.localizedDescription
          }
        }
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .alert(
        "Couldn't Rename Host",
        isPresented: Binding(
          get: { error != nil }, set: { if !$0 { error = nil } })
      ) {
        Button("OK", role: .cancel) { error = nil }
      } message: {
        Text(error ?? "")
      }
  }
}

struct RemoteAgentConnectionView: View {
  var onAdded: ((UUID) -> Void)? = nil
  var initialHost: RemoteAgentBookmark? = nil
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var appStore: AppStore
  @State private var name = ""
  @State private var address = ""
  @State private var token = ""
  @State private var cwd = ""
  @State private var uri = ""
  @State private var scanning = false
  @State private var error: String?
  @State private var accentColor = AgentProjectTint.presetNames.randomElement() ?? "blue"
  @State private var requiresApproval: Bool?
  @State private var forwirohInvitation: String?
  @State private var connectionProtocol: ACPRemoteProtocol = .forwiroh
  @State private var backend: RemoteAgentBackend = .acp
  @State private var importing = false
  @State private var importTask: Task<Void, Never>?
  @State private var advanced = false
  @State private var deleting = false
  @State private var agentAccess = false

  private enum HostType: String, CaseIterable { case pocketMai = "PocketMai", webSocketACP = "WebSocketACP", openCode = "OpenCode" }
  private var hostType: HostType {
    backend == .openCode ? .openCode : connectionProtocol == .local ? .webSocketACP : .pocketMai
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("Host Type", selection: Binding(get: { hostType }, set: { value in
            backend = value == .openCode ? .openCode : .acp
            if value != .openCode { connectionProtocol = value == .webSocketACP ? .local : .forwiroh }
          })) {
            ForEach(HostType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.menu)
          .disabled(importing)
          Button {
            Task { await scan() }
          } label: {
            Label("Scan Host QR", systemImage: "qrcode.viewfinder")
              .labelStyle(.titleAndIcon)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.regular)
          .disabled(importing || !DataScannerViewController.isSupported)
          VStack(alignment: .leading, spacing: 8) {
            Text(hostType == .pocketMai ? "In the pmai REPL, run:" : "On your computer, run:")
            Text(hostType == .openCode ? "opencode pair --remote" : hostType == .webSocketACP
              ? "pmai acp-gateway --host 0.0.0.0 --cwd \"$PWD\" --url ws://HOST_IP:19283/acp -- pmai --acp --acp-root \"$PWD\""
              : "/remote serve")
              .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            Text(
              hostType == .openCode ? "Scan the QR, choose a name, then tap Add."
                : hostType == .webSocketACP
                ? "Replace HOST_IP with your computer’s LAN address, run this command in the project folder, then scan its QR. Other ACP agents can also be exposed through the gateway."
                : "Scan the QR and add the host. Approve the device and chat requests with /remote accept on your computer."
            )
          }
          .font(.footnote).foregroundStyle(.secondary)
          if !DataScannerViewController.isSupported {
            Text("QR scanning is unavailable on this device. Paste a connection in Advanced.")
              .font(.footnote).foregroundStyle(.secondary)
          }
          if importing { ProgressView("Pairing with OpenCode…") }
        }
        Section {
          TextField("Host name", text: $name)
            .disabled(importing)
          appearanceFields
            .disabled(importing)
          if !address.isEmpty {
            Label("Connection details added", systemImage: "checkmark.circle")
              .font(.footnote).foregroundStyle(.secondary)
          }
        }
        Section {
          DisclosureGroup("Advanced", isExpanded: $advanced) {
            manualConnectionFields
          }
          .disabled(importing)
        }
        if address.lowercased().hasPrefix("ws://") || address.lowercased().hasPrefix("http://") {
          Section {
            Label(
              "This connection is unencrypted. Use it only on a trusted private network, or use HTTPS / WSS.",
              systemImage: "lock.open")
          }
        }
        Section {
          Toggle("Allow Remote Tool", isOn: $agentAccess)
        } footer: {
          Text("Permit the native remote tool in local conversations to access this host’s files and run programs. Tool approvals still apply.")
        }
        if initialHost != nil {
          Section {
            Button("Delete Host", systemImage: "trash", role: .destructive) { deleting = true }
          }
        }
        if let error { Text(error).foregroundStyle(.red) }
      }
      .navigationTitle(initialHost == nil ? "Add Host" : "Edit Host")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(initialHost == nil ? "Add" : "Save") { save() }
            .disabled(
              importing || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
      .alert("Delete Host?", isPresented: $deleting) {
        Button("Delete Host", role: .destructive) {
          guard let host = initialHost else { return }
          RemoteAgentStore.shared.remove(host.id)
          dismiss()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This removes the saved connection and its chats from this device.")
      }
      .task {
        if let host = initialHost {
          name = host.name
          address = host.url.absoluteString
          cwd = host.cwd
          accentColor = host.accentColor ?? accentColor
          requiresApproval = host.requiresApproval
          forwirohInvitation = host.forwirohInvitation
          connectionProtocol = host.connectionProtocol ?? (host.url.scheme == "forwiroh" ? .forwiroh : .local)
          backend = host.backend ?? .acp
          agentAccess = host.agentAccess == true
          do { token = try RemoteAgentStore.shared.token(for: host.id) } catch {
            self.error = error.localizedDescription
          }
        }
      }
      .onDisappear { importTask?.cancel() }
    }
  }

  private var manualConnectionFields: some View {
    Group {
      TextField("Paste connection or pairing link", text: $uri, axis: .vertical)
        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
      Button("Import Connection") { apply(uri) }
        .disabled(importing || uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Divider()
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
      if backend == .acp && connectionProtocol == .tailcat {
        VStack(alignment: .leading, spacing: 8) {
          Text("Set up Tailcat").font(.headline)
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
    }
  }

  private var appearanceFields: some View {
    Group {
      Picker("Accent color", selection: Binding(
        get: { AgentProjectTint.presetNames.contains(accentColor) ? accentColor : "custom" },
        set: { selection in
          if selection == "custom" {
            let color = ConversationFolderTint(rawIdentifier: accentColor)?.color ?? .blue
            accentColor = "custom:" + (color.folderTintHex ?? "#007AFF")
          } else {
            accentColor = selection
          }
        }
      )) {
        ForEach(AgentProjectTint.presetNames, id: \.self) { name in
          Text(name.capitalized).tag(name)
        }
        Text("Custom").tag("custom")
      }
      .pickerStyle(.menu)
      if !AgentProjectTint.presetNames.contains(accentColor) {
        ColorPicker(
          "Custom accent",
          selection: Binding(
            get: { ConversationFolderTint(rawIdentifier: accentColor)?.color ?? .blue },
            set: { color in
              if let hex = color.folderTintHex { accentColor = "custom:" + hex }
            }),
          supportsOpacity: false)
      }
    }
  }

  private func scan() async {
    let allowed = await AVCaptureDevice.requestAccess(for: .video)
    guard allowed else {
      advanced = true
      error = "Allow camera access for PocketMai in iOS Settings to scan a host QR."
      return
    }
    guard DataScannerViewController.isAvailable else {
      advanced = true
      error = "Camera scanning is currently unavailable. Paste the connection in Advanced instead."
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
      advanced = true
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
      name = initialHost?.name ?? profile.name
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
        try RemoteAgentStore.shared.setAgentAccess(agentAccess, for: id)
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
      try RemoteAgentStore.shared.setAgentAccess(agentAccess, for: id)
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
