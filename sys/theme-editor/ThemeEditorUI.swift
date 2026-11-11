import Foundation

struct ThemeItem {
  let key: String
  let title: String
  var fields: [ThemeField]

  static func grouped(_ fields: [ThemeField]) -> [ThemeItem] {
    let titles = ["text": "Text", "backgroundLine": "Status bar", "prompt": "Input prompt",
      "bubble": "User bubble", "toolCall": "Tool call", "toolResult": "Tool result",
      "error": "Error", "warning": "Warning", "success": "Success", "info": "Info",
      "thinking": "Thinking", "diffAdded": "Diff added", "diffRemoved": "Diff removed",
      "diffHeader": "Diff header", "selection": "Selection", "bold": "Markdown bold",
      "italic": "Markdown italic"]
    var items: [ThemeItem] = []
    for field in fields {
      let key: String
      if ["foreground", "background", "bold"].contains(field.name) { key = "text" }
      else if field.name == "toolCallBold" { key = "toolCall" }
      else if field.name.hasSuffix("Foreground") { key = String(field.name.dropLast(10)) }
      else if field.name.hasSuffix("Background") { key = String(field.name.dropLast(10)) }
      else { key = field.name }
      if let index = items.firstIndex(where: { $0.key == key }) { items[index].fields.append(field) }
      else { items.append(ThemeItem(key: key, title: titles[key] ?? field.name, fields: [field])) }
    }
    return items
  }

  static func component(_ field: ThemeField) -> String {
    field.isFlag ? "bold" : field.shortName.hasPrefix("bg") ? "bg" : "fg"
  }
}

struct ThemeEdit {
  let theme: String
  let field: String
  let before: String
  let after: String
}

struct ThemeEditorUI {
  var document: ThemeDocument
  var themeIndex = 0
  var itemIndex = 0
  var memberIndex = 0
  var channel = 0
  var input: String?
  var confirmation: String?
  var help = false
  var helpOffset = 0
  var helpPageSize = 1
  var clipboard: String?
  var undo: [ThemeEdit] = []
  var redo: [ThemeEdit] = []
  var previewOffset = 0
  var previewPageSize = 1
  var revealSelection = true
  var blinkStarted: TimeInterval = -.infinity
  var status = "Ready. Edits stay in memory until you save."
  var items: [ThemeItem] { ThemeItem.grouped(document.fields) }
  var item: ThemeItem { items[itemIndex] }
  var theme: String { document.themes[themeIndex].name }
  var field: ThemeField { item.fields[memberIndex] }
  var value: String { document.values[theme]![field.name]! }
  var mode: Int { value.isEmpty ? 0 : ThemeColor.rgb(value) == nil ? 1 : 2 }

  mutating func highlight() {
    blinkStarted = ProcessInfo.processInfo.systemUptime
    revealSelection = true
  }

  func blinkPhase(at time: TimeInterval) -> Int {
    let elapsed = time - blinkStarted
    return elapsed >= 0 && elapsed < 1.2 ? Int(elapsed / 0.2) : 6
  }

  mutating func moveItem(to index: Int) {
    let component = ThemeItem.component(field)
    itemIndex = max(0, min(items.count - 1, index))
    memberIndex = item.fields.firstIndex(where: { ThemeItem.component($0) == component }) ?? 0
    highlight()
  }

  mutating func moveMember(_ direction: Int) {
    memberIndex = (memberIndex + item.fields.count + direction) % item.fields.count
    highlight()
  }

  mutating func selectComponent(_ component: String) {
    if let index = item.fields.firstIndex(where: { ThemeItem.component($0) == component }) {
      memberIndex = index
      highlight()
    } else { status = "\(item.title) has no \(component) setting." }
  }

  mutating func setValue(_ replacement: String) {
    if replacement != value {
      undo.append(ThemeEdit(theme: theme, field: field.name, before: value, after: replacement))
      redo.removeAll()
      document.values[theme]![field.name] = replacement
    }
    status = "\(theme).\(field.name) = \(replacement.isEmpty ? "none" : replacement)"
  }

