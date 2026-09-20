<p align="center">
  <img src="mai-logo.png" alt="MAI logo" width="300" />
</p>

# PocketMai

[![CI](https://github.com/trufae/pocketmai/actions/workflows/ci.yml/badge.svg)](https://github.com/trufae/pocketmai/actions/workflows/ci.yml)

A native iOS chat client for talking to LLMs — Apple's on-device Foundation Models and any OpenAI-compatible HTTP endpoint.

This app, comes after [MAI](https://github.com/trufae/mai), a cli agent with focus on batch/prompt/cli workflows that also integrates well with VIM editor.

## Features

- **Providers**: Apple Intelligence (on-device) and any OpenAI-compatible API (OpenAI, Ollama, llama.cpp, vLLM, OpenRouter, ...).
- **Tools**: datetime, location, weather, web search, browser, todo, text-to-speech, files, memory — invokable by the model via native tool-calling or a text-protocol fallback.
- **Browser**: the model can open pages in an in-app WebKit view shown as a picture-in-picture card, read the text, DOM, links, or an on-device text-recognition pass over the screen, click, type, scroll, and run JavaScript. Tap the card to enlarge it and take over by hand for sign-ins and other steps only a person can do.
- **MCP**: configure remote Streamable HTTP or CLI-local stdio servers and surface them to the model.
- **Multiple system prompts**, persistent conversations, export to Markdown / HTML / plain text / JSON / ePUB / Word (docx).
- **Attachments**: arbitrary text and source files plus HTML, Markdown, Word (docx), EPUB, JSON and PDF. HTML asks whether to keep its source, convert it to Markdown, or copy it to the chat's working folder; Word, EPUB and PDF are converted to Markdown on device (PDFs can also be attached as one image per page, and scanned pages are read with Vision OCR).
- **Share sheet**: send pictures, voice messages and documents to PocketMai from WhatsApp, Telegram, Photos, Files or any other app. Voice messages are transcribed on device (Ogg Opus included), documents are converted to text, and pictures ask for their size or for OCR just like when they are attached inside the app.
- **Background replies**: a Live Activity on the Lock Screen and in the Dynamic Island follows running replies and tool calls, and a local notification tells you when a reply finishes, fails, or needs a tool approval while the app is in the background. An optional "Keep working when locked" mode keeps long replies running after the screen locks.

## Build

Requires Xcode 26+ and an iOS 18+ deployment target. iOS 26-only features
such as Apple Foundation Models, Native iOS Live speech transcription, and
Liquid Glass controls fall back or report unavailable at runtime on older OS
versions.

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
make run                 # installs and launches Xcode's latest signed device build
make fmt                 # swift-format the sources
```

`make run` selects the first connected iOS device and uses the latest signed
`Debug` device app in Xcode's Derived Data. Use `make run DEVICE=<UDID>` to
select a specific device, or `make run APP_BUNDLE=<path>` to select an app
bundle. Build in Xcode first after source changes; this preserves Xcode's
private-key access for code signing. Open `PocketMai.xcodeproj` when you need
debugger attachment or to run in the Simulator.

## Releases

Ready to use from the [AppStore](https://apps.apple.com/es/app/pocketmai/id6764296742)

But you may find the ipa and source zips in the [Release](https://github.com/trufae/pocketmai/releases) page.

The `pmai` CLI ships there for macOS, Linux, and Android. Linux comes as a
glibc build and as a fully static `-musl` build that runs on Alpine and other
musl distributions; `www/install.sh` picks the right one automatically.

—pancake
