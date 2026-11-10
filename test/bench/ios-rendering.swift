// Opt-in macOS harness for the iOS app's portable rendering components.
// Compile with the production SyntaxHighlighter.swift and RenderCache.swift.
import Foundation
import SwiftUI

@main
struct IOSRenderingBenchmark {
  static func main() {
    let mode = CommandLine.arguments.dropFirst().first ?? "highlight"
    let start = ProcessInfo.processInfo.systemUptime
    if mode == "highlight" {
      let code = String(repeating:
        "let value = call(first_argument, second_argument) + 12345 // expression\n", count: 4_096)
      let result = SyntaxHighlighter.highlight(code, language: "swift")
      precondition(String(result.characters) == code)
      print("highlight: \(code.utf8.count) bytes, \(result.runs.count) style runs")
    } else {
      // Isolate snapshot retention: the former count-only policy versus the
      // same count limit with the attributed cache's byte-cost budget.
      let budget = mode == "count-only" ? Int.max : 4 * 1_024 * 1_024
      var cache = RenderCache<String, AttributedString>(maximumCount: 384, maximumCost: budget)
      var text = String(repeating: "paragraph ", count: 25_000)
      for _ in 0..<384 {
        text += " more text"
        let value = AttributedString(text)
        cache.insert(value, for: text, cost: text.utf8.count * 2 + value.runs.count * 128)
      }
      precondition(cache.value(for: text) != nil)
      print("\(mode): \(cache.totalCost) accounted bytes retained")
    }
    print(String(format: "elapsed: %.4f seconds", ProcessInfo.processInfo.systemUptime - start))
  }
}
