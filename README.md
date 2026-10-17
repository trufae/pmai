<p align="center">

[Providers, agents, and task defaults](doc/task-agents.md) explains configuring separate models for compaction and tool decisions in PocketMai and pmai.

  <img src="mai-logo.png" alt="MAI logo" width="300" />
</p>

# PocketMai

[![CI](https://github.com/trufae/pocketmai/actions/workflows/ci.yml/badge.svg)](https://github.com/trufae/pocketmai/actions/workflows/ci.yml)

A native iOS chat client for talking to LLMs — Apple's on-device Foundation Models and any OpenAI-compatible HTTP endpoint.

This app, comes after [MAI](https://github.com/trufae/mai), a cli agent with focus on batch/prompt/cli workflows that also integrates well with VIM editor.

## Features

- **Providers**: Apple Intelligence and MLX on supported devices, ChatGPT subscription sign-in, plus any OpenAI-compatible API (OpenAI, Ollama, llama.cpp, vLLM, OpenRouter, ...).
- **Tools**: datetime, location, weather, web search, browser, todo, text-to-speech, files, local documentation (`vdb`), memory — invokable by the model via native tool-calling or a text-protocol fallback.
- **File manager**: browse local working folders and remote projects, copy paths, preview files, create folders, and upload or download files. Open **Files…** from the chat title menu, or long-press a folder and choose **Browse Files…**. See [file browsing over ACP](doc/acp.md#file-browsing-from-pocketmai).
- **Browser**: the model can open pages in an in-app WebKit view shown as a picture-in-picture card, read the text, DOM, links, or an on-device text-recognition pass over the screen, click, type, scroll, and run JavaScript. Tap the card to enlarge it and take over by hand for sign-ins and other steps only a person can do.
- **MCP**: configure remote Streamable HTTP or CLI-local stdio servers and surface them to the model.
- **Multiple system prompts**, persistent conversations, export to Markdown / HTML / plain text / JSON / ePUB / Word (docx).
- **Side questions**: `/btw QUESTION` starts immediately alongside a running reply in the iOS app and interactive CLI. It uses a fresh context with the current profile and tools. In iOS, answers appear in temporary cards with independent Stop and Dismiss controls; chat history and pending attachments stay unchanged.
- **Attachments**: arbitrary text and source files plus HTML, Markdown, Word (docx), EPUB, JSON and PDF. HTML asks whether to keep its source, convert it to Markdown, or copy it to the chat's working folder; Word, EPUB and PDF are converted to Markdown on device (PDFs can also be attached as one image per page, and scanned pages are read with Vision OCR).
- **Share sheet**: send pictures, voice messages and documents to PocketMai from WhatsApp, Telegram, Photos, Files or any other app. Voice messages are transcribed on device by default (Ogg Opus included), documents are converted to text, and pictures ask for their size or for OCR just like when they are attached inside the app.
- **Background replies**: a Live Activity on the Lock Screen and in the Dynamic Island follows running replies and tool calls, and a local notification tells you when a reply finishes, fails, or needs a tool approval while the app is in the background. An optional "Keep working when locked" mode keeps long replies running after the screen locks.

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

## OpenAI text-to-speech

1. Open **Settings > Providers > Add Provider**, choose **OpenAI API**,
   set the base URL to `https://api.openai.com/v1`, and save your API key using
   the provider's existing credentials form. Enable the provider.
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
error without switching voices. Compatible servers retain `/voices` discovery
and custom speech model names; a blank speech model uses their server default.
Existing compatible-provider configurations keep their previous synthesis model
when migrated. Airplane Mode retains the existing system-voice behavior.
See the [official TTS guide](https://developers.openai.com/api/docs/guides/text-to-speech).

As of October 17, 2026, OpenAI has announced retirement of `tts-1`, `tts-1-hd`
and the dated `gpt-4o-mini-tts` models on January 6, 2027. See
[OpenAI's deprecation notice](https://developers.openai.com/api/docs/deprecations#2026-10-01-text-to-speech-models).
Realtime speech is outside this integration.

## Voice privacy

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

## Build

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

As of 2026-09-24, the project already resolves the latest stable releases:
`mlx-swift` 0.31.6 (includes the iOS build fix) and `mlx-swift-lm` 3.31.4.

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

## Releases

A basic [Android app](PocketMaiAndroid/README.md) is also available from source:
provider setup, model listing, system prompts, streaming chat, and saved history.
Its application code and UI are Swift, using MaiCore and the AndroidSwiftUI
runtime. Build it with `make android` using the matching Swift 6.4 Android SDK.

Ready to use from the [AppStore](https://apps.apple.com/es/app/pocketmai/id6764296742)

But you may find the ipa and source zips in the [Release](https://github.com/trufae/pocketmai/releases) page.

The `pmai` CLI ships there for macOS, Linux, and Android. Linux comes as a
glibc build and as a fully static `-musl` build that runs on Alpine and other
musl distributions; `www/install.sh` picks the right one automatically.

Install the bundled [Vim integration](doc/vim.md) with `pmai --vim install`.
Use `pmai --vim update` to refresh it and `pmai --vim uninstall` to remove it.
Select lines and press `m` to send them to pmai, review the reply, and apply it.

—pancake
