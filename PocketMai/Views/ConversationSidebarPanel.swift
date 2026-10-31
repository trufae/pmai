import SwiftUI

/// Adjacent rows share one pill header; stores keep their existing sort order.
struct SidebarGroupedRows<Item: Identifiable, Row: View>: View {
  let items: [Item]
  let groupTitle: (Item) -> String
  @ViewBuilder let row: (Item) -> Row

  var body: some View {
    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
      let title = groupTitle(item)
      if index == 0 || groupTitle(items[index - 1]) != title {
        SidebarGroupHeader(title: title)
      }
      row(item)
    }
  }
}

struct SidebarGroupHeader: View {
  let title: String

  var body: some View {
    HStack(spacing: 8) {
      line
      Text(title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(nil)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
      line
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .listRowInsets(EdgeInsets())
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
    .accessibilityAddTraits(.isHeader)
  }

  private var line: some View {
    Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1 / UIScreen.main.scale)
  }
}

struct SidebarPanel<Rows: View, Actions: View>: View {
  let title: String
  var backTitle: String? = nil
  var onBack: () -> Void = {}
  @ViewBuilder let rows: () -> Rows
  @ViewBuilder let actions: (Bool) -> Actions

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .bottom) {
        List { rows().listRowBackground(Color.clear) }
          .environment(\.defaultMinListRowHeight, 0)
          .listStyle(.plain)
          .scrollContentBackground(.hidden)
          .contentMargins(.horizontal, 16, for: .scrollContent)
          .scrollIndicators(.hidden)
          .safeAreaInset(edge: .top, spacing: 0) {
            HostPanelHeader(title: title, backTitle: backTitle, action: onBack)
          }
          .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 100)
          }
        SidebarEdgeFades()
        actions(proxy.size.width - 36 < 300)
          .frame(maxWidth: .infinity, minHeight: 56)
          .padding(.horizontal, 18).padding(.bottom, 22)
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
