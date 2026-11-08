# CLI XDC apps

A CLI XDC app is a directory with a `manifest.json` and any source or data it
needs. Use an installed interpreter or compiler to run it:

```sh
pmai app run --allow-exec examples/cli-xdc/c "Hello world"
pmai app run --allow-exec examples/cli-xdc/node "Hello world"
pmai app run --allow-exec examples/cli-xdc/python "Hello world"
```

The C example uses Clang. On Windows, run it from an environment with the
native compiler and SDK available. The Python example expects `python` on PATH.
The Node example uses the built-in `fetch` API for chat requests.

The manifest contains `version: 1`, a required `run.command` argument array and
an optional `build.command` argument array. Both commands run from the app
directory. `{bin}` expands to a fresh executable path when a build is declared,
with an `.exe` suffix on Windows. A failed build stops the app and returns the
compiler's exit status. Optional `build.pkg_config` entries name installed
modules for `pkg-config --cflags --libs`. Build messages go to stderr so the
standalone app's stdout can be used in a pipeline.

`--allow-exec` authorizes native execution with your user's permissions.
Review the build and run commands before using it with code you receive.

## Use the active chat

Run this at the pmai chat prompt:

```text
/app run --allow-exec --chat examples/cli-xdc/node "Summarize our conversation."
```

The child receives a private loopback URL in `PMAI_APP_RPC`. Send one JSON-RPC
2.0 request per HTTP POST. Each app can make one request at a time. The endpoint
closes when the app exits. The REPL owns stdin in this mode and displays the
app's collected stdout and stderr when it exits.

| Method | Parameters | Result |
| --- | --- | --- |
| `chat/context` | None | The selected chat's text history, session ID, agent, provider and model |
| `chat/prompt` | `{"text":"..."}` | `{"text":"..."}` using the selected chat's context and agent |
| `tools/list` | None | The session's enabled tools and schemas, including skill tools when enabled |
| `tools/call` | `{"name":"...","arguments":{}}` | Tool output, subject to the chat's policy and approvals |
| `user/ask` | `{"text":"..."}` | The next answer from the interactive REPL |

App prompts add to the app's copy of the chat for later requests. The host
conversation is edited through the regular chat interface. An app can invoke
tools that change files or services after the usual approvals.
