// Standalone FoundationNetworking probe for swift-corelibs-foundation#5532.
// swiftc sys/diagnostics/urlsession-upload.swift -o urlsession-upload.exe
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

func report(_ text: String) {
  FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

final class UploadProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  let finished = DispatchSemaphore(value: 0)
  var succeeded = false

  func urlSession(_ session: URLSession, task: URLSessionTask,
    didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
    // This is Foundation's counter; the Python receiver reports bytes actually
    // received independently. A delegate counter alone does not prove delivery.
    report("delegate.bodyProgress=\(totalBytesSent)/\(totalBytesExpectedToSend)")
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
    report("HTTP=\((response as? HTTPURLResponse)?.statusCode ?? 0)")
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error {
      let value = error as NSError
      report("error=\(value.domain):\(value.code) \(value.localizedDescription)")
    } else {
      succeeded = (task.response as? HTTPURLResponse)?.statusCode == 200
      report("completed=\(succeeded)")
    }
    finished.signal()
  }
}

guard CommandLine.arguments.count == 4,
  let url = URL(string: CommandLine.arguments[1]),
  let count = Int(CommandLine.arguments[2]), (1...16_777_216).contains(count),
  ["data", "upload"].contains(CommandLine.arguments[3])
else {
  report("usage: urlsession-upload URL BODY_BYTES data|upload")
  exit(2)
}
let mode = CommandLine.arguments[3]
var request = URLRequest(url: url)
request.httpMethod = "POST"
request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
request.timeoutInterval = 30
let body = Data(repeating: 0x61, count: count)
let probe = UploadProbe()
let configuration = URLSessionConfiguration.ephemeral
configuration.timeoutIntervalForResource = 45
let session = URLSession(configuration: configuration, delegate: probe, delegateQueue: nil)
let task: URLSessionTask
if mode == "data" {
  request.httpBody = body
  task = session.dataTask(with: request)
} else {
  task = session.uploadTask(with: request, from: body)
}
report("starting mode=\(mode) bodyBytes=\(count)")
task.resume()
guard probe.finished.wait(timeout: .now() + 60) == .success else {
  report("completion callback did not arrive within 60 seconds")
  task.cancel()
  session.invalidateAndCancel()
  exit(1)
}
session.invalidateAndCancel()
exit(probe.succeeded ? 0 : 1)
