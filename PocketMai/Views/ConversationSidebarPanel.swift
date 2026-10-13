import SwiftUI

struct ConversationSidebarPanel<Rows: View, Actions: View>: View {
  let title: String
  let onShowFolders: () -> Void
  @ViewBuilder let rows: () -> Rows
  @ViewBuilder let actions: (Bool) -> Actions

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        rows()
        SidebarEdgeFades()
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        HostPanelHeader(title: title, backTitle: "Folders", action: onShowFolders)
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        actions(proxy.size.width - 36 < 300)
          .frame(minHeight: 56).padding(.horizontal, 18).padding(.bottom, 22)
      }
    }
  }
}

struct ConversationSearchControls: View {
  @Binding var text: String
  let isFocused: FocusState<Bool>.Binding
  let compact: Bool
  let onShowSettings: () -> Void

  var body: some View {
    Group {
      FloatingSearchField(text: $text, isFocused: isFocused) {
        text = ""
        isFocused.wrappedValue = false
      }
      if !isFocused.wrappedValue && text.isEmpty {
        FloatingActionIcon(
          systemImage: "gearshape", accessibilityLabel: "Settings",
          compact: compact, action: onShowSettings
        )
        .transition(.opacity)
      }
    }
  }
}

enum SidebarSearch {
  static func matches(_ query: String, in texts: [String]) -> Bool {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty
      || texts.contains {
        $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
      }
  }
}
