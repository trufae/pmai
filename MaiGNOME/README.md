# PocketMai for GNOME

PocketMai uses GTK 4 and libadwaita for the desktop and the same Swift runtime
and chat files as the `pmai` CLI. Install the repository's Swift toolchain, GTK 4
development headers, libadwaita 1.4 or newer development headers, and `pkg-config`.
On Debian-based systems the development packages are `libgtk-4-dev` and
`libadwaita-1-dev`. On Fedora they are `gtk4-devel` and `libadwaita-devel`.

From the repository root, run `make gnome-run`. To build without launching, use
`make gnome`. By default it uses a single build job and a debug configuration.
The build shares SwiftPM's scratch directory with the CLI.

- Select a project and conversation in the sidebar. Search matches titles and
  project names across the project index. The archive button includes archived
  conversations, and Refresh picks up changes saved by the CLI. Right-click a
  conversation to rename, pin, archive, restore, delete, or open it in a local
  terminal when available. Use the header sidebar button to show or hide
  conversations.
- Start a chat with **New Chat**. Use the header model menu to select the agent,
  model, and other session options. Use **Tools** to search and enable or disable
  tools for the current chat. **Enter** sends the draft. Use
  **Shift+Enter** or **Ctrl+Enter** to insert a newline. Type **/** or **$** to
  find skills, prompts, and commands. Use **↑** and **↓** to select, **Tab** to
  complete, and **Esc** to dismiss the active menu or dialog.
- Consecutive tool calls share a collapsible row with counts. Expand it to see
  tool inputs and outputs. Permission requests appear above the composer.
  **Stop** interrupts a running reply. Right-click a message to copy it, or to
  edit, delete, or rewind from it when the host supports those actions.
- Use the header gear to edit providers, MCP servers, skills, and prompts. New
  and reconnected local conversations pick up saved settings. Under **Remote
  Hosts**, import a pairing link or enter a host manually, then choose the host
  in the sidebar to browse and resume its conversations.
- **Open in Terminal** releases the GUI session and resumes the same chat in
  the terminal. Finish that terminal session before reconnecting in the GUI.
  Use **Refresh Conversations** to pick up changes made in another process.

The app uses `PMAI_HOME` and the normal project-local `.pmai` directories. Use
`pmai-gnome --cd DIR --state STATE_DIR` for a project whose CLI chat storage was
relocated with `PMAI_STATE` or `--state`. Resuming a relocated chat requires the
CLI from this checkout or later. `--home DIR` selects a different global home.
The app uses the `pmai` executable next to `pmai-gnome` if available, then tries
the installed CLI. Set `PMAI_EXECUTABLE` to override the CLI path. Replies go into
the same chat files and the worker uses the existing project and provider settings.
