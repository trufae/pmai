# Remote ACP agents: WebSocket and optional Tailcat

pmai exposes agents through [ACP](https://agentclientprotocol.com/). The
WebSocket gateway works without Tailcat and can wrap any agent that speaks ACP
on stdin/stdout. PocketMai uses Apple's URLSession WebSocket client and the
existing MaiACP module; it does not embed Go or a third-party networking library.

[Tailcat](https://github.com/tailscale/tailcat) is an optional encrypted stream
transport between hosts. It is not an HTTP server. pmai invokes the installed
`tailcat` executable; it does not implement Tailcat's transport, encryption,
relay discovery, or wire protocol.

```text
Without Tailcat:
  PocketMai ── WebSocket ── pmai acp-gateway ── stdio ── pmai --acp
                                                        (or another ACP agent)

With Tailcat:
  PocketMai ── WebSocket ── pmai acp-gateway
                              │ stdio
                         pmai tailcat connect workstation
                              │ installed tailcat executable
                              │ encrypted Tailcat stream
                         pmai tailcat serve ── stdio ── pmai --acp
```

The gateway must be reachable from the phone. Tailcat connects the gateway host
to a worker; it does not make the phone a Tailcat node. Use WSS behind a TLS
reverse proxy for an Internet-facing gateway, or WS on a trusted private network.
The gateway itself listens for HTTP WebSocket upgrades at `/acp` and does not
terminate TLS. This implementation provides stdio and WebSocket transports, not
a separate raw TCP listener.

## Start from the REPL

```text
/remote serve
```

This starts an authenticated server in the background, chooses the machine's LAN
address, and prints a pairing QR. The REPL remains usable; `/remote stop` or
exiting the REPL stops the listener. By default it exposes every working directory
in `~/.pmai/projects.json` (or the configured pmai home), with the conversations
stored in each project's `.pmai/chats`. `/remote qr` shows the invitation again.
Run `/remote stop` before starting it with different paths or options.

Scan it in PocketMai → Hosts, or pair it from another CLI:

```text
/remote pair CONNECTION_URI_OR_QR_FILE
```

The serving REPL displays the client's name, address, and request code. Accept it
there with `/remote accept` (or `/remote accept CODE` if several requests are
waiting). `/remote reject` denies it. Until acceptance, the invitation can only
request pairing: it cannot initialize ACP, read chats, or start an agent process.
Acceptance issues a separate private credential for that client. The phone stores
it in Keychain; CLI clients store it in a mode-0600 token file. Reconnection uses
this credential without asking again. `/remote clients` lists accepted clients;
`/remote del CLIENT_ID` removes their access, including active connections.

After the server accepts a CLI client:

```text
/remote connect HOST_NAME
/remote disconnect
```

Connecting creates a separate local chat backed by the remote agent. The earlier
local conversation is preserved; disconnect returns to it. Saved remote chats
can be reopened with `/chat use` or `--resume`, and restore their remote session
across CLI restarts. Remote tools use the normal REPL approval flow.

Optional path restrictions accept multiple directories:

```text
/remote serve --path ~/prg/one ~/prg/two
```

Both discovery and session access are limited to those directories and their
descendants. Omitting `--path` shares all indexed projects. `--port`, `--address`,
and `--name` override the defaults when needed.

`/project` describes the current project. `/projects` lists the same shared index;
`/projects open NAME` switches the working directory and loads its saved chats,
memory, skills, and local settings. It also accepts paths, list numbers, and ID
prefixes. `/projects rename SELECTOR NAME`, `/projects tint SELECTOR COLOR`, and
`/projects del SELECTOR` manage that index; forgetting leaves chat files intact.
Opening a previously unseen directory registers it. Refresh the folder panel in
PocketMai to see changes made from the CLI.

## Start a standalone gateway without Tailcat

Build/install pmai as usual. On the machine that will run the agent:

```sh
cd /absolute/path/to/project
pmai acp-gateway \
  --host 0.0.0.0 --port 19283 \
  --cwd /absolute/path/to/project \
  --url ws://your-mac.local:19283/acp \
  --name workstation \
  -- pmai --acp --acp-root /absolute/path/to/project
```

Replace the workspace and hostname with real values. The default bind address,
when `--host` is omitted, is `127.0.0.1`. Use that default behind a reverse proxy,
and set `--url wss://your-gateway.example/acp` to export the phone-facing URL.
The advertised URL does not change the listener or configure TLS.

With `--url`, pmai prints a scannable block-character QR directly in the terminal.
Open **Scan Gateway QR** in PocketMai and point the phone at the terminal. Keep
the whole square and its white border visible; widen the terminal or reduce its
font size if lines wrap. `--qr gateway.png` additionally saves an image. On
non-Apple hosts, install the optional `qrencode` executable for terminal/image
QR generation; the URI remains available without it.

The gateway creates a private bearer token in `$PMAI_HOME/gateway/token`
(`~/.pmai/gateway/token` by default). `--token-file /path/to/token` selects a
different credential; an existing file must contain at least 32 non-whitespace
characters. Use different token files for gateways that expose different agents.

`--cwd` is the workspace the phone will request on the **agent host**. The child
command starts in the gateway's current directory. For a local pmai child, `cd`
to the project before starting the gateway. `--acp-root` restricts which working
directories pmai accepts; it is not an OS sandbox for shell commands or tools.

To expose another ACP agent, replace everything after `--` with that agent's
ACP stdio command. Configure its model, tools, and credentials on the agent host.
The gateway forwards requests, replies, notifications, and permission requests;
it does not choose models or execute tools itself. One authenticated WebSocket
connection starts one child process. No child starts for rejected credentials.

## Connect from PocketMai

1. Open the conversation drawer, swipe right to Folders, then right again to **Hosts**.
   The **Hosts** button above the folders also opens this panel. **Local** is always
   available and shows this PocketMai app's existing folders and conversations.
2. Choose **Scan Host QR** or **Add Remote Host**, then scan the terminal QR (or `gateway.png`), paste the printed
   `pmai-acp://connect/...` URI, or enter the gateway URL, token, and remote cwd.
3. Save and select the host. For `/remote serve`, accept the pending client in
   the serving REPL with `/remote accept`. PocketMai then discovers its folders and conversations.
   Choose a folder, then open a conversation or use **New Chat** at the top right
   of the chat window. Opening a
   chat connects automatically and restores its transcript from the host.
4. Send a prompt. Replies stream into the chat; tools that request permission
   display their arguments and the agent's approval/rejection choices.

The remote project panel filters by folder name only. Beside the filter, **Sort
folders** chooses **Name** or **Last Updated**, and Refresh reloads projects from
the host. The sort choice is remembered, with pinned folders always kept first
in their saved order. Each row shows its latest known update from host project
metadata or conversation activity; unknown dates are omitted and sort last.
The local and remote conversation panels share their rows, date groups, and
search controls; conversation search uses titles and locally cached messages.
Long-press a conversation to rename, delete, or export it. Hosts without chat
management support disable rename and delete for saved server chats.
Long-press a project and choose **Browse Files…** to open its file manager.
Choose **Pin to Top** or **Unpin Folder** in the same menu to organize remote
folders. Pins are saved per host on the phone, work offline, and survive refreshes,
reconnects, and updates to the saved host.

Open **Chat Settings** in the chat title menu to change the remote session's
settings. Updated pmai hosts expose provider, model, and reasoning effort over
ACP; changes apply to that conversation and persist across reconnects. Other ACP
agents expose their supported controls through standard
[session config options](https://agentclientprotocol.com/protocol/v1/session-config-options),
with legacy session modes supported as a fallback. Connect/Disconnect remains a
separate menu action.

**Share…** and **Export…** also work for remote conversations, including offline
cached history. Share creates a `.pocketmai` file; Export offers that format,
Markdown, JSON debug reports, and the usual document formats. Exports use the
history currently loaded on the phone.

Long-press a remote host to edit, reconnect, or remove it. Tapping a host in
**Manage…** opens its editor, including its name, gateway address, and accent color.
The same manager is under
**Settings → Remote Hosts**. One gateway URL represents one host, which can have
many folders and conversations. Existing per-workspace connection bookmarks
are migrated into that host without discarding their conversations.

pmai's ACP server lists the projects in its `AgentHome` index and their saved CLI
chats, plus persistent ACP sessions. `--acp-root` restricts both discovery and
session access to that directory and its descendants. To share several projects,
serve their common parent; the example above shares only one project. Refresh
the folder panel to pick up work created by other clients. Older ACP agents that
do not advertise session listing still show their configured workspace and chats
previously opened on the phone.

`/remote serve` QR codes contain a pairing invitation requiring server approval.
The standalone `pmai acp-gateway` command is an unattended adapter; its QR contains
a reusable bearer credential granting access directly. Neither is a Tailcat
enrollment invite. Tokens are stored in the iOS Keychain; local chat records do not contain
tokens and are excluded from backup. Deleting a saved connection removes its
local token and chat record, not the worker's session files.

OpenCode v2 hosts can also be added by running `opencode pair --remote` and
scanning its QR in **Add Remote Host**, or pasting its HTTPS pairing link into
**Import connection**. Local links from `opencode pair` work too. PocketMai accepts
both `/auth/connect/<code>` links and the QR's JSON `{code, urls}` payload, exchanges
the single-use code for a session token, and stores that token in the Keychain.
Save the connection, then select its discovered project and conversation.
Expired or already-used links require a fresh `opencode pair --remote` QR.

OpenCode uses its native HTTP API with Basic authentication, independently of
pmai's ACP WebSocket transport. Project and conversation discovery, history,
text prompts, tool results, permission replies, rename, and delete are supported.
Chat Settings offers the project's providers, models, model variants, and primary
agents through OpenCode's native session APIs.
Replies refresh while the host runs. File browsing and OpenCode input forms are
not currently supported by PocketMai; use the OpenCode app for those features.

The frontend supports text prompts, streamed text/reasoning, tool status and
results, permissions, and session restoration. It does not offer local file or
terminal access to the remote agent. Approvals occur when the remote agent asks
for them; a worker configured to allow tools automatically will not ask the phone.

**Stop**, leaving the chat, entering the background, or enabling PocketMai's
Airplane Mode disconnects the session. Tap **Connect** to restore it. A failed
prompt is never resent automatically because it may already have executed tools.
Agents that do not support ACP `session/load` require **New Chat** after a
disconnect. New Chat creates a separate conversation and keeps earlier chats
available in their folder.

### Host boundaries

`HostNavigationStore` owns host/folder/conversation selection. `AppStore` owns
local app conversations; `RemoteAgentStore` owns device-local host bookmarks and
cached remote transcripts. `ACPClient` and `OpenCodeClient` implement the shared
`RemoteSessionClient` interface for discovery and session transport.
`ACPServer` adapts prompts to `AgentRuntime` and delegates durable workspace data
to `ACPWorkspaceRepository`. The CLI's `AgentHomeACPWorkspace` implementation
reads and updates the same project/chat files as its local workspace, preserving
the existing chat's primary agent, title, and archive state.

Discovery uses ACP [`session/list`](https://agentclientprotocol.com/protocol/v1/session-list),
including cursor pagination on the client.
The response's `_meta.pmai.folders` contains folder names, icons, and tints so
empty projects are visible. Other ACP agents can supply standard session metadata;
PocketMai groups it by cwd. Opening a conversation uses `session/load`, and
starting a conversation uses `session/new`; browsing alone creates no chat.

This repository boundary can also be implemented by an app host without putting
its persistence or UI inside the agent runtime. PocketMai currently connects as
an ACP client; exposing its own folders over an iOS ACP listener is a further
adapter, separate from the existing local OpenAI/Ollama HTTP API server.

## Connect from the CLI over WebSocket

The ACP provider also accepts a WebSocket URL, independently of Tailcat. For
example, add this provider and agent to your pmai configuration:

```json
{
  "providers": [{
    "id": "remote",
    "kind": "acp",
    "options": {
      "url": "wss://your-gateway.example/acp",
      "tokenEnv": "PMAI_ACP_TOKEN",
      "remoteCwd": "/absolute/path/to/project",
      "permission": "auto"
    }
  }],
  "agents": [{
    "id": "remote",
    "provider": "remote",
    "model": "",
    "instructions": ""
  }]
}
```

Set `PMAI_ACP_TOKEN` to the gateway token in the CLI's environment, then run
`pmai --agent remote`. The existing ACP permission policies apply: `auto`
approves read-only requests and rejects other tools, `reject` denies all, and
`allow` approves all. The iOS frontend instead asks for each requested approval.
Remote providers default to disabling reads of the client's local files.

## Add Tailcat between the gateway and the worker

Install a [Tailcat build](https://github.com/tailscale/tailcat#readme) supporting
`serve exec`, persistent `--key` files, `TAILCAT_ADDR_FILE`, and authenticated
`TAILCAT_PEER_KEY` on **both hosts**. If it is not in PATH, use `--tailcat
/absolute/path/to/tailcat` or `PMAI_TAILCAT`. No Tailcat installation is needed
for the standalone WebSocket gateway or the phone.

On the worker:

```sh
cd /absolute/path/to/project
pmai tailcat serve --name workstation --qr invite.png -- --agent main
```

This starts Tailcat with a persistent worker key and prints an enrollment URI
and QR on first launch. Leave it running. Arguments after `--` configure the
pmai agent, for example `--config /path/to/pmai.json --agent coding`.

On the gateway/controller host, redeem the invite:

```sh
pmai tailcat pair workstation 'pmai-tailcat://pair/…'
# On macOS, a QR image also works:
pmai tailcat pair workstation /path/to/invite.png
pmai tailcat status workstation
```

Text files containing the URI work on all platforms. QR generation uses Core
Image on macOS and the optional `qrencode` executable elsewhere. Linux clients
can always paste the URI without QR tooling.

Pairing records the worker's address and workspace, creates a persistent
controller key, and adds an ACP provider/agent to the pmai config. Selection is
`--config`, then `PMAI_CONFIG`, then `./pmai.json` when present, otherwise
`~/.config/pmai/config.json`. It does not replace an unrelated agent with the same
name. The remote is usable immediately with `pmai --agent workstation`; restart
an already-open REPL before selecting it with `/agent use workstation`.

Start the phone-facing gateway on the controller host:

```sh
pmai acp-gateway \
  --host 0.0.0.0 --port 19283 \
  --cwd /absolute/path/to/project \
  --url ws://your-gateway.local:19283/acp \
  --name workstation --qr gateway.png \
  -- pmai tailcat connect workstation
```

Here `--cwd` is the **worker's** workspace reported by `pmai tailcat status
workstation`. `connect` is a raw stdio proxy for ACP clients, so it should not be
used as an interactive terminal. The phone still imports `gateway.png`, not
`invite.png`. The pair command's `--permission` policy applies when using its
registered CLI provider; the raw `connect` proxy passes approvals through to iOS.

In PocketMai's host editor, choose **pmai / ACP → Tailcat (via gateway)**.
The selection includes setup commands and is retained when you import the gateway
QR and save. Scanning a worker enrollment invite explains how to pair it on the
gateway computer and obtain the phone-facing QR.

## Enrollment, revocation, and saved state

Tailcat enrollment is pmai application metadata carried over an existing
Tailcat stream. The worker consumes the invite token and binds it to the
authenticated node key supplied by Tailcat, never a client-claimed public key.
Invites expire after five minutes by default. Only one identity can redeem a
token; the same identity may retry before expiry if a reply was lost.

```sh
# On the worker, issue another invite; this replaces the previous token:
pmai tailcat invite --expires 300 --qr invite.png

# Inspect paired controllers and their IDs:
pmai tailcat status

# Revoke one controller, including active connections (within two seconds):
pmai tailcat revoke PEER_ID
```

Use `--home /private/path` or `PMAI_HOME` consistently for all commands belonging
to the same worker/controller. Use separate homes for separate served projects.
State lives under `$PMAI_HOME/tailcat`: keys, registry, and an audit log of
enrollment/revocation/connection events. State directories are mode 0700 and
state files are mode 0600. Audit events exclude invite tokens and addresses.
`status NAME` performs a live worker check and updates the local last-seen time.

To revoke gateway credentials, replace the token file with a new random token
of at least 32 characters, or stop the gateway. Rotation rejects new connections
immediately and closes existing ones within 40 seconds. Re-export/import the
connection profile after rotation. This token is shared by clients of that
gateway; per-device gateway accounts are not implemented. A Tailcat worker sees
the gateway's paired identity, not separate phone identities.

pmai persists ACP sessions under `$PMAI_HOME/acp`, separated by agent and, for
Tailcat workers, controller identity. `--acp-sessions DIR` overrides the base
directory. Session files include prompts, replies, and tool results; completed
turns are replayed on `session/load`. Exclusive file leases prevent two child
processes from editing the same session simultaneously. A hard interruption can
lose partial output; restored sessions mark interrupted prompts so tools are not
silently assumed to have completed. ACP working directories propagate to pmai's
file tools, shell commands, and subagents without changing process-global cwd.

## Limits and troubleshooting

- **Connection refused:** check the bind address, firewall, and phone-facing
  hostname. `localhost` on the phone refers to the phone. A TLS reverse proxy
  must preserve Authorization and support WebSocket upgrades.
- **Unauthorized/closed:** check the gateway token, or check `pmai tailcat status`
  on the worker for revocation. Browser Origin headers are rejected; the gateway
  is intended for native clients using Authorization headers.
- **Expired invitation:** run `pmai tailcat invite` again on the worker. Do not
  delete keys or hand-edit peer identities to recover access.
- **Unknown/busy session:** ensure the previous connection has closed, the same
  agent/home/cwd is selected, and the worker still has the session file. Start a
  new chat if the upstream agent cannot restore sessions.
- **Missing tools/models:** configure them on the worker. pmai currently rejects
  client-supplied `mcpServers`; configure those in the worker's pmai config.
- **Gateway host portability:** SwiftNIO implements the CLI's WebSocket server
  on macOS/Linux. It belongs only to the gateway target, not the iOS app. The
  iOS build can resolve these packages as part of the shared SwiftPM manifest,
  but does not compile or link them into the app.

The PDF's central fleet registry, scheduling, remote installation, and direct
phone-to-Tailcat transport are not implemented. This integration supplies the
ACP connection and session layer, with optional Tailcat enrollment and routing.

## Verification

```sh
swift test --package-path MaiCore --disable-index-store \
  --filter 'acp|jsonRPC|mcpServer|tailcat'
python3 test/acp-gateway-smoke.py MaiCore/.build/debug/pmai
python3 test/tailcat-smoke.py MaiCore/.build/debug/pmai /path/to/tailcat
```

The gateway smoke test covers authentication, framing, streaming, approvals,
the shared URLSession client, reconnects, token rotation, and child cleanup.
The Tailcat test uses its local test relay and an offline provider to verify QR
pairing, the complete WebSocket/Tailcat/pmai path, session recovery, unauthorized
access rejection, and live revocation. Neither test uses a model API or a public
Tailcat relay.

## Forwiroh paired transport

Run `/remote serve --protocol forwiroh [--path PATH ...]` in the CLI. The ACP
listener binds only to loopback; Forwiroh carries the connection between paired
devices. No OpenTunnel executable or public WebSocket address is needed.

Import the printed pmai connection URI/QR using `/remote pair`, the iOS Hosts
screen, or Android's Hosts tab. The serving REPL first asks for
`/remote accept fw-REQUEST_ID`, then `/remote accept CODE` for ACP chat access.
`/remote pending` shows both kinds of request. `/remote reject` rejects the
selected request. This keeps device pairing separate from ACP credentials.

The invitation expires after five minutes and is single-use. `/remote qr`
creates another invitation; previously approved hosts retain their identity
and reconnect after restarting. `/remote clients` lists both device and ACP
credentials. `/remote del fw-PEER_ID` revokes device access; `/remote del CLIENT_ID`
revokes an ACP credential. `/remote stop` closes the listener and host endpoint.

Only the `pmai-acp` service is authorized. SOCKS, reverse forwarding, VPN and
arbitrary host ports are unavailable. Client endpoints accept no incoming
services. The host and client keep separate state directories under the pmai
home. iOS stores the client seed in Keychain; Android encrypts it with an
Android Keystore key. Removing this identity requires pairing again.

The Android app can pair and chat with a remote CLI host. Hosting runs in the
macOS or Linux CLI; mobile apps do not run a
background ACP server. Android currently uses the workspace from the invitation
and rejects interactive tool-permission requests. Configure the host's agent
permissions accordingly. iOS retains its existing project/chat browsing.
