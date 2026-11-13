import AVFoundation
import AVKit
import CoreMedia
import UIKit
import WebKit

/// A real AVKit PiP video preview. The web view stays owned by the same session;
/// PiP receives bounded snapshots, never a second copy of the app or its scripts.
@MainActor
final class WebXDCPictureInPicture: NSObject {
  let sourceView = WebXDCPiPSourceView()
  private weak var session: WebXDCRunningSession?
  private var controller: AVPictureInPictureController?
  private var possibleObservation: NSKeyValueObservation?
  private var timer: Timer?
  private var startupTimeout: Task<Void, Never>?
  private var generation = 0
  private var snapshotInFlight = false
  private var starting = false
  private var paused = false
  private var renderWidth: CGFloat = 480
  private var audioRetention: UUID?

  init(session: WebXDCRunningSession) {
    self.session = session
    super.init()
    sourceView.displayLayer.videoGravity = .resizeAspect
    var timebase: CMTimebase?
    CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
    if let timebase {
      CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
      CMTimebaseSetRate(timebase, rate: 1)
      sourceView.displayLayer.controlTimebase = timebase
    }
  }

  func start() {
    guard !starting, controller?.isPictureInPictureActive != true,
      let session, !session.isStopped else { return }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      session.presentationError = "Picture in Picture is unavailable on this device. Use Minimize to keep the app over the chat."
      return
    }
    guard sourceView.window != nil, session.webView.bounds.width > 0 else {
      session.presentationError = "Open the app before starting Picture in Picture."
      return
    }
    do {
      audioRetention = try BackgroundAudioRetention.acquire()
    } catch {
      session.presentationError = "Could not start Picture in Picture audio: \(error.localizedDescription)"
      return
    }
    starting = true
    paused = false
    generation += 1
    let source = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: sourceView.displayLayer, playbackDelegate: self)
    let controller = AVPictureInPictureController(contentSource: source)
    self.controller = controller
    controller.delegate = self
    controller.requiresLinearPlayback = true
    controller.canStartPictureInPictureAutomaticallyFromInline = false
    possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
      [weak self] _, _ in
      Task { @MainActor in self?.startWhenReady() }
    }
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.captureFrame() }
    }
    captureFrame()
    startupTimeout = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(10)) } catch { return }
      guard let self, starting else { return }
      fail("iOS could not start Picture in Picture. Try again, or use Minimize.")
    }
  }

  func stop() {
    generation += 1
    starting = false
    snapshotInFlight = false
    startupTimeout?.cancel()
    startupTimeout = nil
    timer?.invalidate()
    timer = nil
    possibleObservation = nil
    controller?.delegate = nil
    controller?.stopPictureInPicture()
    controller = nil
    sourceView.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    if let audioRetention { BackgroundAudioRetention.release(audioRetention) }
    audioRetention = nil
  }

  private func startWhenReady() {
    guard starting, controller?.isPictureInPicturePossible == true else { return }
    // KVO can notify more than once while the start animation is in progress.
    possibleObservation = nil
    controller?.startPictureInPicture()
  }

  private func fail(_ message: String) {
    stop()
    session?.present(.floating)
    session?.presentationError = message
  }

  private func captureFrame() {
    guard !paused, !snapshotInFlight, let session, !session.isStopped,
      starting || controller?.isPictureInPictureActive == true else { return }
    if let message = session.pendingApprovalMessage {
      let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).image { context in
        UIColor.secondarySystemBackground.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        ("\(session.app.name)\n\n\(message)" as NSString).draw(
          in: CGRect(x: 20, y: 30, width: 280, height: 180),
          withAttributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.label])
      }
      enqueue(image)
      return
    }
    snapshotInFlight = true
    let capturedGeneration = generation
    let configuration = WKSnapshotConfiguration()
    configuration.snapshotWidth = NSNumber(value: Double(renderWidth / max(1, session.webView.traitCollection.displayScale)))
    configuration.afterScreenUpdates = false
    session.webView.takeSnapshot(with: configuration) { [weak self] image, error in
      guard let self, generation == capturedGeneration else { return }
      snapshotInFlight = false
      if let image { enqueue(image) }
      else if starting, let error { fail("Could not create the app preview: \(error.localizedDescription)") }
      // While backgrounded, WebKit may retain its last frame. Keep that frame
      // instead of replacing it with black or restarting the web app.
    }
  }

  private func enqueue(_ image: UIImage) {
    guard let image = image.cgImage else { return }
    let scale = min(1, 720 / CGFloat(max(image.width, image.height)))
    let width = max(2, Int(CGFloat(image.width) * scale) / 2 * 2)
    let height = max(2, Int(CGFloat(image.height) * scale) / 2 * 2)
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else { return }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
      width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr, let format else { return }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 4),
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing,
      sampleBufferOut: &sample) == noErr, let sample else { return }
    let renderer = sourceView.displayLayer.sampleBufferRenderer
    if renderer.status == .failed { renderer.flush() }
    if renderer.isReadyForMoreMediaData { renderer.enqueue(sample) }
  }
}

extension WebXDCPictureInPicture: @MainActor AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    starting = false
    startupTimeout?.cancel()
    startupTimeout = nil
    session?.present(.pictureInPicture)
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error) {
    fail("Picture in Picture could not start: \(error.localizedDescription)")
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    stop()
    session?.present(.closed)
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    session?.present(.fullScreen)
    completionHandler(session?.isStopped == false)
  }
}

extension WebXDCPictureInPicture: @MainActor AVPictureInPictureSampleBufferPlaybackDelegate {
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
    paused = !playing
    session?.setPlaybackActive(playing)
    pictureInPictureController.invalidatePlaybackState()
    if playing { captureFrame() }
  }

  func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
    CMTimeRange(start: .zero, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { paused }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
    renderWidth = min(720, max(320, CGFloat(newRenderSize.width)))
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { completionHandler() }
}

final class WebXDCPiPSourceView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
  var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}
