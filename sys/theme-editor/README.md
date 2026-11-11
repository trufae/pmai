# Theme editor

A standalone Swift TUI with no dependencies or server. From the repository root:

```sh
make themeeditor
```

Or run `swift run ThemeEditor` inside this directory. Use
`make themeeditor ARGS="--root /path/to/pmai"` to edit another checkout.
The layout adapts to the terminal size, stacking the editor above the preview
in narrow terminals and reducing the visible rows in short terminals. Small
previews omit blank lines and bubble borders so the sample text stays visible.

The persistent element list reads every editable key from the existing Swift
definitions, including defaults from `ConfiguredTerminalUI`. Foreground,
background, and bold settings for an element share one row, with color swatches
and an unsaved-change marker. The selected component's key and value appear
below the list. Short terminals scroll the list to keep the selection visible.
All themes retain their unsaved edits when you switch between them.

The preview uses the available terminal height for a sample conversation with
the REPL's filled or outlined `◢` user bubbles, tool calls and results, a diff,
headings, emphasis, lists, a quote, code, a table, a link, status messages,
selection, and input prompt. Selecting a component reveals its sample and
briefly blinks the affected spans, then restores their normal colors. Page
through the conversation to inspect more of it, or press `.` to find the
selected component again.

| Key | Action |
| --- | --- |
| Tab / Shift-Tab | Next / previous theme |
| j / k, Up / Down | Next / previous element |
| g / G, Home / End | First / last element |
| Ctrl-U / Ctrl-D | Move eight elements up / down |
| h / l, [ / ], Space | Cycle an element's foreground, background, and bold components |
| f / b / v | Select foreground / background / bold directly |
| Enter / e | Type a replacement color, or toggle a Boolean; Enter applies, Escape cancels |
| Left / Right, - / + | Cycle ANSI colors (including none), toggle a Boolean, or adjust an RGB channel by 1 |
| Shift-Left / Shift-Right | Adjust an RGB channel by 16 |
| 1 / 2 / 3 | Select the red / green / blue channel |
| c / n | Cycle None / ANSI / RGB mode, or clear the color to none |
| y / p | Copy / paste a compatible color or Boolean value |
| u / U | Undo / redo an edit, including across themes |
| Page Up / Page Down | Scroll the preview conversation |
| . | Reveal and blink the selected component again |
| ? | Show keyboard help; j/k or Page Up/Down scrolls it; ? or Escape closes it |
| s / Ctrl-S | Save all changed themes |
| r | Reset the current field to its last loaded/saved value |
| R | Reload source, with confirmation if edits would be discarded |
| q / Escape | Quit, with an unsaved-changes prompt |
| Ctrl-C | Exit without saving |

Each color has **None**, **ANSI**, and **RGB** modes. None saves an empty string;
it uses the terminal default or the surrounding color according to the role.
ANSI names use your terminal's actual palette, including bright variants.
Typed values also accept the aliases supported by pmai and `rgb:abc` shorthand.
RGB adjustments save `#rrggbb`. Switching to ANSI starts at white; switching to RGB
starts at `#808080`, since ANSI colors are controlled by the terminal.

Saving updates `MaiCore/Sources/MaiCLI/Terminal/TerminalTheme.swift` atomically.
Existing value replacements preserve surrounding formatting and comments;
omitted fields are inserted in initializer order. A save refuses to overwrite
source or defaults changed since loading. The parser intentionally handles the
literal `.init(...)` definitions used here, not arbitrary Swift expressions.
Rebuild pmai to use the changed built-in themes.

Source editing and terminal input live in `ThemeEditor.swift`, the editor in
`ThemeEditorUI.swift`, and the sample conversation in `ThemePreview.swift`.
It uses POSIX terminals on macOS and Linux, without linking the CLI or calling
a model. The preview's Markdown examples follow the REPL renderer's theme
color mappings.

Focused checks (source preservation, saves, conflicts, and terminal interaction):

```sh
swift test --package-path sys/theme-editor
python3 sys/theme-editor/Tests/terminal-smoke.py "$(swift build --package-path sys/theme-editor --show-bin-path)/ThemeEditor"
```
