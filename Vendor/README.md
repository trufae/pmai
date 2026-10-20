# Forwiroh SwiftPM dependency

`Forwiroh/` contains the small SwiftPM **0.1.1** release package from
https://github.com/trufae/forwiroh/releases. The Swift sources and license are
vendored; `Artifacts/manifest.json` pins immutable release binary URLs and
SHA-256 checksums. SwiftPM fetches the Apple XCFramework and Linux/Android
artifact bundle. Consumers do not need a sibling checkout, Cargo, a Rust
compiler, or generated bindings.

To upgrade, verify `Forwiroh-VERSION-swiftpm-remote.zip` against the release's
`SHA256SUMS`, then replace `Forwiroh/` with its contents. Keep the upstream
license and update the version documented in the main README. Also update the
SDK pin comment in `Forwiroh/Package.swift`: SwiftPM caches that manifest without
tracking the external artifact JSON. This version comment is the only local
change to the release package.

Maintainers can set `PMAI_FORWIROH_PATH` to a prepared SDK package when testing
upstream fixes before release. Ordinary builds use the pinned vendored package.

Release package SHA-256: `68998051cd0d8b5fa780595fa5dccdffbddbf4d50740f4a9d112d271b8679f68`.
