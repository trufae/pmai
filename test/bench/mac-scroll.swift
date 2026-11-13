// Opt-in benchmark using the actual Mac chat and deterministic local messages.
import AppKit
import Darwin
import MaiACP
import MaiCore
import SwiftUI
@testable import MaiMac

@MainActor
final class ScrollBenchmark: NSObject, NSApplicationDelegate {
  private var window: NSWindow!
  private var timer: Timer?
  private var scroll: NSScrollView?
  private var frame = 0
  private var startTime = 0.0
  private var startCPU = 0.0

  func applicationDidFinishLaunching(_ notification: Notification) {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    let chat = MacConversation(hostID: nil, hostName: "Benchmark", cwd: directory.path,
      sessionID: nil, title: "Scroll benchmark", home: AgentHome(rootURL: directory))
    chat.messages = (0..<8).map { index in
      ACPConversationMessage(role: index.isMultiple(of: 2) ? "user" : "assistant", text: """
        ## Message \(index + 1)
        A sample paragraph with **emphasis**, `inline code`, and a [link](https://example.com).

        - Keep the conversation readable while scrolling.
        - Include formatted text and a code block.

        ```swift
        struct Example {
          let count = 42
          func value() -> Int { return count }
        }
        ```

        | Setting | Value |
        | --- | --- |
        | Mode | Local sample |
        | Messages | 8 |
        """)
    }
    window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 720),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "pmai scroll benchmark"
    window.contentView = NSHostingView(rootView: MacChatView(conversation: chat))
    window.ignoresMouseEvents = true
    window.orderFront(nil)
    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }

  private func findScroll(_ view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.lazy.compactMap { self.findScroll($0) }.first
  }

  private func cpuTime() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }

  private func wheel(delta: Int32, phase: Int64) {
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
      wheel1: delta, wheel2: 0, wheel3: 0)!
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    scroll?.scrollWheel(with: NSEvent(cgEvent: event)!)
  }

  private func tick() {
    frame += 1
    if scroll == nil { scroll = findScroll(window.contentView!) }
    // Warm up text layout before measuring; this is a benchmark, not a timing assertion.
    guard frame >= 120 else { return }
    guard scroll != nil else { fputs("No transcript scroll view\n", stderr); exit(1) }
    if frame == 120 {
      startCPU = cpuTime()
      startTime = ProcessInfo.processInfo.systemUptime
    }
    let step = frame - 120
    if step == 480 {
      let wall = ProcessInfo.processInfo.systemUptime - startTime
      let cpu = cpuTime() - startCPU
      print(String(format: "360 scroll events: %.3fs CPU, %.3fs wall, %.1f%% of one core",
        cpu, wall, cpu / wall * 100))
      timer?.invalidate()
      NSApp.terminate(nil)
      return
    }
    let gestureFrame = step % 60
    if gestureFrame < 45 {
      wheel(delta: (step / 60).isMultiple(of: 2) ? 24 : -24, phase: gestureFrame == 0 ? 1 : 2)
    } else if gestureFrame == 45 {
      wheel(delta: 0, phase: 4)
    }
  }
}

@main
enum Entry {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = ScrollBenchmark()
    app.delegate = delegate
    app.run()
  }
}
