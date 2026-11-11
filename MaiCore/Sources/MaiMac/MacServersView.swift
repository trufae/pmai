import AppKit
import CoreImage.CIFilterBuiltins
import MaiCLI
import SwiftUI

struct MacServersView: View {
  @Bindable var server: MacServerStore
  @State private var revoking: RemoteHostingClient?
  @State private var qrImage: NSImage?

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: server.snapshot.running ? "antenna.radiowaves.left.and.right" : "server.rack")
          .foregroundStyle(server.snapshot.running ? Color.green : .secondary)
        VStack(alignment: .leading, spacing: 4) {
          Text("Servers").font(.headline)
          Text(server.busy ? "Updating server…" : server.snapshot.status)
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        Spacer()
        if server.busy { ProgressView().controlSize(.small) }
        if server.snapshot.running || server.busy {
          Button("Stop Server", role: .destructive, action: server.stop)
        } else {
          Button("Start Server", action: server.start).buttonStyle(.borderedProminent)
        }
      }.padding()
      Form {
        if !server.snapshot.running {
          configuration.disabled(server.busy)
        }
        if let endpoint = server.snapshot.endpoint {
          Section("Connection") {
            HStack {
              Text(endpoint).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
              Spacer()
              Button("Copy Endpoint") { copy(endpoint) }
            }
            if server.protocolName == "openai" {
              Text("Use this base URL in an OpenAI-compatible client. Models, chat completions, and audio use this Mac’s configured providers.")
                .foregroundStyle(.secondary)
              if let token = server.snapshot.bearerToken, !token.isEmpty {
                HStack {
                  Text("Bearer authentication is required.")
                  Spacer()
                  Button("Copy API Key") { copy(token) }
                }
              } else { Text("Local clients can connect without an API key.").foregroundStyle(.secondary) }
            }
          }
        }
        if server.snapshot.pairingURI != nil { pairing }
        if !server.snapshot.requests.isEmpty {
          Section("Pending Clients") {
            ForEach(server.snapshot.requests) { request in
              HStack {
                VStack(alignment: .leading, spacing: 4) {
                  Text(request.name).font(.headline)
                  Text([request.kind, request.id, request.source].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Reject", role: .destructive) { server.resolve(request.id, allow: false) }
                Button("Accept") { server.resolve(request.id, allow: true) }
              }.disabled(server.busy)
            }
          }
        }
        if !server.permissions.isEmpty {
          Section("Tool Approvals") {
            ForEach(server.permissions) { permission in
              VStack(alignment: .leading, spacing: 8) {
                Text(permission.request.tool.name).font(.headline)
                Text(permission.request.call.arguments.compactJSONString)
                  .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                HStack {
                  Button("Deny", role: .destructive) { server.answer(permission.id, allow: false) }
                  Button("Allow Once") { server.answer(permission.id, allow: true) }
                }
              }
            }
          }
        }
        Section("Clients") {
          if server.snapshot.clients.isEmpty {
            Text("No accepted clients. Pair a device using the QR code or connection link.").foregroundStyle(.secondary)
          }
          ForEach(server.snapshot.clients) { client in
            HStack {
              Circle().fill(client.connections > 0 ? Color.green : .secondary).frame(width: 7, height: 7)
              VStack(alignment: .leading, spacing: 4) {
                Text(client.name).font(.headline)
                Text("\(client.kind) · \(client.connections > 0 ? "Active" : "Offline")")
                  .font(.caption).foregroundStyle(.secondary)
                Text(client.id).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
              }
              Spacer()
              Button("Revoke…", role: .destructive) { revoking = client }.disabled(server.busy)
            }
          }
          Text("Forwiroh device access and chat access are separate approvals. Accept both to connect; revoke either to remove that access. Start Forwiroh to view its saved devices.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if let error = server.error ?? server.snapshot.failure {
          Section {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
            if error == MacCLI.installationInstructions {
              Button("Copy Install Command") { copy(MacCLI.installCommand) }
            }
          }
        }
        if let notice = server.notice { Section { Text(notice).foregroundStyle(.secondary) } }
      }.formStyle(.grouped)
    }
    .task { await server.refresh() }
    .task(id: server.snapshot.pairingURI) {
      qrImage = server.snapshot.pairingURI.flatMap(Self.qrCode)
      if server.snapshot.pairingURI != nil, qrImage == nil { server.error = "Couldn’t render the QR code. Use Copy Pairing Link." }
    }
    .alert("Revoke \(revoking?.name ?? "client")?", isPresented: Binding(
      get: { revoking != nil }, set: { if !$0 { revoking = nil } }
    )) {
      Button("Revoke", role: .destructive) { if let client = revoking { server.revoke(client.id) }; revoking = nil }
      Button("Cancel", role: .cancel) { revoking = nil }
    } message: { Text("This removes its saved access and disconnects active connections. The client must pair again to reconnect.") }
  }

  private var configuration: some View {
    Group {
      Section("Server") {
        Picker("Protocol", selection: $server.protocolName) {
          Text("Forwiroh").tag("forwiroh")
          Text("Local Network (ACP)").tag("local")
          Text("OpenTunnel").tag("opentunnel")
          Text("OpenAI-compatible HTTP").tag("openai")
        }.onChange(of: server.protocolName) { old, new in
          if old == "openai", server.port == "11435" { server.port = "19283" }
          if new == "openai", server.port == "19283" { server.port = "11435" }
        }
        TextField("Port", text: $server.port)
        if server.protocolName == "openai" {
          TextField("Bind address", text: $server.bindAddress)
          Toggle("Enable agent tools", isOn: $server.allowTools)
          Text("127.0.0.1 accepts connections from this Mac. A network bind address requires an API key, generated automatically when needed. Tool requests that need approval appear here.")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          TextField("Host name", text: $server.name)
          if server.protocolName == "local" {
            Toggle("Listen on localhost only", isOn: $server.loopback)
            TextField("Advertised address (automatic if empty)", text: $server.advertisedAddress)
          }
          if server.protocolName == "opentunnel" {
            TextField("Existing wss:// gateway URL (optional)", text: $server.publicURL)
            Text("Leave empty to create a tunnel using the installed OpenTunnel CLI.").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Section("Workspace") {
        HStack {
          TextField("Working directory", text: $server.workingDirectory)
          Button("Choose…") { chooseFolders(multiple: false) { server.workingDirectory = $0[0] } }
        }
        Text("Configuration: \(server.configurationURL?.path ?? "Default settings")")
          .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        if server.protocolName != "openai" {
          Toggle("Share all indexed projects", isOn: $server.shareAll)
          if !server.shareAll {
            ForEach(server.paths, id: \.self) { path in
              HStack {
                Text(path).font(.caption).textSelection(.enabled)
                Spacer()
                Button("Remove", systemImage: "minus.circle") { server.paths.removeAll { $0 == path } }.labelStyle(.iconOnly)
              }
            }
            Button("Add Shared Folders…") {
              chooseFolders(multiple: true) { server.paths = Array(Set(server.paths + $0)).sorted() }
            }
          }
        }
        Text("The server uses these settings until stopped. Sharing continues when windows close and stops when you quit pmai.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var pairing: some View {
    Section("Pair a Client") {
      HStack(alignment: .top, spacing: 20) {
        if let qrImage {
          Image(nsImage: qrImage).interpolation(.none).resizable().scaledToFit()
            .frame(width: 280, height: 280).accessibilityLabel("Remote host pairing QR code")
        }
        VStack(alignment: .leading, spacing: 12) {
          Text("Scan in PocketMai’s Hosts screen, or paste the pairing link into another pmai client.")
          Text("Accept the device request below, then accept its chat access request.").foregroundStyle(.secondary)
          if let expires = server.snapshot.pairingExpiresAt {
            Text("Single-use invitation. Expires at \(expires.formatted(date: .omitted, time: .shortened)).")
              .font(.caption).foregroundStyle(.secondary)
          }
          Button("Copy Pairing Link") { if let uri = server.snapshot.pairingURI { copy(uri) } }
          Button("New QR Code", action: server.renewPairing).disabled(server.busy)
        }
      }
    }
  }

  private func chooseFolders(multiple: Bool, selected: ([String]) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = multiple
    if panel.runModal() == .OK { selected(panel.urls.map(\.path)) }
  }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  private static func qrCode(_ text: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "L"
    guard let output = filter.outputImage,
      let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
    // A white quiet zone remains visible in dark mode and makes camera scanning reliable.
    let size = NSSize(width: image.width + 8, height: image.height + 8)
    return NSImage(size: size, flipped: false) { rect in
      NSColor.white.setFill()
      rect.fill()
      NSGraphicsContext.current?.imageInterpolation = .none
      NSImage(cgImage: image, size: .zero).draw(in: rect.insetBy(dx: 4, dy: 4))
      return true
    }
  }
}
