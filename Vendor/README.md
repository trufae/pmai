# Forwiroh SwiftPM dependency

`Forwiroh/` contains the small SwiftPM **0.1.4** release package from
https://github.com/trufae/forwiroh/releases. The Swift sources and license are
vendored; `Artifacts/manifest.json` pins immutable release binary URLs and
SHA-256 checksums. SwiftPM fetches only the Apple XCFramework on a Mac or the
Linux/Android artifact bundle on Linux. Consumers do not need a sibling checkout,
Cargo, a Rust compiler, or generated bindings.

To upgrade, verify `Forwiroh-VERSION-swiftpm-remote.zip` against the release's
`SHA256SUMS`, then replace `Forwiroh/` with its contents. Keep the upstream
license and update the version documented in the main README. Also update the
SDK pin comment in `Forwiroh/Package.swift`: SwiftPM caches that manifest without
tracking the external artifact JSON. Preserve the local artifact selection in
that manifest when updating the SDK: platform conditions prevent linking an
artifact, but SwiftPM still downloads every declared binary target.

`PMAI_FORWIROH_PLATFORM=apple|native|none` selects the destination for cross-builds.
The default follows the host: Apple on macOS, native on Linux/Android, and no
artifacts on unsupported hosts such as Windows. Android and musl build scripts
set `native` explicitly, including when run on a Mac.

Maintainers can set `PMAI_FORWIROH_PATH` to a prepared SDK package when testing
upstream fixes before release. Ordinary builds use the pinned vendored package.

Release package SHA-256: `8818a52839f698baa6144e705df12d690feb02c76717b495a526b90dd4ae7714`.
