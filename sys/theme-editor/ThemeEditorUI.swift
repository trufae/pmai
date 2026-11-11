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
  var clipboard: String?
  var undo: [ThemeEdit] = []
  var redo: [ThemeEdit] = []
  var previewOffset = 0
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
    if help { if [.escape, .character("?"), .enter].contains(key) { help = false }; return true }
    switch key {
    case .character("q"), .escape:
      if !document.dirty { return false }
      confirmation = "quit"
    case .character("?"): help = true
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
      let page = max(1, Terminal.size.rows - 8)
      previewOffset = max(0, previewOffset + (key == .pageUp ? -page : page))
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
    var screen = Array(repeating: "", count: max(1, rows))
    func put(_ x: Int, _ y: Int, _ text: String, width: Int, style: String = "") {
      guard y > 0, y <= rows, x <= columns else { return }
      let width = max(0, min(width, columns - x))
      let safe = text.map { $0.isNewline || $0.asciiValue.map({ $0 < 32 || $0 == 127 }) == true ? " " : $0 }
      let clipped = String(safe.prefix(width))
      screen[y - 1] += "\u{1b}[\(y);\(x)H" + Terminal.reset + style + clipped
        + String(repeating: " ", count: max(0, width - clipped.count)) + Terminal.reset
    }
    put(2, 1, "PMAI THEME EDITOR  |  \(theme)\(document.dirty ? "  * unsaved" : "")",
      width: columns - 3, style: "\u{1b}[1m")
    put(2, 2, "Tab / Shift-Tab: theme \(themeIndex + 1)/\(document.themes.count)   ? help   \(document.changedCount) changes",
      width: columns - 3, style: "\u{1b}[2m")
    if columns < 78 || rows < 24 {
      put(2, 4, "Resize to at least 78 x 24 (now \(columns) x \(rows)).", width: columns - 3)
      put(2, 6, "s save  q quit  Ctrl-C exit", width: columns - 3)
    } else {
      let sidebar = 34
      let height = rows - 10
      let start = max(0, min(itemIndex - height / 2, items.count - height))
      let palette = document.values[theme]!
      put(2, 3, "Elements \(start + 1)-\(min(items.count, start + height))/\(items.count)", width: 22, style: "\u{1b}[2m")
      put(25, 3, "fg bg  B", width: 9, style: "\u{1b}[2m")
      for (offset, entry) in items.dropFirst(start).prefix(height).enumerated() {
        let selected = start + offset == itemIndex
        let changed = entry.fields.contains { palette[$0.name] != document.original[theme]?[$0.name] }
        put(2, 4 + offset, "\(selected ? "›" : " ") \(entry.title)\(changed ? " *" : "")", width: sidebar - 1,
          style: selected ? "\u{1b}[7m" : "")
        for member in entry.fields {
          let component = ThemeItem.component(member)
          let x = component == "fg" ? 25 : component == "bg" ? 28 : 32
          let color = palette[member.name]!
          let active = selected && member.name == field.name
          let swatch = member.isFlag ? (color == "true" ? "1" : "0") : color.isEmpty ? "··" : "██"
          put(x, 4 + offset, swatch, width: member.isFlag ? 1 : 2,
            style: (member.isFlag ? "" : "\u{1b}[\(ThemeColor.code(color))m") + (active ? "\u{1b}[4m" : ""))
        }
      }
      put(2, rows - 6, String(repeating: "─", count: sidebar - 1), width: sidebar - 1, style: "\u{1b}[2m")
      var x = 2
      for member in item.fields {
        let label = " \(ThemeItem.component(member)) "
        put(x, rows - 5, label, width: min(label.count, sidebar + 1 - x),
          style: member.name == field.name ? "\u{1b}[7m" : "\u{1b}[2m")
        x += label.count + 1
      }
      put(2, rows - 4, input.map { "Color: \($0)_" } ?? "\(field.shortName) = \(value.isEmpty ? "none" : value)",
        width: sidebar - 1, style: input == nil ? "" : "\u{1b}[1m")
      if let rgb = ThemeColor.rgb(value), !field.isFlag {
        let channels = (0..<3).map { "\($0 == channel ? "[" : " ")\(["R", "G", "B"][$0]):\(rgb[$0])\($0 == channel ? "]" : " ")" }
        put(2, rows - 3, channels.joined(separator: " "), width: sidebar - 1)
      } else {
        put(2, rows - 3, field.isFlag ? "Boolean · Enter toggles" : "\(["None", "ANSI", "RGB"][mode]) · c changes color mode", width: sidebar - 1)
      }
      put(2, rows - 2, input == nil ? "h/l part  ←/→ value  1/2/3 RGB" : "Enter applies · Esc cancels", width: sidebar - 1,
        style: "\u{1b}[2m")
      for y in 3...(rows - 2) { put(36, y, "│", width: 1, style: "\u{1b}[2m") }
      let previewX = 38
      let width = columns - previewX
      let preview = ThemePreview(palette: palette, width: width)
      let bodyHeight = rows - 7
      previewOffset = min(previewOffset, max(0, preview.lines.count - bodyHeight))
      let header = ThemePreview.header(theme)
      let prompt = ThemePreview.prompt
      if revealSelection {
        if !header.contains(field.name, palette: palette), !prompt.contains(field.name, palette: palette),
          let target = preview.lines.firstIndex(where: { $0.contains(field.name, palette: palette) }),
          !(previewOffset..<(previewOffset + bodyHeight)).contains(target) {
          previewOffset = max(0, min(target - 2, preview.lines.count - bodyHeight))
        }
        revealSelection = false
      }
      let flashing = blinkPhase(at: now) % 2 == 0 && blinkPhase(at: now) < 6 ? field.name : nil
      func previewRow(_ y: Int, _ line: PreviewLine) {
        screen[y - 1] += "\u{1b}[\(y);\(previewX)H" + line.render(width: width, palette: palette, flashing: flashing)
      }
      previewRow(3, header)
      for offset in 0..<bodyHeight {
        let index = previewOffset + offset
        previewRow(4 + offset, index < preview.lines.count ? preview.lines[index] : PreviewLine())
      }
      previewRow(rows - 3, prompt)
      put(previewX, rows - 2, "Preview \(previewOffset + 1)-\(min(preview.lines.count, previewOffset + bodyHeight))/\(preview.lines.count) · PgUp/PgDn",
        width: width, style: "\u{1b}[2m")
      if help {
        let shortcuts = ["KEYBOARD · ? / Esc closes", "j/k ↑/↓    Move through elements",
          "g/G Home/End   First/last element", "Ctrl-U/D   Page through elements",
          "Tab / Shift-Tab   Next/prev theme", "h/l [/] Space   Cycle fg/bg/bold",
          "f / b / v  Select fg / bg / bold", "Enter / e  Type color; toggle flag",
          "c / n      Cycle mode / use none", "←/→  -/+   Adjust color/channel",
          "Shift-←/→  Adjust channel by 16", "1/2/3      Select R/G/B channel",
          "y / p      Copy / paste value", "u / U      Undo / redo edit",
          "r / R      Reset field / reload", "s Ctrl-S   Save all themes",
          "PgUp/PgDn  Scroll conversation", ".          Blink/reveal selection",
          "q / Esc    Quit; check unsaved edits", "Ctrl-C     Exit without saving"]
        for y in 3...(rows - 2) {
          let index = y - 3
          put(previewX, y, index < shortcuts.count ? shortcuts[index] : "", width: width)
        }
      }
    }
    let message = confirmation == "quit" ? "Unsaved edits: s save & quit / d discard / Esc stay"
      : confirmation == "reload" ? "Reload and discard unsaved edits? y yes / n no" : status
    put(2, rows - 1, message, width: columns - 3, style: confirmation == nil ? "" : "\u{1b}[7m")
    put(2, rows, "j/k items · Tab themes · e edit · f/b fg/bg · u undo · s save · ? help · q quit", width: columns - 3,
      style: "\u{1b}[2m")
    // Paint each cleared row immediately, rather than blanking the whole screen
    // before the selection pulse. Leave the last column free to avoid autowrap.
    return screen.enumerated().map { row, content in
      Terminal.reset + "\u{1b}[\(row + 1);1H\u{1b}[2K" + content
    }.joined()
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
