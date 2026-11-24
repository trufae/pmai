import SwiftUI

extension EnvironmentValues {
  @Entry var sidebarKeyboardActive = false
  @Entry var chatKeyboardActive = true
}

/// Uses the same actions as the visible controls and the system shortcut HUD.
struct KeyboardAction: View {
  let title: String
  let key: KeyEquivalent
  var modifiers: EventModifiers = .command
  let action: () -> Void

  var body: some View {
    Button(title, action: action)
      .keyboardShortcut(key, modifiers: modifiers)
      .hidden()
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
  }
}

struct SidebarKeyboardNavigation<ID: Hashable>: ViewModifier {
  @Environment(\.sidebarKeyboardActive) private var active
  @FocusState private var focused: Bool
  let items: [ID]
  @Binding var selection: ID?
  let activate: (ID) -> Void

  func body(content: Content) -> some View {
    ScrollViewReader { proxy in
      content
        .focusable(active)
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
          guard focused, press.modifiers.isEmpty, !items.isEmpty else { return .ignored }
          let index = selection.flatMap { items.firstIndex(of: $0) }
          let next = index.map { $0 + (press.key == .upArrow ? -1 : 1) }
            ?? (press.key == .upArrow ? items.count - 1 : 0)
          selection = items[min(max(next, 0), items.count - 1)]
          return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
          guard focused, press.modifiers.isEmpty, let selection, items.contains(selection)
          else { return .ignored }
          activate(selection)
          return .handled
        }
        .task(id: active) {
          if active {
            await Task.yield()
            guard !Task.isCancelled else { return }
          }
          focused = active
          selection = active ? items.first : nil
        }
        .onChange(of: focused) { _, focused in
          if !focused { selection = nil }
        }
        .onChange(of: items) { _, items in
          if focused, selection.map({ !items.contains($0) }) ?? true {
            selection = items.first
          }
        }
        .onChange(of: selection) { _, selection in
          if let selection { proxy.scrollTo(selection, anchor: .center) }
        }
    }
  }
}

extension View {
  func keyboardSidebarRow<ID: Hashable>(_ id: ID, selection: ID?) -> some View {
    self.id(id)
      .overlay {
        if selection == id {
          RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2)
            .allowsHitTesting(false)
        }
      }
  }
}
