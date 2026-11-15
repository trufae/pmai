[![CI](https://github.com/trufae/pmai/actions/workflows/ci.yml/badge.svg)](https://github.com/trufae/pmai/actions/workflows/ci.yml)

<p align="center">
  <a href="https://trufae.github.io/pmai"><img src="mai-logo.png" alt="PocketMai logo" width="140" /></a>
</p>

# pmai + PocketMai

**A personal AI agent for your terminal, desktop, and phone.**

pmai is a terminal agent that can work on code, run tools, research, and create
documents. PocketMai brings the same Swift engine to native apps. Choose your
model, keep conversations by project, and use your workstation from your phone.

[Website](https://trufae.github.io/pmai) · [Releases](https://github.com/trufae/pmai/releases) · [Documentation](doc/README.md)

- **Your choice of model.** Connect OpenAI-compatible services such as Ollama,
  llama.cpp, vLLM, and OpenRouter, sign in with ChatGPT, or run Apple Intelligence
  and MLX locally on supported Apple hardware.
- **Your workstation on your phone.** Share projects, chats, files, and terminals
  over encrypted Iroh connections through built-in Forwiroh. Pair with a QR code
  and approve access on the host; no separate tunnel command is needed.
- **Project boxes.** Run agents and their tools in Docker or Podman containers
  with a separate Git checkout. Review the diff and explicitly apply changes
  back to your project.
- **Tools and agents you control.** Use skills, MCP tools, ACP agents, and
  subagents with their own models and tools. Set approvals and run limits, or
  expose pmai itself to an ACP editor or MCP client.
- **One workflow across devices.** Keep project memory and todos, transfer chats
  with attachments and subagent history, use Vim and shell pipelines, or speak
  to PocketMai and build WebXDC mini apps in chat.

## Platforms

| Interface | Platforms | Get it |
| --- | --- | --- |
| **pmai CLI** | macOS, Linux, Windows (beta), Android/Termux | [Install below](#install) · [CLI guide](MaiCore/README.md) |
| **pmai for Mac** | Native macOS app | [Releases](https://github.com/trufae/pmai/releases) · [Build guide](doc/mac-app.md) |
| **PocketMai for iOS** | iPhone and iPad, iOS 18+ | [App Store](https://apps.apple.com/es/app/pocketmai/id6764296742) |
| **PocketMai for Android** | Native Kotlin/Compose app, arm64 | [Download APK](https://trufae.github.io/pmai/downloads/PocketMai-Android.apk) · [Android guide](PocketMaiKotlin/README.md) |

Local models and device features depend on OS and hardware support. See the
[feature guide](doc/features.md) and [build requirements](doc/build.md).

## Install

macOS, Linux, or Android/Termux:

```sh
curl -fsSL https://raw.githubusercontent.com/trufae/pmai/main/www/install.sh | sh
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/trufae/pmai/main/www/install.ps1 | iex
```

The installers verify checksums and need no administrator privileges. Update
with `pmai -U`. Run `pmai` to configure a provider and choose a model; see
[getting started](doc/getting-started.md) for Ollama, ChatGPT, and other providers.

## Three quick commands

**Run a prompt** with your configured model, from a project directory:

```sh
pmai "explain this project"
```

**Serve this project over Iroh.** Enter this inside the `pmai` REPL, then scan the
QR in PocketMai's **Hosts** screen and approve pairing on the host:

```text
/remote serve --path .
```

Forwiroh is the default transport. See [remote hosts](doc/remote-hosts.md) for
pairing, remote terminals, and LAN access.

**Work in a project box** from a Git checkout on macOS or Linux with Docker or
Podman running:

```sh
pmai box create --share-home && pmai "review this project"
```

`--share-home` shares your pmai settings, credentials, and chats with the box.
The box starts from committed HEAD; review with `pmai box diff` and import with
`pmai box apply`. See [boxes](doc/boxes.md) for private homes and container options.

## Learn more

- [Install, providers, and terminal setup](doc/getting-started.md) · [CLI reference](MaiCore/README.md)
- [Remote hosts and Iroh pairing](doc/remote-hosts.md) · [Project boxes](doc/boxes.md)
- [Features](doc/features.md) · [PocketMai voice, sharing, and CarPlay](doc/pocketmai.md)
- [Build and releases](doc/build.md) · [All documentation](doc/README.md)

Built on [MaiCore](MaiCore/README.md), following
[MAI](https://github.com/trufae/mai)'s terminal and Vim workflows.

—pancake
