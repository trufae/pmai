import Foundation
import MaiCore

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

#if os(macOS) || os(Linux)
  /// One owned process. No shell interpolation; cancellation also stops the child.
  final class VoiceProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    let output = Pipe()
    private let exitEvents = AsyncStream<Void>.makeStream()

    init(_ command: VoiceCommand, environment: [String: String], values: [String: String] = [:]) {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments =
        [command.executable]
        + command.arguments.map { argument in
          values.reduce(argument) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
        }
      process.environment = environment
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      let exited = exitEvents.continuation
      process.terminationHandler = { _ in exited.finish() }
    }

    func start() throws {
      try lock.withLock {
        guard !cancelled else { throw CancellationError() }
        try process.run()
      }
    }

    func stop() {
      lock.withLock {
        cancelled = true
        if process.isRunning {
          process.terminate()
          DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(500)) { [self] in
            lock.withLock {
              if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
          }
        }
      }
    }

    /// waitUntilExit spins a run loop and can miss a wakeup on a cooperative worker.
    /// Foundation reports termination independently of whichever thread drains stdout.
    func waitForExit() async {
      // Reap the child even when the caller is already cancelled.
      await Task.detached { [stream = exitEvents.stream] in
        for await _ in stream {}
      }.value
    }

    func run(input: String? = nil) async throws -> Data {
      try await withTaskCancellationHandler {
        let stdin = input.map { _ in Pipe() }
        if let stdin { process.standardInput = stdin }
        try start()
        do {
          let data = try await Task.detached { [self] in
            if let input, let stdin {
              #if os(macOS)
                _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
              #else
                signal(SIGPIPE, SIG_IGN)
              #endif
              try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
              try stdin.fileHandleForWriting.close()
            }
            var data = Data()
            while let chunk = try output.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty
            {
              guard data.count + chunk.count <= 8 * 1024 * 1024 else {
                throw VoiceError.unavailable("Voice program output exceeded 8 MiB.")
              }
              data.append(chunk)
            }
            return data
          }.value
          await waitForExit()
          if lock.withLock({ cancelled }) { throw CancellationError() }
          guard process.terminationStatus == 0 else {
            throw VoiceError.unavailable(
              "Voice program failed (exit \(process.terminationStatus)): \(process.arguments?.first ?? "")."
            )
          }
          return data
        } catch {
          stop()
          await waitForExit()
          throw error
        }
      } onCancel: {
        self.stop()
      }
    }
  }

  func pcmWave(_ pcm: Data) -> Data {
    var data = Data("RIFF".utf8)
    func number<T: FixedWidthInteger>(_ value: T) {
      var value = value.littleEndian
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    number(UInt32(pcm.count + 36))
    data.append(Data("WAVEfmt ".utf8))
    number(UInt32(16))
    number(UInt16(1))
    number(UInt16(1))
    number(UInt32(16000))
    number(UInt32(32000))
    number(UInt16(2))
    number(UInt16(16))
    data.append(Data("data".utf8))
    number(UInt32(pcm.count))
    data.append(pcm)
    return data
  }

  @MainActor final class ProgramVoiceInput: VoiceInputProvider {
    let settings: ConfiguredVoice
    let environment: [String: String]
    let transcribe: @Sendable (Data) async throws -> String
    private var recorder: VoiceProcess?
    private var reading: Task<Data, Error>?

    init(
      settings: ConfiguredVoice, environment: [String: String],
      transcribe: @escaping @Sendable (Data) async throws -> String
    ) {
      self.settings = settings
      self.environment = environment
      self.transcribe = transcribe
    }

    func start(receive: @escaping @Sendable (VoiceInputEvent) -> Void) async throws {
      stop()
      #if os(macOS)
        let fallback = VoiceCommand(
          "sox",
          arguments: [
            "-q", "-d", "-t", "raw", "-r", "16000", "-e", "signed-integer", "-b", "16", "-c", "1",
            "-L", "-",
          ])
      #else
        let fallback = VoiceCommand(
          "arecord", arguments: ["-q", "-t", "raw", "-f", "S16_LE", "-r", "16000", "-c", "1"])
      #endif
      let recorder = VoiceProcess(settings.captureCommand ?? fallback, environment: environment)
      try recorder.start()
      self.recorder = recorder
      let limit = Int(settings.maximumRecordingSeconds * 32000)
      reading = Task.detached {
        var data = Data()
        do {
          while let bytes = try recorder.output.fileHandleForReading.read(upToCount: 3200),
            !bytes.isEmpty
          {
            let remaining = max(0, limit - data.count)
            data.append(bytes.prefix(remaining))
            var peak = 0.0
            let samples = [UInt8](bytes)
            for i in stride(from: 0, to: samples.count - 1, by: 2) {
              let sample = Int16(bitPattern: UInt16(samples[i]) | UInt16(samples[i + 1]) << 8)
              peak = max(peak, abs(Double(sample)) / 32768)
            }
            receive(.level(peak))
            if data.count >= limit {
              recorder.stop()
              break
            }
          }
          await recorder.waitForExit()
          if !Task.isCancelled { receive(.ended) }
          return data
        } catch {
          if !Task.isCancelled { receive(.failure(error.localizedDescription)) }
          throw error
        }
      }
    }
    func finish() async throws -> String {
      let recorder = self.recorder
      self.recorder = nil
      recorder?.stop()
      guard let reading else { return "" }
      self.reading = nil
      let bytes = try await reading.value
      try Task.checkCancellation()
      guard !bytes.isEmpty else {
        throw VoiceError.unavailable(
          "No microphone audio was captured. Check your capture program and device.")
      }
      return try await transcribe(pcmWave(bytes))
    }
    func stop() {
      reading?.cancel()
      reading = nil
      recorder?.stop()
      recorder = nil
    }
  }

  @MainActor final class ProgramVoiceOutput: VoiceOutputProvider {
    let command: VoiceCommand
    let settings: ConfiguredVoice
    let environment: [String: String]
    private var process: VoiceProcess?
    init(command: VoiceCommand, settings: ConfiguredVoice, environment: [String: String]) {
      self.command = command
      self.settings = settings
      self.environment = environment
    }
    func speak(_ text: String) async throws {
      let process = VoiceProcess(
        command, environment: environment,
        values: [
          "text": text, "language": settings.languageIdentifier, "voice": settings.voice,
          "speed": String(settings.speed),
        ])
      self.process = process
      defer { if self.process === process { self.process = nil } }
      let usesArgument = command.arguments.contains { $0.contains("{text}") }
      _ = try await process.run(input: usesArgument ? nil : text)
    }
    func stop() {
      process?.stop()
      process = nil
    }
  }
#endif
