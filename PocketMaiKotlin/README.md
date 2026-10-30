# PocketMai Kotlin

Native Android UI in Kotlin and Jetpack Compose, backed by the same Swift
MaiCore libraries as pmai and iOS. This app has its own application ID
(`org.mai.pocketmai.kotlin`) and can coexist with the SwiftUI Android preview.

The iOS app is the feature/navigation reference. Android uses Material 3,
wallpaper-derived colors, system/light/dark themes, edge-to-edge layout,
adaptive bottom navigation/navigation rail, a chat list/detail layout on large
windows, multiline input above the keyboard, selection/copy, and the system
share sheet. See Android's [Material 3](https://developer.android.com/develop/ui/compose/designsystems/material3)
and [adaptive navigation](https://developer.android.com/develop/adaptive-apps/guides/build-adaptive-navigation) guidance.

## Build

Install the **swift.org Swift 6.4.0 toolchain** and matching Android Swift SDK,
Android SDK platform 36 and build tools 36.0.0, NDK 30, and JDK 17 or 21.
Run the Swift SDK's `setup-android-sdk.sh` against NDK 30 once. Xcode's bundled
compiler is not a substitute for the matching swift.org toolchain.

```sh
cd PocketMaiKotlin
make                  # debug APK
make debug
make release          # optimized Swift, non-debuggable Android app
make install          # build and install debug on the selected adb device
```

Named outputs, similar to SonDeNit's Makefile:

* `PocketMaiKotlin-0.1.0-debug.apk`
* `PocketMaiKotlin-0.1.0.apk` (release)

Gradle also leaves the APKs under `app/build/outputs/apk/{debug,release}/`.
`make -C PocketMaiKotlin release` works from the repository root, as do
`make android-kotlin` and `make android-kotlin-release`.

Both variants are installable. By default, release uses the local Android
debug signing key, matching SonDeNit's convenient local release workflow.
For distribution, set all four existing pmai Android signing variables:

```sh
export PMAI_ANDROID_KEYSTORE=/absolute/path/pocketmai.jks
export PMAI_ANDROID_KEY_ALIAS=pocketmai
# Supply these through your shell/session's secret handling:
export PMAI_ANDROID_STORE_PASSWORD
export PMAI_ANDROID_KEY_PASSWORD
make release
```

Keep the same signing key for subsequent updates. A custom-signed build
cannot replace a debug-signed installation without uninstalling first.

The scripts discover standard SDK/JDK/toolchain locations and ignored
`.deps/` installations. `SWIFT`, `JAVA_HOME`, `ANDROID_HOME`,
`ANDROID_NDK_HOME`, `SWIFT_SDKS_PATH`, and `SWIFT_ANDROID_SDK_ROOT` can override
discovery. `ANDROID_ABIS='arm64-v8a x86_64' make` packages both supported ABIs;
the default is arm64. Android Studio's debug/release builds invoke the same
native build automatically. Each variant has separate staged native libraries.

## App flows

* **Chats:** searchable saved local chats, date groups, conversation folders,
  move/rename/delete folder controls, long-press copy/edit/delete/share actions, streaming replies,
  cancellation with saved partial replies, Markdown, model selection and
  multiple saved providers, named system prompts, photo attachments and document import.
  PDF text is extracted on Android; scanned PDFs can be sent as pages to a local
  vision model. Remote hosts currently accept converted text documents.
  Activity recreation retains Swift state and active work;
  the composer draft is saved by the Android ViewModel.
* **Hosts:** local and saved remote hosts, pinning, renaming, removal,
  reconnect/disconnect, host workspaces and saved/discovered remote sessions.
  Use `/remote serve --protocol forwiroh` in pmai, scan its QR or paste its connection link,
  and approve pairing/chat access on the host. Connection links can also open
  the app directly. Forwiroh's stable identity seed is encrypted with Android
  Keystore; certificate verification uses the Android application context.
  The camera scanner uses CameraX and bundled ML Kit QR decoding; it requests
  camera permission only when opened and needs no model download. Scanning fills
  the pairing sheet for review before connecting.
* **Tools:** enable the local agent runtime, expand tool groups and choose individual tools.
  Group switches preserve individual tool selections.
  Every local tool call asks for approval. File tools are confined to the app's
  private workspace. Tool calls/results are retained in the saved transcript.
  Desktop shell and pmai command tools are excluded.
* **MCP:** add, edit, enable or remove Streamable HTTP MCP endpoints, with an
  optional bearer token. Enabled servers are discovered when an agent turn starts;
  their tools share the native approval path. Android does not bundle desktop
  stdio MCP processes.
* **Skills:** create/edit/remove portable `SKILL.md` workflows and enable them
  individually as tools. This uses MaiCore's existing skill catalog and manager.
* **Remote settings:** models, tools and other options advertised by the host,
  using ACP's configuration protocol. Remote tool permission requests are shown
  on Android and answered on the same connection.
* **Apps:** import `.xdc` files using Android Files, or browse the selected
  remote workspace and download an archive through MaiACP. Apps run in WebView
  with distinct HTTPS origins and storage, persisted/replayed status updates,
  explicit chat-composer handoff and per-app inference/internet permissions.
  The public PocketMai JavaScript API is generated from MaiCore's shared implementation.
  Inference uses the Swift provider without exposing API keys to JavaScript.

This is a new Android client, not complete iOS parity. Voice,
on-device models, stdio MCP, WebXDC speech/realtime channels and WebXDC
chat-scope tool loops are not implemented. WebXDC inference is isolated from
chat history. WebXDC file import returns an empty list; status updates are local
to this device. Imported archives have file-count/size limits and cannot escape
their app directory. Camera, microphone and location access are disabled.

Provider credentials, MCP settings, host credentials, skills and chat files
remain in private app storage; Android backup is disabled. Provider/MCP secrets
are private files, while the Forwiroh identity additionally uses Keystore.

## Library boundary

```text
Kotlin Compose → ViewModel/StateFlow → generated Java/JNI API
    → MaiMobile facade → MaiChat / AgentRuntime / MaiMCP / MaiACP / providers
```

`Sources/MaiKotlinBridge` exports three Swift functions. `swift-java`'s
`JExtractSwiftPlugin` generates Java methods, callback interfaces and JNI
entry points. No native signatures are manually duplicated in Kotlin/Java.
`MaiCore/Sources/MaiMobile` owns the shared application facade; JSON carries data snapshots
and commands, never UI descriptions. Kotlin owns Android lifecycle and UI.

Bindings and libraries are regenerated during Gradle's variant preparation.
The `bridge` Android library packages the native code and generated Java API;
its runtime JAR comes from Swift Java's own callback build. Do not edit anything
under `.build/` or `bridge/build/generated/`. The generator and transitive
dependencies are pinned in `Package.swift` and `Package.resolved`.

## Checks and CI

```sh
make test
```

The focused Swift tests (`python3 test/run-tests.py mobile`) use deterministic
providers to check settings, multiple providers, folders, attachment-preserving
message edits, streaming cancellation, tool groups and approved tool execution.
JVM tests cover WebXDC extraction and malicious/oversized archives.
No live model, credentials or emulator is needed for these suites.

The Android GitHub Actions workflow builds both Android clients. The Kotlin
job tests the facade/importer and uploads debug and release APKs containing
arm64 and x86_64 libraries. CI release APKs use the runner's debug key; configure
your own signing variables for an APK intended for distribution.
