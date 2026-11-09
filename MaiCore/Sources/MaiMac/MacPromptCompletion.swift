import AppKit
import MaiCore
import Observation
import SwiftUI

@MainActor @Observable
final class MacPromptCompletion {
  var matches: [PromptCatalog.Entry] = []
  var selected = -1
  var prefix = "$"
  @ObservationIgnored var replacementRange = NSRange(location: 0, length: 0)
  @ObservationIgnored var choose: ((Int) -> Void)?

  func dismiss() {
    matches = []
    selected = -1
  }

  func update(text: String, selection: NSRange, catalog: PromptCatalog) {
    dismiss()
    guard selection.length == 0, let caret = Range(selection, in: text)?.lowerBound,
      let start = text.firstIndex(where: { !$0.isWhitespace }),
      PromptSlashCommand.prefixes.contains(text[start]) else { return }
    let nameStart = text.index(after: start)
    let end = text[nameStart...].firstIndex(where: \.isWhitespace) ?? text.endIndex
    guard caret >= nameStart, caret <= end else { return }
    let fragment = PromptSlashCommand.normalized(String(text[nameStart..<caret]))
    prefix = String(text[start])
    replacementRange = NSRange(start..<end, in: text)
    // Keep the catalog's lookup precedence when a configured prompt shadows
    // a builtin or skill. System prompts cannot be invoked by this composer.
    var seen = Set<String>()
    matches = catalog.entries.filter { entry in
      let name = PromptSlashCommand.normalized(entry.commandName)
      return seen.insert(name).inserted && entry.kind != .system && name.hasPrefix(fragment)
    }.sorted { $0.commandName < $1.commandName }
    if !matches.isEmpty { selected = 0 }
  }
}

struct MacPromptCompletionList: View {
  let completion: MacPromptCompletion

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(Array(completion.matches.enumerated()), id: \.element.id) { index, entry in
              MacPromptCompletionRow(entry: entry, prefix: completion.prefix,
                selected: index == completion.selected) { completion.choose?(index) }
              .id(index)
            }
          }.padding(6)
        }
        .frame(height: min(CGFloat(completion.matches.count) * 50 + 12, 262))
        .onChange(of: completion.selected) { _, index in
          if index >= 0 { proxy.scrollTo(index, anchor: .center) }
        }
      }
      Divider()
      Text("↑ ↓ to choose · Tab to complete · Esc to dismiss")
        .font(.caption).foregroundStyle(.secondary).padding(8)
    }
    .frame(maxWidth: 440)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary, lineWidth: 1) }
    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
  }
}

private struct MacPromptCompletionRow: View {
  let entry: PromptCatalog.Entry
  let prefix: String
  let selected: Bool
  let choose: () -> Void

  var body: some View {
    Button(action: choose) {
      HStack(spacing: 10) {
        Image(systemName: entry.kind == .skill ? "sparkles" : "text.bubble")
          .foregroundStyle(.secondary).frame(width: 18)
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text(prefix + entry.commandName).font(.callout.weight(.medium))
            Spacer(minLength: 8)
            Text(entry.kind.label).font(.caption).foregroundStyle(.secondary)
          }
          Text(entry.summary).font(.caption).foregroundStyle(.secondary)
        }
        .lineLimit(1)
      }
      .padding(.horizontal, 10).frame(height: 48)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(selected ? Color.accentColor.opacity(0.16) : Color.clear,
        in: RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain).focusable(false)
    .accessibilityLabel(prefix + entry.commandName + ", " + entry.kind.label)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
