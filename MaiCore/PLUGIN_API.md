# Mai native plugin API v1

Mai uses the same logical plugin registry for statically linked Swift modules
and dynamically loaded macOS libraries. PocketMai installs signed Swift package
modules at composition time. The CLI can additionally load trusted `.dylib`
files.

The bundled integrations demonstrate static composition: `MaiOpenAIPlugin`,
`MaiMCPPlugin`, and `MaiVisionOCRPlugin` are separate Swift targets. `MaiCore`
keeps only the contracts, configuration records, structured content, runtime,
and transcript state needed by every host.

Native plugins must export this C symbol:

```c
const mai_plugin_api_v1 *mai_plugin_entry_v1(void);
```

The full declaration is in
`Sources/CMaiPluginABI/include/mai_plugin.h`. The returned table contains a JSON
manifest and asynchronous `start`, `cancel`, and `destroy` functions. `start`
receives a JSON request and may emit zero or more event JSON values before
calling its completion callback exactly once. It must copy request memory before
returning. Callback strings only need to remain valid during the callback.
After completion, a plugin must not use the callback context again. Cancellation
must eventually complete the operation.

The manifest declares an identity plus factory kinds for these extension
points:

- `chat-provider`
- `agent-tool`
- `ocr-provider`
- `mcp-tool-source`

Requests use the operations in `MaiPluginSDK.NativePluginOperation`. Payloads
are Codable JSON representations of MaiCore's provider requests and responses,
tool definitions and outputs, OCR requests and results, and MCP catalogs. The
ABI version freezes those representations for v1; incompatible changes require
a new entry symbol and ABI version.

Agent-tool extensions answer `tool.list` with their provider-visible tool
definitions. They may also answer the optional `tool.groups` operation with
`NativeToolGroupDefinition` values. A group gives the host one stable checkbox
for several related tool names (for example, `github`) and may declare portable
`text`, `secret`, `boolean`, `number`, or `choice` settings. The host passes the
updated tool-source options back in the factory context when it reloads the
tools. Plugins that predate `tool.groups` remain compatible: the host groups
their tools by the prefix before the first underscore.

Build and exercise the reference plugin:

```sh
make plugin-fixture
make repl ARGS="--config MaiCore/Tests/Fixtures/native-plugin.json --plugin $(swift build --package-path MaiCore --show-bin-path)/libMaiFixturePlugin.dylib"
```

Then use `/plugins`, `/models`, `/tools`, `/mcps`, and `/image ocr PATH` in the
REPL. Platform-specific SwiftPM build directories may include the target triple;
`swift build --package-path MaiCore --show-bin-path` prints the exact directory.

Native plugins run in the CLI process and have the same permissions as the CLI.
They can crash or compromise it, so only load trusted libraries. Untrusted or
fault-isolated extensions should use MCP or a future subprocess transport.