  mutating func adjust(_ direction: Int, step: Int = 1) {
    if field.isFlag { setValue(value == "true" ? "false" : "true") }
    else if var rgb = ThemeColor.rgb(value) {
      rgb[channel] = max(0, min(255, rgb[channel] + direction * step))
      setValue(String(format: "#%02x%02x%02x", rgb[0], rgb[1], rgb[2]))
    } else {
      let colors = [""] + ThemeColor.names
      let index = colors.firstIndex(of: ThemeColor.aliases[value] ?? value) ?? 0
      setValue(colors[(index + colors.count + direction) % colors.count])
    }
  }

  mutating func replay(redoing: Bool) {
    guard let edit = redoing ? redo.popLast() : undo.popLast() else {
      status = redoing ? "Nothing to redo." : "Nothing to undo."
      return
    }
    document.values[edit.theme]![edit.field] = redoing ? edit.after : edit.before
    if redoing { undo.append(edit) } else { redo.append(edit) }
    themeIndex = document.themes.firstIndex(where: { $0.name == edit.theme })!
    itemIndex = items.firstIndex(where: { $0.fields.contains(where: { $0.name == edit.field }) })!
    memberIndex = item.fields.firstIndex(where: { $0.name == edit.field })!
    highlight()
    status = "\(redoing ? "Redid" : "Undid") \(theme).\(field.name) = \(value.isEmpty ? "none" : value)"
  }

  mutating func save() -> Bool {
    do {
      let count = document.changedCount
      try document.save()
      status = count == 0 ? "No changes to save." : "Saved \(count) changes to TerminalTheme.swift."
      return true
    } catch { status = error.localizedDescription; return false }
  }

  mutating func handle(_ key: Key) -> Bool {
    if key == .interrupt || key == .eof { return false }
    if let confirmation {
      if key == .escape || key == .character("n") { self.confirmation = nil }
      else if confirmation == "quit" {
        if key == .character("d") { return false }
        if key == .character("s") { self.confirmation = nil; return !save() }
      } else if key == .character("y") { self.confirmation = nil; reload() }
      return true
    }
    if var input {
      switch key {
      case .escape: self.input = nil
      case .backspace: if !input.isEmpty { input.removeLast() }; self.input = input
      case .character(let c): if input.count < 32 { self.input = input + String(c) }
      case .enter:
        if let color = ThemeColor.normalize(input) { self.input = nil; setValue(color) }
        else { status = "Invalid color. Use none, blue, bright-red, #aabbcc, or rgb:abc." }
      default: break
      }
      return true
    }
    if help {
      switch key {
      case .escape, .character("?"), .enter: help = false
      case .down, .character("j"): helpOffset += 1
      case .up, .character("k"): helpOffset = max(0, helpOffset - 1)
      case .pageDown: helpOffset += helpPageSize
      case .pageUp: helpOffset = max(0, helpOffset - helpPageSize)
      case .home, .character("g"): helpOffset = 0
      case .end, .character("G"): helpOffset = Int.max
      default: break
      }
      return true
    }
    switch key {
    case .character("q"), .escape:
      if !document.dirty { return false }
      confirmation = "quit"
    case .character("?"): help = true; helpOffset = 0
    case .character("s"): _ = save()
    case .character("r"): setValue(document.original[theme]![field.name]!)
    case .character("R"):
      if document.dirty { confirmation = "reload" } else { reload() }
    case .character("u"): replay(redoing: false)
    case .character("U"): replay(redoing: true)
    case .character("y"): clipboard = value; status = "Copied \(value.isEmpty ? "none" : value). p pastes."
    case .character("p"):
      if let clipboard, (try? field.literal(clipboard)) != nil { setValue(clipboard) }
      else { status = "Copy a compatible \(field.isFlag ? "flag" : "color") with y first." }
    case .enter, .character("e"):
      if field.isFlag { adjust(1) } else { input = "" }
    case .tab, .backTab:
      themeIndex = (themeIndex + document.themes.count + (key == .tab ? 1 : -1)) % document.themes.count
      highlight()
    case .down, .character("j"): moveItem(to: itemIndex + 1)
    case .up, .character("k"): moveItem(to: itemIndex - 1)
    case .home, .character("g"): moveItem(to: 0)
    case .end, .character("G"): moveItem(to: items.count - 1)
    case .listPageUp: moveItem(to: itemIndex - 8)
    case .listPageDown: moveItem(to: itemIndex + 8)
    case .character("h"), .character("["): moveMember(-1)
    case .character("l"), .character("]"), .character(" "): moveMember(1)
    case .character("f"): selectComponent("fg")
    case .character("b"): selectComponent("bg")
    case .character("v"): selectComponent("bold")
    case .character("c"):
      if field.isFlag { adjust(1) } else { setValue(["", "white", "#808080"][(mode + 1) % 3]) }
    case .character("n") where !field.isFlag: setValue("")
    case .character("1"), .character("2"), .character("3"):
      channel = key == .character("1") ? 0 : key == .character("2") ? 1 : 2
    case .left, .character("-"): adjust(-1)
    case .right, .character("+"), .character("="): adjust(1)
    case .fastLeft: adjust(-1, step: 16)
    case .fastRight: adjust(1, step: 16)
    case .pageUp, .pageDown:
      previewOffset = max(0, previewOffset + (key == .pageUp ? -previewPageSize : previewPageSize))
      revealSelection = false
    case .character("."): highlight()
    default: break
    }
    return true
  }

