<p align="center">
  <a href="https://trufae.github.io/pmai"><img src="mai-logo.png" alt="PocketMai logo" width="180" /></a>
</p>

# PocketMai + pmai

[Official website](https://trufae.github.io/pmai) · [App Store](https://apps.apple.com/es/app/pocketmai/id6764296742) · [Releases](https://github.com/trufae/pmai/releases) · [CLI guide](MaiCore/README.md)

**Your models. Your tools. Your workstation in your pocket.**

Install the **pmai CLI** on macOS, Linux, or Android:

```sh
curl -fsSL https://raw.githubusercontent.com/trufae/pmai/main/www/install.sh | sh
```

No root needed. The installer selects the release for your platform, verifies its
SHA-256 checksum, and chooses a writable install directory. Update with `pmai -U`.
Linux releases include glibc and fully static musl builds; the installer detects
musl automatically. See the [installer](www/install.sh) for custom install paths
and version selection.

[![CI](https://github.com/trufae/pmai/actions/workflows/ci.yml/badge.svg)](https://github.com/trufae/pmai/actions/workflows/ci.yml)

PocketMai brings a personal AI agent to your phone; pmai brings the same Swift
engine to your terminal. Talk through an idea, work on a codebase, turn a chat
into a document, or pick up a workstation project from your phone. Choose local
inference or a remote provider, give each agent the tools it needs, and keep
your conversations portable.

Built on [MaiCore](MaiCore/README.md), following
[MAI](https://github.com/trufae/mai)'s terminal and Vim workflows.

| Interface | What you get | Get it |
| --- | --- | --- |
| **PocketMai for iOS** | Native voice, tools, documents, mini apps, and remote projects. iOS 18+; some features require newer iOS or supported hardware. | [App Store](https://apps.apple.com/es/app/pocketmai/id6764296742) |
| **pmai CLI** | A terminal agent for macOS, Linux, and Android, with shell tools, projects, skills, MCP, ACP, and Vim integration. | Install command above · [Release downloads](https://github.com/trufae/pmai/releases) |
| **PocketMai for Android** | A native preview with provider/model setup, custom prompts, streaming chat, saved history, and light/dark themes. | [Download APK](https://trufae.github.io/pmai/downloads/PocketMai-Android.apk) · [Android guide](PocketMaiAndroid/README.md) |

The Android app preview has a smaller feature set than iOS: tools, voice,
attachments, MCP, local inference, and remote host navigation are not available
there yet. The Android CLI is a separate terminal client.

## Features

### Make the agent yours

- **Bring your model.** Use Apple Intelligence or MLX on supported Apple hardware,
  sign in with a ChatGPT subscription, or connect an OpenAI-compatible API such
  as OpenAI, Ollama, llama.cpp, vLLM, or OpenRouter. Native tool calling and text,
  XML, and JSON fallbacks accommodate different providers.
- **Build your own team.** Save prompts, create or import `SKILL.md` skills, and
  give agents their own models and tools. Inspect subagent transcripts and usage,
  send guidance, pause or resume work, and stop a branch. Choose separate models
  for chat, compaction, tool decisions, and approval review.
- **Set the boundaries.** Choose tools per agent and MCP server, set file and
  folder rules to allow, ask, or deny, and review or edit tool arguments before
  execution. Configure manual or model-assisted approval and limits on turns,
  tool calls, tokens, elapsed time, and subagents.
- **Connect your tools and agents.** Add Streamable HTTP MCP servers, plus local
  stdio servers and native plugins in supported CLI builds. Use ACP agents as
  providers or subagents, serve pmai to an ACP editor with `pmai --acp`, or expose
  its configured agent to an MCP client with `pmai --mcp`. The
  [tool proxy](doc/proxy.md) controls discovery and reduces tool-schema overhead.

### Move between phone and terminal

- **Take your workstation with you.** Pair PocketMai or another pmai CLI with a
  running host to continue saved chats, switch projects, and browse or transfer
  files. Connect over your LAN or use encrypted OpenTunnel access across
  firewalls, with pairing approved on the host.
- **Stay in your coding flow.** Pipe context into pmai, run shell tools for builds,
  tests, and Git, or hand the terminal over to an interactive program. Install the
  [Vim integration](doc/vim.md) to review and apply changes to a selection.
- **Keep the whole conversation.** Organize chats by project, search past work,
  and carry persistent memory and todos forward. Share a `.pocketmai` file with
  attachments, tool messages, and nested subagent chats, then continue on another
  device using its own provider credentials.
- **Shape the context.** Edit, undo, trim, search, or compact a conversation with
  a focus. Ask `/btw QUESTION` alongside a running reply in iOS or the interactive
  CLI; it uses a fresh context without changing the main conversation.

### Put it to work

- **Files and local knowledge — iOS + CLI.** Read, search, write, and patch files
  within your configured workspace. Index documents and source with `vdb` to
  retrieve passages with file and line references; default retrieval runs locally
  without an embedding-model download. On iOS, browse, preview, and edit local
  or remote files, create folders, and upload or download documents.
- **Research and everyday tools — iOS + CLI.** Search the web, including through
  your own SearXNG instance, fetch readable pages, and download files. Browse
  GitHub repositories, PR diffs, issues, releases, and CI logs with read-only
  tools. Check weather, calculate, or search Mastodon and enable posting when
  needed.
- **Documents in, documents out — iOS + CLI.** Import text, source, HTML,
  Markdown, DOCX, EPUB, JSON, and PDF; export conversations to Word, EPUB,
  Markdown, HTML, plain text, or JSON. Use local Apple Vision OCR on iOS and
  macOS, or installed Tesseract on other CLI platforms. On iOS, attach PDF pages
  as images and read scans with OCR.
- **Talk naturally — iOS.** Speak a question, listen to replies, or import a
  voice note, including Ogg Opus. Transcription stays on device by default;
  choose a local model and device voice for offline conversations. Enable
  Voiceover for short spoken summaries of finished replies. Native live
  transcription requires iOS 26+ and an installed speech model. The share sheet
  accepts pictures, audio, and documents from other apps.
- **A browser you can take over — iOS.** Let the agent read text, DOM, links, or
  OCR from a floating WebKit browser, then click, type, scroll, or run JavaScript.
  Enlarge its picture-in-picture card and take over for sign-ins or any other step.
- **Make little apps — iOS.** Create and run WebXDC mini apps with HTML, CSS, and
  JavaScript inside the chat. Keep revisions, roll back changes, and share `.xdc`
  files for PocketMai or Delta Chat. The runner blocks network access.
- **Use your device — iOS.** Read your calendar and optionally create events,
  use device location, and set countdowns or one-time and repeating alarms
  (iOS 26.1+). Follow replies and tool calls through Lock Screen and Dynamic
  Island Live Activities, receive background completion and approval
  notifications, and optionally keep long replies working when the screen locks.

Offline use depends on selecting a local model and local tools; remote providers
still need a connection. CLI Airplane Mode limits tools, not the inference
provider. File-tool rules enforce workspace boundaries; CLI shell commands run
with the pmai process's privileges and their own approval rules.

## Start in the terminal

Run `pmai`, add your provider, and choose a model. For a local Ollama server
already running with a downloaded model:

```text
/provider add local http://127.0.0.1:11434/v1
/models local
/model local::MODEL_FROM_THE_LIST
```

The selection is saved for future runs. You can also use
[ChatGPT sign-in](#use-your-chatgpt-subscription), a remote API, or native
[Apple Intelligence and MLX providers](MaiCore/README.md).

```sh
pmai "explain this project"
git diff | pmai --stdin "review this change"
pmai --vim install
```

In Vim, select lines and press `m` to choose a prompt, review the reply, and apply
it. Use `pmai --vim update` to refresh the integration or `pmai --vim uninstall`
to remove it. In the REPL, try `/projects` and `/help`.

## Bring your workstation to your phone

In the host's pmai REPL, share a project on your local network:

```text
/remote serve --path /path/to/project
```

In PocketMai, open **Hosts → Add Remote Host**, scan the pairing QR or paste the
connection URI, save it, and select the host. Accept the request on the host with
`/remote accept`, then browse its projects, continue a chat, or open its files.
The serving REPL stays usable; `/remote stop` or exiting it ends the server.

For access across firewalls, install the OpenTunnel CLI on the host and use
`/remote serve --protocol opentunnel --path /path/to/project`. For encrypted device pairing without
an external tunnel command, use `/remote serve --protocol forwiroh --path /path/to/project`.
Scan the connection QR in PocketMai, paste its URI in Android's **Hosts** tab,
or run `/remote pair '<URI>'` on another CLI. Approve the Forwiroh device request
and then the ACP chat request with `/remote accept`. Saved hosts reconnect
without scanning again; `/remote qr` creates a fresh five-minute invitation for
another device. Forwiroh grants access only to pmai's loopback ACP endpoint.

Forwiroh [0.1.1](https://github.com/trufae/forwiroh/releases/tag/v0.1.1) is supplied as a prebuilt SwiftPM dependency under `Vendor/Forwiroh`:
no Rust build or wrapper generation is needed. Its release binaries support
macOS, iOS, Linux and Android. Linux glibc binaries require Ubuntu 24.04/glibc
2.39 or newer; musl builds use the musl variants. The source package requires
Swift 6.2 or newer (Android uses the project's matching Swift 6.4 SDK).
Windows keeps direct ACP connections; Forwiroh has no Windows binary yet. See
[remote pmai hosts](MaiCore/README.md#remote-pmai-hosts) for setup and connection
options, and [file browsing over ACP](doc/acp.md#file-browsing-from-pocketmai).

## Guides

- [CLI setup and command reference](MaiCore/README.md)
- [Providers, agents, and task defaults](doc/task-agents.md)
- [Reusable prompts and skills](doc/prompts.md)
- [Editing configuration and conversation context](doc/edit.md)
- [ACP and MCP integration](doc/acp.md) · [Tool proxy](doc/proxy.md)
- [Vim integration](doc/vim.md) · [Android builds](PocketMaiAndroid/README.md)
- [Voice setup and privacy](#voice-setup-and-privacy) · [Build from source](#build)

## Use your ChatGPT subscription

In iOS Settings → Providers, add a provider, choose **ChatGPT subscription** in
the API picker, then tap **Continue with ChatGPT**. Select an available model
after signing in. Add separate providers for different accounts or workspaces.

In the pmai CLI REPL:

```text
/provider add chatgpt --kind chatgpt
/provider login chatgpt
/models chatgpt
/model chatgpt::MODEL_FROM_THE_LIST
```

The provider kind is `chatgpt`. API-key connections use `openai`; existing JSON
using `openAICompatible` still loads and is saved with the new name.
Eligible requests use your ChatGPT plan through
the Responses API; no API key or Codex CLI is needed. Plan limits and account
eligibility apply. [Manage usage](https://chatgpt.com/settings/usage).
Use `/provider status chatgpt` to inspect the account and `/provider logout chatgpt`
to sign out. Credentials stay in the iOS device's Keychain or owner-only files
under `$PMAI_HOME/chatgpt` (`~/.pmai/chatgpt` by default); provider exports do not
include them. Sign in independently on each device. This provider supports text,
images, files, and pmai tools; audio and hosted Responses tools are unavailable.

## Share a conversation between devices

Tap the chat title, or long-press a chat in the left sidebar, then choose
**Share...** and **AirDrop** or **Mail**. This sends a `.pocketmai`
conversation file. Open the received file
with PocketMai, choose its destination folder, and import it to continue chatting.
On a computer, import the very same file in pmai:

```text
/import ~/Downloads/My Chat.pocketmai
```

The file keeps the conversation and its embedded attachments, including tool
messages and nested subagent chats. It does not add the diagnostic report or
export your provider credentials. The receiving device uses its own configured
providers. Older `.pocketmai.json` conversation files remain importable; to send
to an older PocketMai version, rename the file to end in `.pocketmai.json`.

**Export...** offers readable copies such as Plain Text (.txt), Markdown, HTML and
Word. **Debug Report** is for troubleshooting; it is not needed to transfer a chat.

## Voice setup and privacy

Use device voices or configure a speech provider independently of your chat
model. Audio transcription stays on device by default; the resulting chat text
goes to your selected model provider.

<details>
<summary>Configure OpenAI or compatible text-to-speech</summary>

### OpenAI text-to-speech

ChatGPT subscription sign-in provides the Responses API connection; it does not
provide Speech API access. Keep ChatGPT selected for chat and configure a separate
speech provider below. OpenAI speech requires an API key and separate API billing.
See the [ChatGPT plan endpoint contract](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference).

1. Open **Settings > Voices > Assistant** (or **User**). **Browse Built-in Voices**
   lists OpenAI voices even before you configure a provider. Tap **Add OpenAI Speech
   Provider**, or use **Settings > Providers > Add Provider**, choose **OpenAI API**,
   set the base URL to `https://api.openai.com/v1`, and save your API key using
   the provider's existing credentials form. Enable the provider. Adding it from
   Voices selects it for that role without changing your chat provider.
2. Open **Settings > Voices > Assistant** (or **User**) and select that provider.
   Its built-in voices are available immediately, without voice discovery.
3. Leave **Speech Model** at its `gpt-4o-mini-tts` default, or choose a supported
   TTS model, then select a **Voice**. The speech model is shared by roles using
   that provider and is independent of its chat model.
4. Tap **Test Voice** for a paid preview. **Speak Message**, **Speak From Here**,
   live conversation replies, and the `speak` tool use these same settings.

Long messages are divided into bounded requests and played through the existing
speech queue. Pausing while synthesis is pending keeps the returned audio paused.

These are AI-generated voices. OpenAI documents 13 voices for `gpt-4o-mini-tts`;
`tts-1` and `tts-1-hd` support a smaller set. Unsupported selections show an
error without switching voices. Compatible servers are selectable before discovery
and load `/voices` when selected. **Refresh Voices** reports discovery failures;
you can also enter a **Voice ID** manually for servers without a voice catalog.
Switching providers chooses an available voice instead of carrying an unsupported
voice from the previous provider. Returning from System preserves the saved voice.
Compatible servers retain custom speech model names; a blank speech model uses
their server default.
Existing compatible-provider configurations keep their previous synthesis model
when migrated. Airplane Mode retains the existing system-voice behavior.
See the [official TTS guide](https://developers.openai.com/api/docs/guides/text-to-speech).

As of October 17, 2026, OpenAI has announced retirement of `tts-1`, `tts-1-hd`
and the dated `gpt-4o-mini-tts` models on January 6, 2027. See
[OpenAI's deprecation notice](https://developers.openai.com/api/docs/deprecations#2026-10-01-text-to-speech-models).
Realtime speech is outside this integration.

</details>

<details>
<summary>On-device transcription, live voice, and server fallback</summary>

### Voice privacy

Voice recordings and imported audio stay on device for transcription by default.
Settings > Voices > **Allow Apple Server Transcription** explicitly permits an
Apple-server fallback if local recognition fails or is unavailable. The app's
airplane button overrides this permission immediately and cancels active server
recognition. Returning online restores the saved preference.

On iOS 26+, file transcription first tries `SpeechAnalyzer` / `SpeechTranscriber`
with an already-installed language model. The fallback on iOS 26+ and the primary
path on iOS 18–25 use `SFSpeechRecognizer`, checking `supportsOnDeviceRecognition`
before setting `requiresOnDeviceRecognition = true`. Without the server opt-in,
missing local support or recognition errors never trigger a server request.
Native iOS Live always uses the on-device analyzer and requires an installed model.
PocketMai does not initiate speech-model downloads.

Apple documents the guarantees in
[Asking Permission to Use Speech Recognition](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition),
[`requiresOnDeviceRecognition`](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)
and [`supportsOnDeviceRecognition`](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition).
This setting controls audio transcription; sending the resulting text to a chat
still uses that chat's selected model provider.

</details>

## Build

Build the iOS app with Xcode, the CLI with SwiftPM through Make, or the native
Android preview with `make android`. See the [Android guide](PocketMaiAndroid/README.md)
for its SDK and toolchain setup.

<details>
<summary>Requirements, build commands, and local inference notes</summary>

Requires Xcode 26+ and an iOS 18+ deployment target. iOS 26-only features
such as Apple Foundation Models, Native iOS Live speech transcription, and
Liquid Glass controls fall back or report unavailable at runtime on older OS
versions.

MLX inference requires a physical device with Apple GPU family 7 or later
(A14/M1 or newer). PocketMai checks `MTLDevice.supportsFamily(.apple7)` before
enabling MLX selection, downloading, or loading models. The iPhone XS's A12,
A13 devices, and A12X/A12Z iPads do not meet this requirement. These devices
can use an OpenAI-compatible service or connect to Ollama/llama.cpp on a computer
through Settings > Providers > Add Provider.

This GPU cutoff follows the SIMD-group matrix operations used by
[MLX's Metal kernels](https://github.com/ml-explore/mlx/blob/v0.31.1/mlx/backend/metal/kernels/steel/gemm/mma.h)
and [Apple's GPU feature table](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf).
The [MLX iOS guide](https://github.com/ml-explore/mlx-swift/blob/0.31.6/Source/MLX/Documentation.docc/Articles/running-on-ios.md)
also rules out Simulator inference and describes iOS memory limits. Simulator
builds support the UI and remote providers; test MLX on a supported device or
an Apple silicon Mac using Designed for iPad. GPU support does not guarantee
every model fits in memory: start with a small 4-bit model and a short context,
and keep the app in the foreground while generating.

The project pins `mlx-swift` 0.31.6 (includes the iOS build fix) and
`mlx-swift-lm` 3.31.4.

CI and release builds use Swift 6.4.0, including matching Static Linux and
Android SDKs. The packages keep Swift 6 language mode. SwiftPM now defaults
to Swift Build; use `swift build --package-path MaiCore --show-bin-path`
(with the same build system, configuration and SDK arguments) to locate binaries.
Android uses `--build-system native` and the SDK's `setup-android-sdk.sh` to
avoid a Swift Build 6.4 planner crash on Linux. CI exercises the optimized
Android release build and musl x64 networking/no-AVX checks; other CI builds
use debug configurations. Release tags build the optimized distribution
artifacts in the Release workflow.

```sh
make build               # builds for the iOS Simulator without code signing
make repl-build          # builds the debug CLI without starting the REPL
make repl-install        # installs an unoptimized CLI without debug information
make run                 # installs and launches Xcode's latest signed device build
make fmt                 # swift-format the sources
```

The CLI and iOS app reuse `MaiLocalProviders` for Apple Intelligence and MLX.
On macOS, add a native provider with `/provider add apple --kind apple` or
`/provider add mlx --kind mlx`, then `/model apple::on-device` or
`/model mlx::LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit`; no server URL is needed.
`make repl-build` includes the CLI's MLX Metal resource. See
[native provider setup](MaiCore/README.md) for requirements and configuration.
`make repl-install` builds incrementally with `-c debug -debug-info-format none`
and installs that executable and its MLX resource to `~/.local/bin` (or `BINDIR`).

Local builds reuse their existing outputs. Xcode compilation caching is
enabled, and Make's command-line builds skip editor indexing, coverage
instrumentation, and remote package update checks. The default Debug
Simulator build compiles only the host Mac's architecture; Release
builds keep their full architecture set. Keep the same toolchain and build
options between invocations; use `make clean` only when you need to discard
iOS build outputs. Set `XCODE_ARCH_FLAGS=`, `XCODE_BUILD_FLAGS=`, or
`SWIFT_BUILD_FLAGS=` to override the command-line defaults.
To check package remotes again, run
`make build XCODE_PACKAGE_FLAGS=-skipPackagePluginValidation`.

`make run` selects the first connected iOS device and uses the latest signed
`Debug` device app in Xcode's Derived Data. Use `make run DEVICE=<UDID>` to
select a specific device, or `make run APP_BUNDLE=<path>` to select an app
bundle. Build in Xcode first after source changes; this preserves Xcode's
private-key access for code signing. Open `PocketMai.xcodeproj` when you need
debugger attachment or to run in the Simulator.

</details>

## Releases

Get PocketMai from the [App Store](https://apps.apple.com/es/app/pocketmai/id6764296742).
The [GitHub releases](https://github.com/trufae/pmai/releases) include the iOS IPA,
source archives, and pmai CLI binaries for macOS and Linux (arm64 and x64), plus
Android arm64. Static musl builds omit native plugin loading.

The website's [Android APK](https://trufae.github.io/pmai/downloads/PocketMai-Android.apk)
is the latest successful main-branch development build, with arm64 and x86_64
support. Its [SHA-256 checksum](https://trufae.github.io/pmai/downloads/PocketMai-Android.apk.sha256)
is published alongside it. Updating debug builds may require reinstalling.

—pancake
