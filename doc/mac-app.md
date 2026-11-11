# pmai for Mac

Build with `make mac`, then open `build/pmai.app`. `make mac-run` builds and
launches it. The minimum system is macOS 15; building with Xcode 27 adopts the
current macOS 27 system appearance. No iOS Simulator build is needed.

`make mac-install` builds and installs into `~/Applications/pmai.app`. Override
the destination with `MAC_INSTALL_DIR=/Applications` (which may require write
permission). `MAC_APP` overrides the build bundle path for all Mac targets.

`make mac-dmg` builds a Release app and creates `build/pmai.dmg`, containing
`pmai.app` and an Applications shortcut. Set `MAC_DMG` to change the output path,
or `CONFIG=Debug` to package a debug build.

At launch, the app checks for a newer release in the background using the same
release lookup as `pmai -U`. When an update is available, **Open GitHub** opens
its release page so you can download the macOS DMG and replace the app in
Applications. **Later** dismisses the notice until the next launch. Failed or
offline checks do not interrupt startup.

The app starts with a fresh chat in your last workspace, with the composer ready
to type. On first launch, it uses an existing CLI project or your home folder if
there are no projects yet. Previous conversations remain available in the sidebar.
Use **Open Workspace** (⇧⌘O) to select another folder. Existing CLI projects and chats
appear automatically. **New Chat** is ⌘N; **Send** is Return (or ⌘Return);
Shift-Return inserts a newline; **Stop** is ⌘. The conversation inspector contains provider, model,
reasoning, tool settings, and subagents. Running conversations remain open when
switching folders or hosts. Permission requests are attached to the conversation
that requested them, with an attention icon in the conversation list.

**New Window** (⌘⇧N) starts a fresh chat on the current host and folder. Each
window navigates independently, while open conversations and their backend
connections are shared. Different chats can run in parallel; opening the same
chat in two windows shares its transcript and draft. Closing a window keeps
running conversations alive until you close the conversation or quit the app.

The sidebar expands one section at a time: **Hosts**, **Folders**, or
**Conversations**. Selecting a host opens its folders; selecting a folder opens
its conversations. Click another section heading to return to that level. Open
chats appear once, in their own folder, alongside saved conversations.

Right-click a conversation to rename, fork, pin/unpin, archive/restore, delete,
or open it in the terminal. The small switch to the right of the search field
shows archived chats when enabled; its tooltip describes the current filter.
These operations use the CLI's chat storage and preserve the same fork and pin
semantics as `/chat`. Remote hosts advertise supported operations; older ACP
hosts and OpenCode offer rename/delete without the newer organization actions.
Running turns must finish or be stopped before editing a conversation.

Use **⌘-click** to select multiple saved conversations or **Shift-click** to
select a range. Right-click the selection or use its **Actions** menu to delete
the selected chats together or **Move to Folder**. Deletion asks once for the
whole selection. Moves stay on the same host and preserve history and settings;
remote hosts must advertise move support. If an individual operation fails,
the other selected chats are still processed and the error names the failed chat.

Host menus support renaming and removing saved connections. Folder menus offer
new chats and copying paths; local folders also support display-name changes,
Finder/terminal access, and removal from the sidebar. Removing a folder keeps
its files and chats. Removing a host only forgets this Mac's connection.

**Servers → Manage Servers…** (also **Settings → Servers** and the toolbar's
server button) exposes this Mac to other clients. Choose **OpenAI-compatible
HTTP** for a local `/v1` endpoint, then copy its base URL into your client.
It defaults to `127.0.0.1:11435` with tools disabled. Network bindings require
a bearer key, generated when needed; **Copy API Key** copies it. Enabling agent
tools sends approval requests to the Servers panel. The selected working
directory supplies `pmai.json`, falling back to the global configuration.

Choose **Forwiroh** to share projects and saved chats, or select **Local Network
(ACP)** or **OpenTunnel** for the other `/remote serve` transports. Share all
indexed projects or choose specific folders. **Start Server** shows a QR code
and a pairing link; **New QR Code** renews Forwiroh's single-use, five-minute
invitation. Accept or reject each pending device request, then its separate
chat-access request. The client list distinguishes active connections from
offline credentials. **Revoke** removes access and disconnects that client.
The toolbar and Servers menu indicate pending pairing and tool requests.

Hosting is shared across app windows and continues when its panel is closed.
**Stop Server** or quitting the app closes the listener and its tunnel. Stop
before changing protocols or settings. The app and CLI use the same host
identity and client store, so only one can serve from a given pmai home at a time.

**⌘S** toggles the left sidebar in the active window, also available as
**View → Toggle Sidebar**. **⌘O** toggles the right conversation options sidebar,
also available as **View → Toggle Conversation Details** when a chat is selected.

**⌘+** and **⌘−** resize conversation text, Markdown, and the message composer;
**⌘0** restores the default size. These commands also appear in the View menu.
The chosen size is saved across launches.

