[Documentation](README.md) · [Project home](../README.md)

# Build and releases

Build the iOS app with Xcode and the CLI with SwiftPM through Make.
Build the Kotlin/Compose Android app with `make android-kotlin`, or use
`make android-kotlin-release` for its release APK. See the
[Kotlin Android guide](../PocketMaiKotlin/README.md).
The deprecated pure Swift Android preview remains buildable with `make android`.

## Requirements and local inference

The iOS app requires Xcode 26.4+ and an iOS 18+ deployment target. iOS 26-only features
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

The project pins `mlx-swift` 0.31.6 (includes the iOS build fix) and
`mlx-swift-lm` 3.31.4.

## Toolchains and CI

CI and release builds use Swift 6.4.0, including matching Static Linux and
Android SDKs. The packages keep Swift 6 language mode. SwiftPM now defaults
to Swift Build; use `swift build --package-path MaiCore --show-bin-path`
(with the same build system, configuration and SDK arguments) to locate binaries.
Android uses `--build-system native` and the SDK's `setup-android-sdk.sh` to
avoid a Swift Build 6.4 planner crash on Linux. CI exercises the optimized
Android release build and musl x64 networking/no-AVX checks; other CI builds
use debug configurations. Release tags build the optimized distribution
artifacts in the Release workflow.

## Build commands

```sh
make build               # builds for the iOS Simulator without code signing
make repl-build          # builds the debug CLI without starting the REPL
make repl-install        # installs an unoptimized CLI without debug information
make mac-dmg             # builds the Release Mac app and packages build/pmai.dmg
make run                 # builds, installs, and launches on a connected iOS device
make fmt                 # swift-format the sources
```

## Startup diagnostics

For startup diagnostics on any CLI platform (including Android/Termux), run
`PMAI_STARTUP_TIMING=1 pmai`. It prints cumulative and per-phase milliseconds to
stderr through the first input handoff, including plugin setup, tools/skills,
chat loading, and each configured provider or MCP connection. Normal launches
do not print these timings.

## Native CLI providers

The CLI and iOS app reuse `MaiLocalProviders` for Apple Intelligence and MLX.
On macOS, add a native provider with `/provider add apple --kind apple` or
`/provider add mlx --kind mlx`, then `/model apple::on-device` or
`/model mlx::LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit`; no server URL is needed.
`make repl-build` includes the CLI's MLX Metal resource. See
[native provider setup](../MaiCore/README.md) for requirements and configuration.
`make repl-install` builds incrementally with `-c debug -debug-info-format none`
and installs that executable and its MLX resource to `~/.local/bin` (or `BINDIR`).

## Incremental builds

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

## Run on an iOS device

`make run` selects the first connected iOS device, builds a signed `Debug` app,
and installs and launches it. Use `make run DEVICE=<UDID>` to select a specific
device, or `make run APP_BUNDLE=<path>` to install an existing app bundle without
building. Open `PocketMai.xcodeproj` to configure signing, attach the debugger,
or run in the Simulator.

## Releases

Get PocketMai from the [App Store](https://apps.apple.com/es/app/pocketmai/id6764296742).
The [GitHub releases](https://github.com/trufae/pmai/releases) include the iOS IPA,
the native Mac app as `pmai-macos-arm64.dmg` and `pmai-macos-x64.dmg`,
the Kotlin Android app as `PocketMai-Android.apk` (arm64), source
archives, and pmai CLI binaries for macOS, Linux, and Windows (arm64 and x64),
plus Android arm64. Windows CLI builds are beta. `SHA256SUMS` covers the CLI
archives, DMGs, IPA, and Android APK.
The Mac app and DMG use ad hoc signatures; they are not Developer ID signed or
notarized. See the [Mac build notes](mac-app.md) for local signing options.
Static musl builds omit native plugin loading.

The website's [Android APK](https://trufae.github.io/pmai/downloads/PocketMai-Android.apk)
is the Kotlin app's release APK from the latest successful main-branch build,
for arm64 devices. Its [SHA-256 checksum](https://trufae.github.io/pmai/downloads/PocketMai-Android.apk.sha256)
is published alongside it. CI builds use a generated debug signing key;
updating between builds may require reinstalling.

The older [pure Swift Android preview](../PocketMaiAndroid/README.md) is deprecated.
Its CI artifacts are labeled `pureswift` and are excluded from GitHub releases
and website downloads. The Android CLI is a separate terminal client.

The [Pebble Time 2 app](../PebbleApp/README.md) supports voice prompts and saved
shortcuts through PocketMai for iOS and Android.