  mutating func reload() {
    do {
      let name = theme
      let fieldName = field.name
      document = try ThemeDocument(sourceURL: document.sourceURL, configurationURL: document.configurationURL)
      themeIndex = document.themes.firstIndex(where: { $0.name == name }) ?? 0
      itemIndex = items.firstIndex(where: { $0.fields.contains(where: { $0.name == fieldName }) }) ?? 0
      memberIndex = item.fields.firstIndex(where: { $0.name == fieldName }) ?? 0
      undo.removeAll(); redo.removeAll()
      highlight()
      status = "Reloaded themes from disk."
    } catch { status = error.localizedDescription }
  }

  mutating func frame(columns: Int, rows: Int, now: TimeInterval) -> String {
    let columns = max(1, columns)
    let rows = max(1, rows)
    let left = columns >= 40 ? 2 : 1
    // Leave the last column free to avoid autowrap, unless it is the only column.
    let right = max(1, columns - 1)
    let width = right - left + 1
    var screen = Array(repeating: "", count: rows)
    func put(_ x: Int, _ y: Int, _ text: String, width: Int, style: String = "") {
      guard y > 0, y <= rows, x > 0, x <= right else { return }
      let width = max(0, min(width, right - x + 1))
      let safe = text.map { $0.isNewline || $0.asciiValue.map({ $0 < 32 || $0 == 127 }) == true ? " " : $0 }
      let clipped = String(safe.prefix(width))
      screen[y - 1] += "\u{1b}[\(y);\(x)H" + Terminal.reset + style + clipped
        + String(repeating: " ", count: max(0, width - clipped.count)) + Terminal.reset
    }
    func wrapped(_ text: String) -> [String] {
      var rest = text[...]
      var lines: [String] = []
      while !rest.isEmpty {
        lines.append(String(rest.prefix(width)))
        rest = rest.dropFirst(width)
      }
      return lines
    }
    func rendered() -> String {
      // Paint each cleared row immediately rather than blanking the whole screen.
      screen.enumerated().map { row, content in
        Terminal.reset + "\u{1b}[\(row + 1);1H\u{1b}[2K" + content
      }.joined()
    }
    if help {
      let shortcuts = ["j/k Up/Down: move through elements", "g/G Home/End: first/last element",
        "Ctrl-U/D: page through elements", "Tab / Shift-Tab: next/previous theme",
        "h/l [/] Space: cycle fg/bg/bold", "f / b / v: select fg / bg / bold",
        "Enter / e: type color; toggle flag", "c / n: cycle mode / use none",
        "Left/Right -/+: adjust color/channel", "Shift-Left/Right: adjust channel by 16",
        "1/2/3: select R/G/B channel", "y / p: copy / paste value", "u / U: undo / redo edit",
        "r / R: reset field / reload", "s Ctrl-S: save all themes",
        "PgUp/PgDn: scroll conversation", ".: blink/reveal selection",
        "q / Esc: quit; check unsaved edits", "Ctrl-C: exit without saving"]
      let lines = shortcuts.flatMap(wrapped)
      let top = rows > 1 ? 2 : 1
      helpPageSize = rows - top + 1
      helpOffset = min(helpOffset, max(0, lines.count - helpPageSize))
      if rows > 1 { put(left, 1, "? close · j/k scroll · KEYBOARD", width: width, style: "\u{1b}[1m") }
      for (offset, line) in lines.dropFirst(helpOffset).prefix(helpPageSize).enumerated() {
        put(left, top + offset, line, width: width)
      }
      return rendered()
    }

    let titleRows = rows >= 12 ? 2 : rows >= 5 ? 1 : 0
    let footerRows = rows >= 8 ? 2 : rows >= 3 ? 1 : 0
    let top = titleRows + 1
    let height = rows - titleRows - footerRows
    let sideBySide = columns >= 72
    let editorWidth = sideBySide ? 33 : width
    let editorHeight = sideBySide ? height : max(1, min(9, height / 2))
    let palette = document.values[theme]!
    if titleRows > 0 {
      let title = width >= 58 ? "PMAI THEME EDITOR  |  \(theme)\(document.dirty ? "  * unsaved" : "")"
        : "\(theme)\(document.dirty ? " *" : "") · THEME EDITOR"
      put(left, 1, title, width: width, style: "\u{1b}[1m")
    }
    if titleRows > 1 {
      put(left, 2, "Tab / Shift-Tab: theme \(themeIndex + 1)/\(document.themes.count)   ? help   \(document.changedCount) changes",
        width: width, style: "\u{1b}[2m")
    }

    let listHeader = editorHeight >= 9 ? 1 : 0
    let separator = editorHeight >= 14 ? 1 : 0
    let details = editorHeight >= 10 ? 4 : editorHeight >= 6 ? 3 : editorHeight >= 3 ? 2 : 1
    let listHeight = editorHeight - listHeader - separator - details
    let start = max(0, min(itemIndex - listHeight / 2, items.count - listHeight))
    if listHeader > 0 {
      put(left, top, "Elements \(start + 1)-\(min(items.count, start + listHeight))/\(items.count)",
        width: editorWidth - 10, style: "\u{1b}[2m")
      put(left + editorWidth - 10, top, "fg bg  B", width: 9, style: "\u{1b}[2m")
    }
    for (offset, entry) in items.dropFirst(start).prefix(listHeight).enumerated() {
      let selected = start + offset == itemIndex
      let changed = entry.fields.contains { palette[$0.name] != document.original[theme]?[$0.name] }
      let y = top + listHeader + offset
      put(left, y, "\(selected ? "›" : " ") \(entry.title)\(changed ? " *" : "")", width: editorWidth,
        style: selected ? "\u{1b}[7m" : "")
      if editorWidth >= 30 {
        for member in entry.fields {
          let component = ThemeItem.component(member)
          let x = left + editorWidth - (component == "fg" ? 10 : component == "bg" ? 7 : 3)
          let color = palette[member.name]!
          let active = selected && member.name == field.name
          let swatch = member.isFlag ? (color == "true" ? "1" : "0") : color.isEmpty ? "··" : "██"
          put(x, y, swatch, width: member.isFlag ? 1 : 2,
            style: (member.isFlag ? "" : "\u{1b}[\(ThemeColor.code(color))m") + (active ? "\u{1b}[4m" : ""))
        }
      }
    }
    var detailY = top + listHeader + listHeight
    if separator > 0 {
      put(left, detailY, String(repeating: "─", count: editorWidth), width: editorWidth, style: "\u{1b}[2m")
      detailY += 1
    }
    if details >= 3 {
      var x = left
      for member in item.fields {
        let label = " \(ThemeItem.component(member)) "
        put(x, detailY, label, width: min(label.count, left + editorWidth - x),
          style: member.name == field.name ? "\u{1b}[7m" : "\u{1b}[2m")
        x += label.count + 1
      }
      detailY += 1
    }
    let currentValue = "\(field.shortName) = \(value.isEmpty ? "none" : value)"
    let editingValue = input.map { String("Color: \($0)_".suffix(editorWidth)) }
    put(left, detailY, editingValue ?? currentValue, width: editorWidth,
      style: input == nil ? "" : "\u{1b}[1m")
    if details >= 2 {
      let modeText: String
      if let rgb = ThemeColor.rgb(value), !field.isFlag {
        modeText = (0..<3).map { "\($0 == channel ? "[" : "")\(["R", "G", "B"][$0]):\(rgb[$0])\($0 == channel ? "]" : "")" }
          .joined(separator: " ")
      } else {
        modeText = field.isFlag ? "Boolean · Enter toggles" : "\(["None", "ANSI", "RGB"][mode]) · c changes color mode"
      }
      put(left, detailY + 1, input == nil ? modeText : "Enter applies · Esc cancels", width: editorWidth)
    }
    if details == 4 {
      put(left, detailY + 2, "h/l part  ←/→ value  1/2/3 RGB", width: editorWidth, style: "\u{1b}[2m")
    }

    let previewX = sideBySide ? 38 : left
    let previewY = sideBySide ? top : top + editorHeight
    let previewWidth = right - previewX + 1
    let previewHeight = sideBySide ? height : height - editorHeight
    previewPageSize = 1
    if previewHeight > 0 {
      if sideBySide {
        for y in top..<(top + height) { put(36, y, "│", width: 1, style: "\u{1b}[2m") }
      }
      let preview = ThemePreview(palette: palette, width: previewWidth, compact: previewHeight < 8)
      let showChrome = previewHeight >= 3
      let showPosition = previewHeight >= 5
      let bodyHeight = previewHeight - (showChrome ? 2 : 0) - (showPosition ? 1 : 0)
      previewPageSize = bodyHeight
      previewOffset = min(previewOffset, max(0, preview.lines.count - bodyHeight))
      let header = ThemePreview.header(theme)
      let prompt = ThemePreview.prompt
      if revealSelection {
        if !(showChrome && (header.contains(field.name, palette: palette) || prompt.contains(field.name, palette: palette))),
          let target = preview.lines.firstIndex(where: { $0.contains(field.name, palette: palette) }),
          !(previewOffset..<(previewOffset + bodyHeight)).contains(target) {
          previewOffset = max(0, min(target - min(2, bodyHeight - 1), preview.lines.count - bodyHeight))
        }
        revealSelection = false
      }
      let phase = blinkPhase(at: now)
      let flashing = phase % 2 == 0 && phase < 6 ? field.name : nil
      func previewRow(_ y: Int, _ line: PreviewLine) {
        screen[y - 1] += "\u{1b}[\(y);\(previewX)H" + line.render(width: previewWidth, palette: palette, flashing: flashing)
      }
      if showChrome { previewRow(previewY, header) }
      let bodyY = previewY + (showChrome ? 1 : 0)
      for offset in 0..<bodyHeight {
        let index = previewOffset + offset
        previewRow(bodyY + offset, index < preview.lines.count ? preview.lines[index] : PreviewLine())
      }
      if showChrome { previewRow(bodyY + bodyHeight, prompt) }
      if showPosition {
        put(previewX, previewY + previewHeight - 1,
          "Preview \(previewOffset + 1)-\(min(preview.lines.count, previewOffset + bodyHeight))/\(preview.lines.count) · PgUp/PgDn",
          width: previewWidth, style: "\u{1b}[2m")
      }
    }
    if footerRows > 0 { put(left, rows - footerRows + 1, status, width: width) }
    if footerRows > 1 {
      put(left, rows, width >= 70
        ? "j/k items · Tab themes · e edit · f/b fg/bg · u undo · s save · ? help · q quit"
        : "e edit · s save · ? help · q quit", width: width, style: "\u{1b}[2m")
    }
    if let confirmation {
      let message = confirmation == "quit" ? "Unsaved edits: s save & quit / d discard / Esc stay"
        : "Reload and discard unsaved edits? y yes / n no"
      // Wrap prompts over the lower rows so narrow terminals still show the choices.
      let lines = wrapped(message)
      let visible = lines.suffix(rows)
      for (offset, line) in visible.enumerated() {
        let y = rows - visible.count + offset + 1
        screen[y - 1] = ""
        put(left, y, line, width: width, style: "\u{1b}[7m")
      }
    }
    return rendered()
  }

  mutating func run() throws {
    try Terminal.run {
      var previous = (columns: 0, rows: 0)
      var previousPhase = -1
      var redraw = true
      while stopSignal == 0 {
        let size = Terminal.size
        let now = ProcessInfo.processInfo.systemUptime
        let phase = blinkPhase(at: now)
        if size != previous { revealSelection = true }
        if redraw || size != previous || phase != previousPhase {
          Terminal.write(frame(columns: size.columns, rows: size.rows, now: now))
          previous = size; previousPhase = phase
        }
        redraw = false
        if let key = Terminal.readKey() {
          if !handle(key) { break }
          redraw = true
        }
      }
    }
  }
}