The floating composer uses Liquid Glass on macOS 26 and later, with a system
material on macOS 15. It starts at one text row, grows with wrapping or newlines
up to five rows, then scrolls internally. Sending or clearing the draft shrinks
it back to one row. The current model appears in the window title bar; there is
no idle status row below the composer. Disconnected chats offer **Reconnect** in
the toolbar.

The microphone offers **Dictation**, **Voice Conversation**, and **Walkie-talkie**.
Dictation previews recognized speech and adds it to your draft when you finish.
Voice conversation sends after a pause and reads replies aloud; walkie-talkie
waits for an explicit send. Audio uses this Mac's `voice` configuration, including
its language, input/output providers, silence timeout, and speech voice. The app
bundle includes microphone and Speech Recognition privacy descriptions. System
transcription stays on device and requires an installed recognition language.

`/voice` toggles conversation mode. `/voice on`, `off`, `pause`, `resume`, `send`,
`discard`, `realtime`, `walkie-talkie`, and `dictate` also work in the composer.
**Control-Space** records/sends, **Control-T** sends the current voice turn, and
**Control-G** discards it. The **Voice** menu exposes these controls. On current
pmai hosts, voice uses a separate agent with access to the text conversation,
so keyboard work and spoken conversation can run concurrently. Its transcript
is shown in the voice controls and saved with the chat's subagents. Cancelling
voice does not cancel the keyboard task. Older or non-pmai hosts use the current
chat for voice turns and wait until it is idle. Typed drafts and attachments are
preserved when a spoken message is sent. Switching away from the chat stops audio.

Use **(+) → Webxdc Apps…** to import a `.xdc` archive or start an installed app
directly inside the chat. **Hide** retains the running browser; **Open [app]** in
the composer brings it back. **Stop App** closes it. Imports, app revisions, and
status updates live in `$PMAI_HOME/WebXDCApps`; each app has its own persistent
WebKit storage. Importing an identical archive preserves its identity and data.
The archive loader and standard `webxdc.js` bridge are shared with iOS.

Apps run offline. **Chat interaction** forwards app updates to the assistant and
delivers its JSON replies to the app; `sendToChat` queues messages while the chat
is busy. The PocketMai bridge supports native speech and inference with explicit
permissions for the running app. Mac inference currently requires `scope: 'chat'`
and uses that chat's agent; isolated provider selection is not implemented.
Native audio stops when an app is hidden or the chat is closed. File import and
realtime channels inside apps have the same unsupported behavior as the iOS bridge.

Type `/` or `$` at the start of the composer to complete names from the host's
configured prompt catalog and project/global skills. Suggestions open above the
composer and narrow as you type; the arrow keys select a suggestion, Tab inserts
it with a trailing space, and Escape dismisses the list. Clicking a suggestion
also inserts it for further editing. Return still
sends the message. `$name arguments` and `/name arguments` expand through the
shared prompt parser. The inspector's **Agent** selection
uses the configured agent definitions, including their model and instructions.

**Settings** (⌘,) includes Hosts, Providers, MCP Servers, Prompts, and Skills.
Hosts can be paired, edited, or removed without exposing stored credentials.
Provider forms edit endpoints, models, API keys or key references, headers, and
provider-specific options. MCP forms support Streamable HTTP and local stdio
commands, arguments, environment variables, authentication, and tool approvals.
Prompts can be created, edited, or removed; built-in prompts can be customized.
Skills can be created, imported with their supporting files, edited, or removed.

The scope selector chooses the global CLI configuration or a local workspace's
`pmai.json`. The first workspace save copies the global configuration. Later
global changes do not override that file. Saves retain unknown configuration
fields and refuse to overwrite a configuration changed by another editor.
Skill edits retain supporting files and additional front matter. Changes apply
to new conversations; running conversations retain their current runtime.
Remote-host connection profiles are managed locally; these Settings panes do
not modify configuration files on remote servers. Existing CLI OAuth sign-ins
remain shared with the Mac app.

**Connect Host** accepts the same ACP/Forwiroh connection profiles and OpenCode
pairing links as the mobile client. It reads and updates the CLI's remote host
bookmarks. Device approval still happens on the host. New subagent controls need
a host built with the `_pmai/session/agents` extension; older hosts can still chat
and run their existing model-driven delegation tools.

## Reuse and storage

The app links MaiCore, MaiACP, MaiMarkdown, and the CLI runtime. `MaiCLI` is a
library target with a small `MaiCommand` executable entry point. Both CLI and Mac
products reuse those compiled modules within the same SwiftPM build graph.

The app bundle contains one executable. Launched without arguments it runs the
SwiftUI interface; launched with CLI arguments it runs the existing CLI entry
point. Each open local conversation uses that executable as a stdio ACP worker.
This keeps shell tools, plugins, MCP, provider authentication, project settings,
approvals, and agent execution in the established CLI path. Workers do not start
AppKit or windows, and there is no listening network port for local chat.
When reopening a chat, the worker also receives `--resume`, restoring that chat's
saved runtime configuration before providers and tools are registered.

