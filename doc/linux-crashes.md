# Linux CPU compatibility and crashes

Linux x64 builds should run on baseline x86-64 CPUs, including the Intel
Celeron N4120. Keep the default CPU target; `-Osize` optimizes for size without
selecting the build host's instruction set. Do not add `-march=native`, AVX,
or x86-64-v3 requirements to portable builds. The N4120 supports SSE4.2 but
does not support AVX. Use the fully static `linux-x64-musl` asset on Alpine;
the regular Linux asset still requires glibc and system libraries.

`Illegal instruction` / SIGILL alone does not identify a CPU mismatch.
Swift also deliberately traps for failed preconditions, force unwraps,
out-of-range numeric conversions, integer overflow, `try!` failures and
errors escaping a throwing entry point. On x86 these can end at `ud2`.
Such traps cannot be caught with `do/catch`: fix the operation that traps.

The CLI entry point is nonthrowing and catches setup errors. Both one-shot
requests and REPL turns already catch provider errors. Ordinary connection
failures and HTTP errors should be reported, with exit status 1 for a failed
one-shot turn, or a usable prompt in the REPL.

One concrete trap was an unchecked Double-to-Int conversion in
`JSONValue.intValue`, reachable from server-supplied token counts and tool
call indices. Values such as `1e100` are valid JSON but not representable as
Int. Conversion now returns nil, and invalid token usage throws a provider
error. Token-count addition is also checked before constructing usage.
This is a demonstrated code path, not a diagnosis of a particular crash
without its backtrace.

Run the release HTTP regressions (local mock server; no model credentials):

```sh
python3 test/linux-network-smoke.py "$(swift build --package-path MaiCore -c release --show-bin-path)/pmai"
# Fully static musl binary, SSE4.2 CPU model without AVX:
python3 test/linux-network-smoke.py qemu-x86_64 -cpu Nehalem ./pmai
```

CI checks success, HTTP 401, disconnects, malformed responses and invalid
token usage with streaming enabled and disabled. The musl release also runs
these paths under QEMU, exercising the linked Swift runtime and networking
libraries. This is an ISA compatibility check, not a complete emulation or
hardware certification of the N4120.

For a remaining crash, retain the exact binary, Swift crash output and core
dump. With an unstripped build, inspect `bt` and `x/i $pc` in gdb. `ud2`
alongside `_assertionFailure` or `swift_errorInMain` suggests a deliberate
trap; an unsupported vector instruction suggests a CPU target or dependency
problem. Do not ignore SIGILL or disable Swift safety checks to hide it.

Sources:
- [Intel N4120 specifications](https://www.intel.com/content/www/us/en/products/sku/197309/intel-celeron-processor-n4120-4m-cache-up-to-2-60-ghz/specifications.html)
- [Swift top-level error handling](https://github.com/swiftlang/swift/blob/main/stdlib/public/core/ErrorType.swift)
- [Swift fixed-width integer conversion](https://github.com/swiftlang/swift/blob/main/stdlib/public/core/IntegerTypes.swift.gyb)
