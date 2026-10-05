# PocketMai for Android

A minimal app with Swift 6 application code and screens: OpenAI-compatible
provider setup, model discovery/manual selection, named system prompts,
streaming chat with cancellation, and saved conversations.

The screens render as native Android Jetpack Compose/Material 3 controls,
including text fields, buttons, menus and bottom navigation. They are not a
WebView or iOS widgets. This first version has a deliberately basic layout.
The APK bundles the same `icon-1024.png` from the iOS AppIcon asset catalog;
Gradle copies it at build time, keeping one source of truth for both apps.

`MaiChat` in the MaiCore package owns portable application state. It reuses
`OpenAIConfiguredProviderFactory`, `ChatProvider`, `SystemPrompt`,
`AgentMessage`, `AgentChat`, and `ChatFileStore`. `PocketMaiPortableUI` uses
the common SwiftUI API subset, importing Apple's SwiftUI on iOS and
SwiftUICore on Android and the desktop test host.

There are **no app-authored Kotlin/Java sources or JNI bindings**. The manifest
uses AndroidSwiftUI's supplied Application and Activity directly. The reusable
Compose renderer and generated Swift/Java bindings contain Kotlin/Java/JNI;
this is a Swift application over that runtime, not a JVM-free NativeActivity.
The framework is pinned by `scripts/bootstrap.sh`, and transitive Swift package
revisions are pinned in `Package.resolved`.
Bootstrap applies a small Swift-only renderer fix so rapid typing cannot be
overwritten by a delayed state acknowledgement. No Kotlin patch is needed.

## Build

Install the **swift.org Swift 6.4.0 toolchain** (Xcode's bundled compiler is not
interchangeable), its matching Android Swift SDK, Android SDK platform 35,
Android NDK 30, and a JDK 17 or 21. Follow the
[Swift Android setup guide](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html).
For the native SwiftPM build system, run the SDK's `setup-android-sdk.sh`
against your NDK installation as the existing Android CLI CI does.

From the repository root:

```sh
make android
```

You can also run `make` inside `PocketMaiAndroid/` to generate the APK,
`make test` for the shared-core and portable-UI tests, or `make install`
to build and install it on the attached Android device/emulator.

The build finds Java in Android Studio, registered macOS JDKs, Gradle's JDK
cache, Homebrew, or standard Linux installations. It finds the Android SDK
from `local.properties` or its default macOS/Linux location, and NDK 30 under
that SDK. Swift 6.4 toolchains and the matching Swift Android SDK are detected
in their standard locations, `.deps/`, or the initial `/tmp/pmai-swift64` build
cache. No path exports are needed for those installations. `JAVA_HOME`,
`ANDROID_HOME`, `ANDROID_NDK_HOME`, and `SWIFT` remain optional overrides for
custom installations; the SDK/NDK `*_ROOT` aliases are also accepted.

The script builds arm64 by default and uses the UI dependency's pinned Gradle
wrapper. Set `ANDROID_ABIS='arm64-v8a x86_64'` for both supported ABIs.
Only the requested ABIs are packaged, even if an earlier build left other
native libraries in the staging directory. Set
`SWIFT_SDKS_PATH` for a custom SDK install directory, or
`SWIFT_ANDROID_SDK_ROOT` to the artifact bundle's `swift-android` directory.
`GRADLE` can override the wrapper command.

Output: `app/build/outputs/apk/debug/app-debug.apk`. Install and launch:

```sh
adb install -r PocketMaiAndroid/app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n org.mai.pocketmai/com.pureswift.swiftandroid.SwiftUIActivity
```

## Release APK

Inside `PocketMaiAndroid/`:

```sh
make release
```

This compiles Swift with release optimizations and packages Android's
non-debuggable release variant. Without signing credentials, the output is
`app/build/outputs/apk/release/app-release-unsigned.apk`; it cannot be installed
until signed. `make CONFIGURATION=release` is equivalent. Plain `make` still
builds the debug APK.

Release builds can spend several minutes optimizing the renderer and SwiftPM
build tools.

To produce an installable release APK, create or reuse your own
[Android signing keystore](https://developer.android.com/studio/publish/app-signing)
and set these environment variables before running `make release`:

```sh
export PMAI_ANDROID_KEYSTORE=/absolute/path/to/pocketmai-release.jks
export PMAI_ANDROID_KEY_ALIAS=pocketmai
read -rsp 'Keystore password: ' PMAI_ANDROID_STORE_PASSWORD; echo
read -rsp 'Key password: ' PMAI_ANDROID_KEY_PASSWORD; echo
export PMAI_ANDROID_STORE_PASSWORD PMAI_ANDROID_KEY_PASSWORD
make release
unset PMAI_ANDROID_STORE_PASSWORD PMAI_ANDROID_KEY_PASSWORD
```

The password prompts above use Bash. All four variables are required when
signing is requested. Relative keystore paths resolve from `PocketMaiAndroid/`.
Keep the keystore outside the repository, back it up securely, and use the
same key for future updates. Do not pass passwords as Make command-line
arguments or commit them to files.

Signed output: `app/build/outputs/apk/release/app-release.apk`. To build and
install with the signing variables still exported, use
`make CONFIGURATION=release install`. A release signed with your own key cannot
replace a debug-key installation; uninstalling the old app erases its settings
and chats.

## Use

Open Provider, enter the API base URL (for example `https://api.openai.com/v1`)
and key, then Save provider. List models and select one, or enter a model ID
manually. Define/select a system prompt under Prompts. Chat sends the selected
instructions and conversation history through the existing Swift provider.
New chat starts a separate conversation; History reopens saved chats.

For a provider on the emulator host use `http://10.0.2.2:PORT/v1`. On a phone,
use a reachable LAN address. HTTP is enabled for local OpenAI-compatible
servers. Requests and credentials go directly to the configured endpoint.

Settings and chats live in the app-private files directory. The API key is
currently stored in `settings.json` with owner-only permissions; Android
backup is disabled. This first implementation does not integrate Keystore.
Chat files use MaiCore's `AgentChat` JSON format. Corrupt files are reported
and retained. Reopening a chat restores its original prompt, even after
editing the template.

This version displays plain text and uses basic single-line input controls
(multiline prompt text is stored verbatim). It runs replies while the process
is alive, including activity recreation, and has no background service.
It does not offer tools, MCP, attachments, voice, OCR, or local models.

## Test

```sh
sh PocketMaiAndroid/scripts/bootstrap.sh
swift test --package-path MaiCore --filter portable
PMAI_NO_VISUAL=1 swift test --package-path PocketMaiAndroid --build-system native --disable-sandbox
```

The core tests cover configuration and prompt persistence, model discovery,
request construction, streaming history, partial failures, stopping, concurrent
send protection, resuming prompts and corrupt settings. The portable UI test
evaluates all four screens and invokes a text-input callback without Android.
The framework's SwiftPM code-generation plugins need `JAVA_HOME` and network
access on a fresh build; `--disable-sandbox` allows those plugins to run.

See [AndroidSwiftUI](https://github.com/PureSwift/AndroidSwiftUI) for the UI
runtime, licensing, and its current API coverage.
