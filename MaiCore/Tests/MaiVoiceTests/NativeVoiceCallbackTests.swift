#if os(macOS)
  import Foundation
  @preconcurrency import AVFoundation
  @preconcurrency import Speech
  import MaiCore
  import XCTest
  @testable import MaiVoice

  final class NativeVoiceCallbackTests: XCTestCase {
    /// TCC calls authorization on a background queue even when the request was made on MainActor.
    @MainActor func testSpeechPermissionReplyRunsOnBackgroundQueue() async {
      let authorized = await withCheckedContinuation { continuation in
        let callback = NativeVoiceCallbacks.authorizationReply {
          continuation.resume(returning: $0)
        }
        DispatchQueue.global().async { callback(.authorized) }
      }
      XCTAssertTrue(authorized)
      let denied = await withCheckedContinuation { continuation in
        let callback = NativeVoiceCallbacks.authorizationReply {
          continuation.resume(returning: $0)
        }
        DispatchQueue.global().async { callback(.denied) }
      }
      XCTAssertFalse(denied)
    }

    @MainActor func testRecognitionReplyHopsFromBackgroundQueue() async {
      let input = NativeVoiceInput(settings: .init())
      let received = expectation(description: "Recognition error delivered on MainActor")
      let callback = input.recognitionCallback { event in
        if case .failure(let text) = event, text == "fixture recognition failure" {
          received.fulfill()
        }
      }
      await Task.detached {
        callback(nil, VoiceError.unavailable("fixture recognition failure"))
      }.value
      await fulfillment(of: [received], timeout: 2)
      input.stop()
    }

    @MainActor func testAudioTapRunsOnBackgroundQueueWithoutMicrophone() async throws {
      let received = expectation(description: "Audio level delivered from tap")
      let request = SFSpeechAudioBufferRecognitionRequest()
      let callback = NativeVoiceCallbacks.audioTap(request: request) { event in
        if case .level(let level) = event, level == 0.5 { received.fulfill() }
      }
      try await Task.detached {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        let samples = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<160 { samples[0][i] = 0.5 }
        callback(buffer, AVAudioTime(sampleTime: 0, atRate: 16000))
      }.value
      await fulfillment(of: [received], timeout: 2)
      request.endAudio()
    }
  }
#endif
