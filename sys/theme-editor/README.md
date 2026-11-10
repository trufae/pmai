# Theme editor

A standalone Swift TUI with no dependencies or server. From the repository root:

```sh
swift run --package-path sys/theme-editor ThemeEditor
```

Or run `swift run ThemeEditor` inside this directory. Pass `--root /path/to/pmai`
to edit another checkout. The terminal must be at least 78 columns by 24 rows.

The theme and field selectors read the existing Swift definitions, including
defaults from `ConfiguredTerminalUI`. All themes retain their unsaved edits when
you switch between them. The preview includes a conversation, tool calls, diff,
Markdown emphasis, status messages, selection, and input prompt.

| Key | Action |
| --- | --- |
| Tab / Shift-Tab, Up / Down | Move focus |
| Enter / Space | Open a selector; Enter accepts and Escape cancels |
| Left / Right | Change a selection or adjust an RGB channel by 1 |
| Shift-Left / Shift-Right | Adjust an RGB channel by 16 |
| Home / End | First/last option, or channel value 0/255 |
| Page Up / Page Down | Move through an open selector |
| e | Type a replacement color; Enter applies |
| s / Ctrl-S | Save all changed themes |
| r | Reset the current field to its last loaded/saved value |
| R | Reload source, with confirmation if edits would be discarded |
| q / Escape | Quit, with an unsaved-changes prompt |
| Ctrl-C | Exit without saving |

Each color has **None**, **ANSI**, and **RGB** modes. None saves an empty string;
it uses the terminal default or the surrounding color according to the role.
ANSI names use your terminal's actual palette, including bright variants.
Typed values also accept the aliases supported by pmai and `rgb:abc` shorthand.
RGB sliders save `#rrggbb`. Switching to ANSI starts at white; switching to RGB
starts at `#808080`, since ANSI colors are controlled by the terminal.

Saving updates `MaiCore/Sources/MaiCLI/Terminal/TerminalTheme.swift` atomically.
Existing value replacements preserve surrounding formatting and comments;
omitted fields are inserted in initializer order. A save refuses to overwrite
source or defaults changed since loading. The parser intentionally handles the
literal `.init(...)` definitions used here, not arbitrary Swift expressions.
Rebuild pmai to use the changed built-in themes.

The implementation lives in `ThemeEditor.swift`, with source editing, input,
and rendering separated into small types for possible future REPL integration.
It uses POSIX terminals on macOS and Linux.

Focused checks (source preservation, saves, conflicts, and terminal interaction):

```sh
swift test --package-path sys/theme-editor
python3 sys/theme-editor/Tests/terminal-smoke.py "$(swift build --package-path sys/theme-editor --show-bin-path)/ThemeEditor"
```
