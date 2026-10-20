import Foundation
import MaiACP

#if os(iOS)
  import SwiftUI
#else
  import SwiftUICore
#endif

@MainActor
struct RemoteHostView: @preconcurrency View {
  @Bindable var remote: PortableRemoteChat

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("Remote hosts").font(.title2)
        Text(
          "On your computer run /remote serve --protocol forwiroh, then paste its connection URI here."
        )
        TextField("pmai-acp://connect/…", text: $remote.invitation)
        Button("Pair host") { remote.pair() }.disabled(remote.busy || remote.invitation.isEmpty)
        ForEach(remote.hosts) { host in
          Button("Connect to " + host.name) { remote.connect(host) }.disabled(remote.busy)
        }
        if !remote.status.isEmpty { Text(remote.status).font(.caption) }
        if let error = remote.error { Text(error) }
        if remote.busy { ProgressView() }
        if remote.connected || remote.busy {
          Button(remote.busy ? "Cancel" : "Disconnect") { remote.disconnect() }
        }
        ForEach(remote.messages) { message in
          VStack(alignment: .leading, spacing: 4) {
            Text(message.role == "user" ? "You" : "Remote agent").font(.caption)
            MarkdownText(message.text)
          }
        }
        if !remote.streamed.isEmpty { MarkdownText(remote.streamed) }
        if remote.connected {
          TextField("Message remote agent", text: $remote.draft)
          Button("Send") { remote.send() }.disabled(remote.busy || remote.draft.isEmpty)
          Text(
            "The host executes tools. Interactive permission requests are rejected on this client."
          ).font(.caption)
        }
      }.padding()
    }
  }
}
