[Documentation](README.md) · [Project home](../README.md)

# Bring your workstation to your phone

Forwiroh is pmai's built-in Iroh transport. In the host's pmai REPL, share a
project with:

```text
/remote serve --path /path/to/project
```

In PocketMai, open **Hosts → +**, choose **pmai**, tap **Scan Host QR**, name the
host, and tap **Add**. Manual import and connection fields are under **Advanced**.
Approve the Forwiroh device request
and then the ACP chat request on the host with `/remote accept`, then browse its
projects, continue a chat, or open its files.
The serving REPL stays usable; `/remote stop` or exiting it ends the server.

Forwiroh is the default and needs no external tunnel command. For direct LAN
access, use `/remote serve --protocol local --path /path/to/project`. To use
OpenTunnel, install its CLI on the host and run
`/remote serve --protocol opentunnel --path /path/to/project`.
Scan the connection QR in PocketMai, paste its URI in Android's **Hosts** tab,
or run `/remote pair '<URI>'` on another CLI. Saved hosts reconnect
without scanning again; `/remote qr` creates a fresh five-minute invitation for
another device. Forwiroh grants access only to pmai's loopback ACP endpoint.

## Remote files and commands

CLI users can use `/remote ls HOST`, `/remote get HOST REMOTE [LOCAL]`,
`/remote put HOST LOCAL [REMOTE]`, and `/remote run HOST COMMAND` for files and
commands on paired pmai or OpenCode hosts. `/remote shell HOST` sends typed
commands directly to that host until `exit`. See `/help remote` for pairing and
path examples.

## Persistent iOS terminals

PocketMai's iOS terminal uses SwiftTerm with a persistent Unix PTY on updated
pmai hosts, including Forwiroh connections. It supports interactive programs
such as Vim, pinch font sizing, a keyboard control bar, and separate terminal
sessions selected through the `…` menu. Done detaches the panel; Close Terminal
ends that shell. Sessions reconnect after an app restart or network loss while
the host's pmai server stays running.
Use `/set limits.terminalTimeout 3m20s` (or `1h20m`, or plain seconds) on the host
to expire terminals with no input or output; `0` (the default) keeps them until explicitly closed.
Older pmai hosts and OpenCode use command mode instead: each
command starts in the selected workspace. SwiftTerm is an iOS app dependency;
it is not linked into the CLI or Android clients. Open a terminal from a host's
long-press menu or a remote workspace. Add Host offers PocketMai, WebSocketACP,
and OpenCode; WebSocketACP includes a local gateway command and QR setup hint.

## Let an agent use a remote host

To let a local conversation work on a remote host, edit that host and enable
**Allow Remote Tool**, then enable the native **Remote Hosts** tool in the
conversation. On the CLI, use `/remote tools HOST on` and enable the `remote`
tool group with `/tools`. The `remote_hosts`, `remote_files`, `remote_run`, and
`remote_terminal` tools access only hosts you have explicitly enabled. Turning
host access off prevents subsequent calls and closes its agent terminals;
ordinary tool approvals and the remote host's permissions still apply.

## Transport dependency

Forwiroh [0.1.6](https://github.com/trufae/forwiroh/releases/tag/v0.1.6) is supplied as a prebuilt SwiftPM dependency under `Vendor/Forwiroh`:
no Rust build or wrapper generation is needed. Its release binaries support
macOS, iOS, Linux, Android and Windows (x64/ARM64). Linux glibc binaries require Ubuntu 24.04/glibc
2.39 or newer; musl builds use the musl variants. The source package requires
Swift 6.2 or newer (Android and Windows use the project's matching Swift 6.4 SDK). See
[remote pmai hosts](../MaiCore/README.md#remote-pmai-hosts) for setup and connection
options, and [file browsing over ACP](acp.md#file-browsing-from-pocketmai).