`AgentHomeACPWorkspace` reads and writes the CLI's own chat files. The app honors
`PMAI_HOME`, existing project-local `.pmai` directories, and the normal project
index. It does not import or maintain a second copy of local conversations.
Subagent transcripts are stored in each chat's existing `subagents` field.
The native app stores only window/navigation preferences and unsent drafts in
its defaults. Global configuration is `~/.config/pmai/config.json`; a working
folder's `pmai.json` takes precedence, exactly as in the CLI.

The iOS UIKit view/store hierarchy is not compiled into the Mac product. Its
host → workspace → conversation navigation and disclosure of reasoning/tool
activity are adapted to standard Mac controls. Protocol transcript reduction,
remote connections, pairing, configuration options, Markdown parsing, storage,
and agent orchestration are shared rather than copied.

**Conversation → Open in Terminal** disconnects the app's writer and resumes
the selected chat in the bundled CLI, providing the full REPL command surface.
It uses a new Therm2 instance when installed, otherwise the default application
for `.command` scripts (normally Terminal).
Finish the terminal session before reconnecting the same chat in the app.
As with two CLI processes, concurrently editing the same chat from an unrelated
terminal session should be avoided; CLI and ACP do not share one universal lease.

## Build size and distribution

`make mac` defaults to a lean build without MLX and its tokenizer/model-loading
dependencies. Network providers, ACP providers, and available Apple Foundation
Models remain usable. Use `MAC_MLX=1 make mac` to include MLX. Model weights are
never included in the app bundle. SwiftPM's full dependency lockfile is preserved
when building the smaller graph, and an explicit compilation flag prevents stale
MLX modules from leaking into a lean incremental build.

`make mac CONFIG=Release` produces an optimized, stripped app. Local builds use
ad hoc signing; `MAC_SIGN_IDENTITY` selects a keychain signing identity for both
the app and DMG. For example:

```sh
make mac-dmg MAC_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
```

Packaging verifies both signatures and the
disk image before replacing an existing DMG. The scripts do not notarize or
publish the app. This is a direct-distribution Mac application,
without App Sandbox: CLI-compatible project access, subprocesses, and native
plugins require that execution model.

CI uploads a debug DMG on macOS. Release tags build lean, optimized arm64 and
x64 DMGs, attach them to the GitHub release, and include them in `SHA256SUMS`.
Both the app and DMG are ad hoc signed in CI, without Developer ID or notarization.
Like the unsigned iOS IPA, this keeps builds independent of private Apple
credentials; ad hoc signatures do not establish a trusted developer identity.

The lean arm64 app built with Xcode 27.1 measured approximately 21 MB in Release
and 66 MB in Debug. These are local bundle measurements, not CI size thresholds.

The single-binary packaging avoids duplicating the engine on disk. There is
still one worker process per open conversation, which isolates configuration,
working directories, cancellation, and failures. This trades some memory for
reusing the complete CLI runtime without a second initialization implementation.

## Native design decisions

The interface uses `NavigationSplitView`, a standard sidebar, toolbar, inspector,
Settings scene, menu commands, SF Symbols, selectable text, and native controls.
The system supplies Liquid Glass for navigation and controls; the transcript
uses a solid semantic text background. Tool calls and reasoning are expandable,
and code has horizontal scrolling and a Copy action. System colors and materials
follow appearance and accessibility settings. Streaming follows the bottom only
while the reader is already there; a Latest button returns to new output.

These choices follow Apple's [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos),
[Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars),
and [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
guidance. The Settings window groups related preferences into standard panes,
following Apple's [Settings guidance](https://developer.apple.com/design/human-interface-guidelines/settings).
Apple's [Modernize your AppKit app (WWDC26)](https://developer.apple.com/videos/play/wwdc2026/289/)
explains the macOS 27 sidebar/toolbar refinements, keyboard navigation, and state
restoration. Standard components pick up those refinements without reproducing
glass in every message or requiring private APIs.

## Validation

`python3 test/run-tests.py acp` selects the focused ACP graph. Its regression
coverage includes CLI storage interoperability, scoped subagent management,
durable results, and cancellation using deterministic local providers.

The initial implementation passed all 71 ACP tests and a packaged-worker check
for configured providers/models/agents, prompt and skill discovery, and continuing
an existing CLI chat. Release signing and installation into a temporary
Applications directory were also checked. The existing `repl-resume-smoke.py`
flag-override assertion fails on both the pre-existing CLI binary and the new
bundle. UI capture was unavailable (ScreenCaptureKit capture failure), so visual
and interactive UI verification remains outstanding.

For manual UI verification, use a temporary `PMAI_HOME`, a folder containing a
`pmai.json` configured with the offline `hello` provider, and the built app.
Check chat creation, streaming, reopening, sidebar navigation, settings,
subagent results, keyboard commands, narrow windows, light/dark appearance, and
permission sheets before testing real remote hosts or live models.

The iOS-only camera, widgets, CarPlay, and live voice interfaces are not part of
this Mac interface. Advanced REPL commands remain available through the terminal
handoff; this is not a graphical editor for every CLI configuration field.
