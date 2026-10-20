# Embedding Forwiroh with SwiftPM

`import Forwiroh` embeds the same networking core as the CLI. The package includes
the Swift API and precompiled Rust libraries: consuming it does not run Cargo,
generate bindings, start a daemon, or require a bridging header. Swift 6.2 or newer
is required (pmai's Android toolchain is already newer).

## Use from pmai

Download `Forwiroh-<version>-swiftpm.zip` from
[GitHub Releases](https://github.com/trufae/forwiroh/releases) and unpack it into
a stable directory. In
`pmai/MaiCore/Package.swift`, add the package and the product to the target that
will own the networking endpoint:

```swift
dependencies: [
    .package(path: "../../forwiroh"), // or the unpacked release's Forwiroh directory
],
targets: [
    .target(name: "YourTarget", dependencies: [
        .product(name: "Forwiroh", package: "forwiroh"),
    ]),
]
```

The sibling checkout works once its maintainer has populated `Artifacts/` using
the commands below. Binaries are generated output, not committed to the Rust
source tree. A fresh source checkout alone is not a binary distribution. The full
release ZIP contains everything SwiftPM needs, including offline builds.

```swift
import Foundation
import Forwiroh

let state = URL.applicationSupportDirectory.appendingPathComponent("pmai/Forwiroh")
let node = try await Forwiroh.open(stateDirectory: state, name: "pmai")
let status = try await node.status()
print(status.id, status.peers)

// Pair once: show this URI/QR and explicitly approve the requesting peer.
let invitation = try await node.invite()
let qr = try Forwiroh.qrCode(invitation.uri)
// The other device calls pair(invitation:device:).
// Inspect pendingPairings(), then approve(id:accept:) on this device.

// After pairing, expose a remote service on this device's loopback interface.
let tunnel = try await node.forward(peer: "home", listen: "127.0.0.1:2222",
                                    service: "127.0.0.1:22")
// pmai can now connect to localhost:2222 using its ordinary networking APIs.
try await node.stopTunnel(id: tunnel)
await node.close()
```

Keep the endpoint in a long-lived owner. Opening, commands, packets, and shutdown
run on worker threads. Commands can run concurrently, including pairing and its
approval/cancellation. Always `await close()` before reusing its state directory;
deinitialization also closes the endpoint, but can block the releasing thread.
Each concurrent close waits for all readers and commands before freeing Rust.
Cancelling a Swift task does not cancel a core operation: use `cancelPair()`,
`stopTunnel(id:)`, `stopVPN(id:)`, or `close()`.

`events` is a single-consumer `AsyncStream<CoreEvent>`. It buffers the newest 128
events; a `resync` event means refresh `status()` and `pendingPairings()`. Cancelling
observation does not close the endpoint. Avoid making an indefinitely running
event task the sole owner of the endpoint; close it when your feature stops.

Typed methods cover invitations, pairing approval/rejection/cancellation, peers,
policies, forwards, reverse forwards, SOCKS, VPN sessions and packets. `command`
accepts a Sendable `[String: JSONValue]` for protocol extensions. Core errors throw
`ForwirohError`; arrays and null responses retain their original JSON shape.

## Platform coverage

| Platform | Release binary | Minimum |
| --- | --- | --- |
| macOS | Universal arm64 / x86_64 XCFramework slice | macOS 14 |
| iOS | arm64 device; arm64 / x86_64 simulator slices | iOS 17 |
| Linux | arm64 / x86_64 glibc and musl static archives | glibc 2.39 or musl |
| Android | arm64-v8a / x86_64 static archives | API 28 |

Apple uses XCFrameworks. Linux and Android use SwiftPM's
[static library artifact bundles (SE-0482)](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0482-swiftpm-static-library-binary-target-non-apple-platforms.md).
Their archives link into the consuming executable/shared library; no extra
`libforwiroh.so` needs packaging or a runtime search path. Use SwiftPM's native
build system when cross-compiling Android. Android variant metadata includes
API-level triples 28 through 40 (pmai currently selects `android28`).

Mobile callers supply `identity: Data` containing a stable 32-byte seed stored in
their Keychain/Keystore. The core does not write external identities to disk.
macOS/Linux can omit it to use the core's owner-only identity file. The caller
chooses a writable, app-specific state directory. An app and its VPN extension
cannot own the same directory simultaneously.

### Android initialization

Before `open`, call `Forwiroh.initializeAndroid(environment:application:)` on a
JNI thread with its current `JNIEnv*` and Application `jobject`. This uses the
existing Rust JNI initialization, retains the Application, and installs Android's
certificate verifier. The host must check/propagate any pending JNI exception;
do not continue to `open` after initialization failed. Swift JNI libraries can
pass their existing raw references; no new Swift wrapper generation is needed.

The host Gradle build also needs the verifier's Java component. For the current
Cargo.lock it is `0.2.0`:

```groovy
// settings.gradle, dependencyResolutionManagement.repositories
maven { url 'https://raw.githubusercontent.com/rustls/rustls-platform-verifier/maven-archive/android-release-support/maven/' }

// app/build.gradle, dependencies
implementation 'org.rustls:rustls-platform-verifier:0.2.0'
implementation 'org.jetbrains.kotlin:kotlin-stdlib:2.1.0'
```

Keep that version synchronized with `rustls-platform-verifier-android` in
Cargo.lock when updating the core. If the host app enables R8/ProGuard, preserve
the classes called through JNI in the app's shrinker rules:

```proguard
-keep class org.rustls.platformverifier.** { *; }
```

The app needs the INTERNET permission. For
16-KiB Android devices, link the final host `.so` with
`-Wl,-z,max-page-size=16384`; static archives do not have load-segment alignment.

VPN still requires the host's NetworkExtension or VpnService integration and
entitlements/permissions. `startVPN`, `sendPacket`, and `receivePacket` provide
packet transport, not system routing. iOS ordinary tunnels follow the host app's
foreground lifetime. Android foreground/background service ownership also stays
with the host.

## Maintainer builds and binary releases

Only maintainers/CI need Rust. Install the desired Rust targets first. To populate
this checkout for an Apple Silicon Mac, iPhone, and Apple Silicon simulator:

```sh
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
bash scripts/build-swift-core.sh aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
python3 scripts/package-swift.py
swift test
```

`build-swift-core.sh` writes archives to `dist/libraries/<rust-target>/`. Run it
on Linux for the Linux targets, or with `ANDROID_NDK_HOME` for Android. The release
builds use Ubuntu 24.04, `musl-tools`, and Zig 0.17.0 for musl linking (or supply
your own `CARGO_TARGET_<TARGET>_LINKER` and `CC_<target>` overrides). The release
workflow builds all architectures, combines their outputs on macOS, tests an
external SwiftPM consumer, and uploads the distributable packages. Musl archives
are built with `-C target-feature=-crt-static` so the final Swift link owns the C
runtime; consumers can still produce a fully static executable with the Swift
Static Linux SDK. `--require-all` rejects incomplete release sets.

`package-swift.py` only packages existing libraries. It creates local `Artifacts/`,
separate XCFramework/artifactbundle ZIPs, the complete SwiftPM package ZIP,
`SHA256SUMS`, and build provenance (`Artifacts/build-info.json`). You can specify
individual inputs with `--library RUST_TARGET=/path/to/libforwiroh.a`.

To prepare a small Git-distributed Swift package, also pass
`--require-all --release-base-url https://HOST/OWNER/REPO/releases/download/TAG`.
This produces `Forwiroh-<version>-swiftpm-remote.zip` containing the Swift sources
and a manifest with immutable binary URLs and computed checksums. Publish the
binary assets at those exact URLs, then commit the contents of that remote
package to a distribution branch/repository and tag a semantic version. Consumers
can then use `.package(url: "YOUR_DISTRIBUTION_REPOSITORY", from: "VERSION")`.
Include `Artifacts/manifest.json` in that distribution commit. Do not tag the
unpackaged Rust source tree as a ready-to-consume Swift package.

### Publish a release

Set the workspace, lockfile, and application versions to the same value, and add
`docs/releases/<version>.md`. Check them before committing:

```sh
python3 scripts/check-release.py v0.1.0
git tag -a v0.1.0 -m "Forwiroh 0.1.0"
git push origin main
git push origin --tags
```

The tag must match the workspace version. The SwiftPM workflow builds and tests
all platforms, requires all eleven native variants, generates the remote
manifest using that tag's GitHub asset URLs, verifies checksums, then creates
the release and uploads both package ZIPs, both binary ZIPs, and `SHA256SUMS`.
Only the final publishing job has permission to write releases. Pull requests
and manual runs upload Actions artifacts without publishing a release.

The source tag itself remains a Rust source checkout. Consumers use the full ZIP
offline or the smaller remote ZIP, which downloads the binaries on first build.
A Git URL dependency still requires the separate distribution repository/branch
described above; publishing assets does not add a manifest to the source tag.

Use `try await node.setPairingPolicy(PeerPolicy(restricted: true, services: ["pmai-acp": "127.0.0.1:19283"]))` before inviting peers (SDK 0.1.1+). Client-only endpoints can use an empty restricted policy. This avoids a period of unrestricted access immediately after pairing. Existing peer permissions are unchanged.
