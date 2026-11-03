# Windows HTTP upload investigation

The app selects native WinHTTP for OpenAI-compatible providers on Windows.
Set the provider's `options.httpTransport` to `urlsession` to compare the original
path, or `curl` to select the alternative executable transport on Windows,
macOS, or Linux. Explicit `winhttp` selection is available on Windows.
Do not automatically retry a stalled POST through another transport: the first
request may already have reached the provider and incurred usage or side effects.

The suspected upstream bug is
[swift-corelibs-foundation#5532](https://github.com/swiftlang/swift-corelibs-foundation/issues/5532).
It reports a Windows upload stopping around a socket send-buffer boundary.
A separate [JSON POST report](https://forums.swift.org/t/windows-specific-timeout-issue-with-urlsession-in-swift-error-code-1001/81259)
describes a workaround involving an HTTP/2-enabled FoundationNetworking build.
Neither report proves the root cause of a particular pmai request.

## Windows transport choices

Keep the curl transport available independently of the upstream investigation.
Microsoft added the executable to [Windows 10 version 1803](https://devblogs.microsoft.com/commandline/windows10v1803/);
it is included on current Windows installations, but older or customized images
can lack it. pmai invokes `%SystemRoot%\System32\curl.exe` directly, avoiding
the [PowerShell 5.1 `curl` alias](https://learn.microsoft.com/en-us/windows/curl/).
The curl transport requires that executable; it does not silently retry a failed
request through FoundationNetworking.

The native implementation uses the
[WinHTTP API](https://learn.microsoft.com/en-us/windows/win32/winhttp/about-winhttp).
It provides HTTP and OS-managed TLS without a subprocess or a .NET runtime.
The Swift adapter uses a small C bridge to async WinHTTP. It queries available
bytes before reading to preserve incremental SSE delivery, closes the request
handle for cancellation, and retains its callback context and I/O buffers until
the final `HANDLE_CLOSING` notification. A total deadline spans the request and
all redirects. Certificate validation and pmai's same-origin redirect policy
remain enabled. Curl stays available independently of this Windows default.

Raw Winsock would leave TLS, certificate checks, HTTP framing, proxies, and
redirects to the application. It is useful for a reduced socket regression, but
is a much larger replacement for the application's HTTPS transport.
[.NET HttpClient's `ResponseHeadersRead`](https://learn.microsoft.com/en-us/dotnet/api/system.net.http.httpcompletionoption)
can support streaming, with a separate deadline and cancellation for content
reads. Calling it through PowerShell would still require a streaming loop,
process lifecycle handling, and safe credential transfer; a one-liner does not
remove those requirements. PowerShell is not used as an app transport here.

## Run the standalone probe

For a machine that only runs CI-built pmai releases, the manually triggered
**Windows HTTP upload diagnostics** GitHub Actions workflow runs the probe on
both x64 and ARM64 with the release's Swift 6.4.0 toolchain. Its artifacts contain
the comparison log and runtime DLL versions/hashes. It does not run on pushes or
PRs. A green diagnostic job means the harness ran; inspect the per-request byte
counts to determine whether Foundation stalled.

This probe contains no pmai dependencies, model calls, credentials, or external
service requirements. It runs a loopback server with a small receive window and
deliberately slow reads, then compares Foundation `dataTask`, Foundation
`uploadTask`, and the curl executable. It reports both Foundation's upload
delegate counters and the receiver's independent byte count and SHA-256 digest.
The delegate counter is not a packet capture or proof of delivery.

From the repository root in PowerShell:

```powershell
swiftc sys/diagnostics/urlsession-upload.swift -o urlsession-upload.exe
python sys/diagnostics/http-upload-probe.py .\urlsession-upload.exe
```

On macOS/Linux:

```sh
swiftc sys/diagnostics/urlsession-upload.swift -o /tmp/urlsession-upload
python3 sys/diagnostics/http-upload-probe.py /tmp/urlsession-upload
```

Optional: `--sizes 62000,65535,200000,1048576`. The default sizes are 32 KiB,
128 KiB, and 1 MiB. Each successful request must arrive in full. Small successes
followed by incomplete larger Foundation uploads, with complete curl uploads,
support a Foundation/Dispatch transport problem. If loopback does not reproduce,
network latency and buffering may matter; a local success does not clear the
Windows runtime. This is an opt-in diagnostic, not a throughput benchmark or CI
performance test.

## Prepare an upstream fix

Record the Windows version/architecture, the exact Swift toolchain and runtime
DLL versions, the probe output, and whether TLS and HTTP/2 affect reproduction.
Keep the reduced case independent of pmai and Ollama.

The code to instrument is:

- Foundation's `Sources/FoundationNetworking/URLSession/libcurl/MultiHandle.swift`:
  socket callback registration, `_SocketSources`, and calls into curl.
- Dispatch's `src/event/event_windows.c`: socket write registration,
  `WSAEnumNetworkEvents`, and delivery of write-ready completion packets.

The missing-progress boundary to locate is: curl attempts a write, Windows
returns `WSAEWOULDBLOCK`, the socket becomes writable, and curl gets another
opportunity to send. Establish which transition is missing before changing
registration or rearming. Capture read/write-ready events and actual receiver
progress on a failing Windows runtime, then repeat with a rebuilt runtime.

Two tempting edits are not established fixes: changing curl's event bitmask
from zero (curl explicitly allows zero and polls the descriptor itself), and
adding a fast polling timer to hide a missed notification. An upstream patch
needs a failing/passing backpressure regression and evidence identifying the
lost notification. The app workaround can be used while that is investigated.

No upstream source patch is claimed or submitted by these diagnostics. The next
required evidence is a failing Windows probe run; successful macOS runs validate
the harness, not the Windows bug or an upstream fix.

The contribution sequence is:

1. Run the manual workflow, or run the two standalone files on an affected
   machine. Attach the receiver results and runtime versions to issue #5532.
2. Trace the missing transition on that same runtime. If Dispatch loses the
   notification, the source fix belongs in `swift-corelibs-libdispatch`, even
   though the symptom is tracked in Foundation.
3. Reduce the failing upload into a bounded regression in the affected upstream
   suite, patch the identified transition, and demonstrate failure before and
   success after on Windows. Verify receiver bytes, rather than relying only on
   Foundation's delegate counters.
