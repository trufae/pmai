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

## Start a gateway without Tailcat

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

1. Open **Remote Agents** from the sidebar menu or Settings.
2. Choose **Add Remote Agent**, then scan the terminal QR (or `gateway.png`), paste the printed
   `pmai-acp://connect/...` URI, or enter the gateway URL, token, and remote cwd.
3. Review the host and workspace, then save. Open the connection and tap **Connect**.
4. Send a prompt. Replies stream into the chat; tools that request permission
   display their arguments and the agent's approval/rejection choices.

The gateway QR contains a **reusable bearer credential**, not an expiring
Tailcat enrollment invite. Anyone with that profile can control the exposed
agent. Tokens are stored in the iOS Keychain; local chat records do not contain
tokens and are excluded from backup. Deleting a saved connection removes its
local token and chat record, not the worker's session files.

The frontend supports text prompts, streamed text/reasoning, tool status and
results, permissions, and session restoration. It does not offer local file or
terminal access to the remote agent. Approvals occur when the remote agent asks
for them; a worker configured to allow tools automatically will not ask the phone.

**Stop**, leaving the chat, entering the background, or enabling PocketMai's
Airplane Mode disconnects the session. Tap **Connect** to restore it. A failed
prompt is never resent automatically because it may already have executed tools.
Agents that do not support ACP `session/load` require **New Chat** after a
disconnect. New Chat replaces the phone's saved chat for that connection; it does
not delete the old session on the agent host.

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
