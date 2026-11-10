import AppKit
import MaiACP
import SwiftUI

struct MacWelcomeView: View {
  @Bindable var workspace: MacWorkspace

  private var recent: [ACPSessionInfo] {
    Array(workspace.snapshot.sessions.filter { $0.isArchived != true }.sorted {
      ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
    }.prefix(3))
  }

  var body: some View {
    GeometryReader { geometry in
      let columns = geometry.size.width >= 700 && !recent.isEmpty
      let layout = columns ? AnyLayout(HStackLayout(spacing: 40)) : AnyLayout(VStackLayout(spacing: 28))
      ScrollView {
        layout {
          VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
              .resizable().interpolation(.high).scaledToFit()
              .frame(width: 128, height: 128)
              .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
              .shadow(color: .accentColor.opacity(0.12), radius: 18, y: 8)
              .accessibilityHidden(true)
            Text("PocketMai").font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text(workspace.hostID == nil ? "Your pocket assistant" : workspace.hostName)
              .font(.title3).foregroundStyle(.secondary)
            if workspace.cwd.isEmpty {
              Button("Open Workspace…", action: workspace.chooseFolder).buttonStyle(.borderedProminent)
              Button("Connect to Host…") { workspace.showConnection = true }
            } else {
              Button("New Chat", action: workspace.newChat).buttonStyle(.borderedProminent)
            }
          }
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
          .disabled(workspace.busy)

          if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
              Text("Pick up where you left off")
                .font(.headline).foregroundStyle(.secondary).padding(.horizontal, 4)
              ForEach(recent) { session in
                recentConversation(session)
              }
            }
            .frame(maxWidth: .infinity)
            .disabled(workspace.busy)
          } else if workspace.busy {
            ProgressView("Loading conversations…")
          }
        }
        .frame(maxWidth: columns ? 900 : 430)
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
      }
    }
  }

  private func recentConversation(_ session: ACPSessionInfo) -> some View {
    let folder = workspace.snapshot.folders.first { $0.cwd == session.cwd }
    let folderName = folder?.name ?? URL(fileURLWithPath: session.cwd).lastPathComponent
    return Button {
      workspace.selectFolder(session.cwd)
      workspace.open(session)
    } label: {
      HStack(spacing: 12) {
        Image(systemName: folder?.icon ?? "folder").foregroundStyle(.tint).frame(width: 22)
        VStack(alignment: .leading, spacing: 4) {
          Text(session.title).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
          Text([folderName, session.updatedAt?.formatted(.relative(presentation: .named))]
            .compactMap { $0 }.joined(separator: " · "))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.accentColor.opacity(recent.first?.id == session.id ? 0.10 : 0.03),
        in: RoundedRectangle(cornerRadius: 14))
      .overlay {
        RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.16), lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 14))
    }
    .buttonStyle(.plain)
    .help("Open \(session.title) in \(folderName)")
  }
}
