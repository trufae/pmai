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

    @MainActor func testNoSpeechEndsCaptureWithoutFailureButOtherErrorsRemainFailures() async throws {
      for (domain, code, noSpeech) in [
        ("kAFAssistantErrorDomain", 1110, true),
        ("kAFAssistantErrorDomain", 1101, false),
        ("fixture.other", 1110, false),
      ] {
        let input = NativeVoiceInput(settings: .init())
        let received = expectation(description: "Recognition completion delivered")
        let callback = input.recognitionCallback { event in
          switch event {
          case .ended:
            XCTAssertTrue(noSpeech)
            received.fulfill()
          case .failure:
            XCTAssertFalse(noSpeech)
            received.fulfill()
          default: break
          }
        }
        await Task.detached {
          callback(nil, NSError(domain: domain, code: code,
            userInfo: [NSLocalizedDescriptionKey: "fixture recognition result"]))
        }.value
        await fulfillment(of: [received], timeout: 2)
        if noSpeech {
          let text = try await input.finish()
          XCTAssertEqual(text, "")
        }
        input.stop()
      }
    }
  }
#endif

#if os(macOS)
  extension NativeVoiceCallbackTests {
    @MainActor func testDefaultVoicePrefersInstalledHigherQualityForTheLanguage() {
      let voices: [VoiceCatalogOption] = [
        .init(id: "compact-us", name: "Compact", language: "en-US", quality: "standard"),
        .init(id: "enhanced-us", name: "Enhanced", language: "en-US", quality: "enhanced"),
        .init(id: "premium-gb", name: "Premium", language: "en-GB", quality: "premium"),
        .init(id: "premium-ca", name: "Premium", language: "ca-ES", quality: "premium"),
      ]
      XCTAssertEqual(
        NativeVoiceCatalog.preferredVoiceID(language: "en-US", voices: voices), "premium-gb")
      XCTAssertEqual(
        NativeVoiceCatalog.preferredVoiceID(language: "ca-ES", voices: voices), "premium-ca")
      XCTAssertNil(NativeVoiceCatalog.preferredVoiceID(language: "ja-JP", voices: voices))
    }

    @MainActor func testInstalledCatalogAndSpeechSelectionWithoutPlayingAudio() throws {
      let catalog = NativeVoiceCatalog.catalog(language: "en-US")
      XCTAssertTrue(catalog.languages.contains { $0.id == "en-US" })
      for language in catalog.languages where language.availabilityChecked {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.id))
        XCTAssertEqual(language.unavailableReason == nil, recognizer?.supportsOnDeviceRecognition == true)
      }
      let voice = try XCTUnwrap(catalog.voices.first)
      var settings = ConfiguredVoice()
      settings.voice = voice.id
      settings.speed = 1.25
      let output = NativeVoiceOutput(settings: settings)
      let utterance = try output.utterance("fixture")
      XCTAssertEqual(utterance.voice?.identifier, voice.id)
      XCTAssertGreaterThan(utterance.rate, AVSpeechUtteranceDefaultSpeechRate)
      settings.voice = "missing-voice-fixture"
      XCTAssertThrowsError(try NativeVoiceOutput(settings: settings).utterance("fixture"))
      settings.voice = "en-US"
      XCTAssertThrowsError(try NativeVoiceOutput(settings: settings).utterance("fixture"), "A language tag is not a voice ID")
      settings.voice = "default"
      settings.language = "zz-ZZ"
      XCTAssertThrowsError(try NativeVoiceOutput(settings: settings).utterance("fixture"), "Do not silently speak in another language")
    }

    @MainActor func testUnavailableNativeLanguageFailsBeforeRequestingMicrophoneAccess() async throws {
      guard let locale = SFSpeechRecognizer.supportedLocales().first(where: {
        SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition != true
      }) else { return }
      var settings = ConfiguredVoice()
      settings.language = locale.identifier
      let input = NativeVoiceInput(settings: settings)
      do {
        try await input.start { _ in XCTFail("Unavailable recognizer started") }
        XCTFail("Expected unavailable language")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains("cannot recognize"))
        XCTAssertTrue(error.localizedDescription.contains("on device"))
      }
      input.stop()
    }
  }
#endif
