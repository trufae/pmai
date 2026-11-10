import Combine
import CoreLocation
import XCTest

@testable import PocketMai

@MainActor
final class LocationServiceTests: XCTestCase {
  func testSentMessageCanQueueAndStopWhileGPSContextIsPending() async throws {
    try await checkSubmissionWhileGPSContextIsPending(stop: true)
  }

  func testQueuedMessageRunsAfterGPSContextCompletes() async throws {
    try await checkSubmissionWhileGPSContextIsPending(stop: false)
  }

  private func checkSubmissionWhileGPSContextIsPending(stop: Bool) async throws {
    StubChatEndpoint.install()
    defer { StubChatEndpoint.uninstall() }
    StubChatEndpoint.script = { _ in (StubChatEndpoint.completion(content: "Done"), 0) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = PersistenceStore(localBaseURL: root)
    let store = AppStore(persistence: persistence, monitorNetwork: false)
    let deadline = Date().addingTimeInterval(10)
    while !store.hasLoadedPersistedSettings {
      guard Date() < deadline else { throw URLError(.timedOut) }
      try await Task.sleep(for: .milliseconds(20))
    }
    await store.loadStoredConversationsForSearch()
    let endpoint = OpenAIEndpoint(name: "Fixture", baseURL: "https://\(StubChatEndpoint.host)/v1")
    store.settings.openAIEndpoints = [endpoint]
    store.settings.toolSettings.useGPSLocation = true
    store.settings.agents[0].canSpawnSubagents = false
    store.settings.followUps.autoGenerate = false
    store.settings.background.liveActivityEnabled = false
    store.newConversation()
    store.updateCurrentConversation {
      $0.provider = .openAICompatible
      $0.endpointID = endpoint.id
      $0.modelID = "test"
      $0.usesStreaming = false
      $0.toolsEnabled = true
      $0.enabledTools = [.location]
      $0.enabledMCPServers = []
    }
    let id = try XCTUnwrap(store.currentConversation?.id)
    let manager = StubLocationManager(status: .authorizedWhenInUse)
    store.locationService = LocationService(manager: manager)
    let requested = expectation(description: "GPS context requested")
    manager.onLocationRequest = { requested.fulfill() }
    let attachment = ChatAttachment.textFile(filename: "note.txt", text: "Attached note")
    let accepted = await store.send(prompt: "Hello", attachments: [attachment])
    defer { store.cancelResponse(in: id) }
    XCTAssertTrue(accepted)
    // The composer must offer queue/stop as soon as submission returns, even
    // before the background task has started requesting context.
    XCTAssertTrue(store.isResponding(in: id))
    XCTAssertTrue(store.enqueueUserMessage(prompt: "Next", attachments: [attachment], in: id))
    await fulfillment(of: [requested], timeout: 10)

    let message = try XCTUnwrap(store.currentConversation?.messages.last)
    XCTAssertEqual(message.role, .user)
    XCTAssertEqual(message.text, "Hello")
    XCTAssertEqual(message.attachments, [attachment])
    XCTAssertTrue(store.isResponding(in: id))
    let queued = try XCTUnwrap(store.queuedUserMessages(in: id).first)
    XCTAssertEqual(queued.text, "Next")
    XCTAssertEqual(queued.attachments, [attachment])
    persistence.flushPendingWrites()
    let saved = try XCTUnwrap(persistence.loadConversation(id: id)?.messages)
    XCTAssertEqual(saved.map(\.id), [message.id])
    XCTAssertEqual(saved.first?.text, message.text)
    XCTAssertEqual(saved.first?.attachments, [attachment])

    let finished = expectation(description: "Response finished")
    let observation = store.$respondingConversationIDs
      .filter { !$0.contains(id) }.prefix(1).sink { _ in finished.fulfill() }
    defer { observation.cancel() }
    if stop {
      store.cancelResponse(in: id)
    } else {
      manager.deliver(latitude: 41, longitude: 2)
    }
    await fulfillment(of: [finished], timeout: 15)
    XCTAssertFalse(store.isResponding(in: id))
    if stop {
      XCTAssertEqual(store.currentConversation?.messages, [message])
      XCTAssertEqual(store.queuedUserMessages(in: id), [queued])
      XCTAssertTrue(StubChatEndpoint.requests.isEmpty)
    } else {
      let messages = try XCTUnwrap(store.currentConversation?.messages)
      XCTAssertEqual(messages.filter { $0.role == .user }.map(\.text), ["Hello", "Next"])
      XCTAssertEqual(messages.filter { $0.role == .user }.last?.attachments, [attachment])
      XCTAssertEqual(messages.last?.role, .assistant)
      XCTAssertEqual(messages.last?.text, "Done")
      XCTAssertTrue(store.queuedUserMessages(in: id).isEmpty)
    }
  }

  func testPrefetchedLocationIsReusedUntilItsMeasuredPositionExpires() async {
    var now = Date(timeIntervalSince1970: 2_000)
    let manager = StubLocationManager(status: .authorizedWhenInUse)
    let service = LocationService(manager: manager, now: { now })
    manager.onLocationRequest = { manager.deliver(latitude: 41, longitude: 2, timestamp: now) }
    service.prefetch(precise: true)
    manager.onLocationRequest = { XCTFail("Sending must share the pending GPS request") }
    let first = await service.currentLocationText()
    XCTAssertTrue(first.contains("Latitude 41.00000"))

    manager.onLocationRequest = { XCTFail("A recent prefetch must not start another lookup") }
    service.prefetch(precise: true)
    let cached = await service.currentLocationText()
    XCTAssertEqual(cached, first)

    now.addTimeInterval(31)
    manager.onLocationRequest = { manager.deliver(latitude: 42, longitude: 3, timestamp: now) }
    let refreshed = await service.currentLocationText()
    XCTAssertTrue(refreshed.contains("Latitude 42.00000"))
  }

  func testPrefetchDoesNotRequestLocationOrAccuracyPermissionWhileTyping() {
    for status in [CLAuthorizationStatus.notDetermined, .denied, .restricted, .authorizedWhenInUse]
    {
      let manager = StubLocationManager(status: status)
      manager.accuracyAuthorization = .reducedAccuracy
      let service = LocationService(manager: manager)
      manager.onAuthorizationRequest = { XCTFail("Typing must not prompt for location permission") }
      manager.onAccuracyRequest = { XCTFail("Typing must not prompt for precise permission") }
      manager.onLocationRequest = { XCTFail("GPS must wait for the configured permissions") }
      service.prefetch(precise: true)
    }
  }

  func testPrefetchRespectsAccuracyChangesAndRevokedPermission() async {
    let now = Date(timeIntervalSince1970: 2_000)
    let manager = StubLocationManager(status: .authorizedWhenInUse)
    let service = LocationService(manager: manager, now: { now })
    manager.onLocationRequest = { manager.deliver(latitude: 41, longitude: 2, timestamp: now) }
    service.prefetch(precise: false)
    let approximate = await service.currentCoordinate(precise: false)
    XCTAssertEqual(approximate?.latitude, 41)

    manager.onLocationRequest = { manager.deliver(latitude: 42, longitude: 3, timestamp: now) }
    let precise = await service.currentCoordinate()
    XCTAssertEqual(precise?.latitude, 42)

    manager.changeAuthorization(to: .denied)
    manager.onLocationRequest = { XCTFail("Revoked permission must prevent GPS access") }
    let denied = await service.currentCoordinate(precise: false)
    XCTAssertNil(denied)
  }

  // These cases prevent missing first-message context, stale positions, and
  // hanging sends when chat and weather request the shared location together.
  func testFirstMessageWaitsForPermissionAndIncludesTheGrantedLocation() async throws {
    let manager = StubLocationManager(status: .notDetermined)
    let service = LocationService(manager: manager)
    let permission = expectation(description: "System permission requested")
    manager.onAuthorizationRequest = { permission.fulfill() }
    let fix = expectation(description: "Position requested after permission")
    manager.onLocationRequest = {
      fix.fulfill()
      manager.deliver(latitude: 41.40363, longitude: 2.17436)
    }
    let request = Task { await service.currentLocationText() }
    await fulfillment(of: [permission], timeout: 10)
    manager.changeAuthorization(to: .authorizedWhenInUse)
    await fulfillment(of: [fix], timeout: 10)
    let text = await request.value
    XCTAssertTrue(text.contains("Latitude 41.40363, longitude 2.17436"), text)
    XCTAssertTrue(text.contains("accuracy ±5 m; measured"), text)
    XCTAssertEqual(service.lastLocationText, text)
  }

  func testPreciseLocationWaitsForAccuracyPermissionAfterInitialAuthorization() async {
    let manager = StubLocationManager(status: .notDetermined)
    manager.accuracyAuthorization = .reducedAccuracy
    let service = LocationService(manager: manager)
    let permission = expectation(description: "Location permission requested")
    manager.onAuthorizationRequest = { permission.fulfill() }
    let accuracy = expectation(description: "Precise permission requested")
    manager.onAccuracyRequest = { accuracy.fulfill() }
    manager.onLocationRequest = { XCTFail("Must wait for the accuracy prompt") }
    let request = Task { await service.currentLocationText() }
    await fulfillment(of: [permission], timeout: 10)
    manager.changeAuthorization(to: .authorizedWhenInUse)
    await fulfillment(of: [accuracy], timeout: 10)
    manager.onLocationRequest = { manager.deliver(latitude: 41.40363, longitude: 2.17436) }
    manager.completeAccuracyRequest(granted: true)
    let text = await request.value
    XCTAssertTrue(text.contains("Latitude 41.40363, longitude 2.17436"), text)
    XCTAssertEqual(service.accuracyAuthorization, .fullAccuracy)
    XCTAssertEqual(manager.desiredAccuracy, kCLLocationAccuracyBest)
  }

  func testDecliningPreciseLocationStillCompletesWithAnApproximatePosition() async {
    let now = Date(timeIntervalSince1970: 2_000)
    let manager = StubLocationManager(status: .authorizedWhenInUse)
    manager.accuracyAuthorization = .reducedAccuracy
    let service = LocationService(manager: manager, now: { now })
    let accuracy = expectation(description: "Precise permission requested")
    manager.onAccuracyRequest = { accuracy.fulfill() }
    manager.onLocationRequest = {
      manager.deliver(
        latitude: 41.4, longitude: 2.2,
        timestamp: now.addingTimeInterval(-15 * 60), accuracy: 5000)
    }
    let request = Task { await service.currentLocationText() }
    await fulfillment(of: [accuracy], timeout: 10)
    manager.onAccuracyRequest = { XCTFail("Must not repeat a declined prompt during this lookup") }
    manager.completeAccuracyRequest(granted: false)
    let text = await request.value
    XCTAssertTrue(text.contains("Approximate location"), text)
    XCTAssertTrue(text.contains("accuracy ±5000 m"), text)
    XCTAssertTrue(service.permissionText.contains("approximate"))
  }

  func testApproximateLocationDoesNotRequestPrecisePermission() async {
    let now = Date(timeIntervalSince1970: 2_000)
    for authorization in [CLAccuracyAuthorization.fullAccuracy, .reducedAccuracy] {
      let manager = StubLocationManager(status: .authorizedWhenInUse)
      manager.accuracyAuthorization = authorization
      let service = LocationService(manager: manager, now: { now })
      manager.onAccuracyRequest = { XCTFail("Approximate mode must not request precise access") }
      manager.onLocationRequest = {
        manager.deliver(
          latitude: 41.4, longitude: 2.2,
          timestamp: now.addingTimeInterval(-15 * 60), accuracy: 5000)
      }
      let text = await service.currentLocationText(precise: false)
      XCTAssertTrue(text.contains("Approximate location"), text)
      XCTAssertTrue(text.contains("accuracy ±5000 m"), text)
      XCTAssertEqual(manager.desiredAccuracy, kCLLocationAccuracyReduced)

      for timestamp in [now.addingTimeInterval(-31 * 60), now.addingTimeInterval(60)] {
        manager.onLocationRequest = {
          manager.deliver(latitude: 41.4, longitude: 2.2, timestamp: timestamp, accuracy: 5000)
        }
        let unavailable = await service.currentLocationText(precise: false)
        XCTAssertTrue(unavailable.contains("Location unavailable"), unavailable)
      }
    }
  }

  // Approximate fixes must remain usable between iOS updates, including when
  // prefetched, without extending the lifetime of precise or expired fixes.
  func testApproximatePrefetchExpiresFromItsMeasurementTime() async {
    var now = Date(timeIntervalSince1970: 2_000)
    let measured = now.addingTimeInterval(-15 * 60)
    let manager = StubLocationManager(status: .authorizedWhenInUse)
    let service = LocationService(manager: manager, now: { now })
    manager.onLocationRequest = {
      manager.deliver(latitude: 41, longitude: 2, timestamp: measured, accuracy: 5000)
    }
    service.prefetch(precise: false)
    let first = await service.currentLocationText(precise: false)
    XCTAssertTrue(first.contains("Latitude 41.00000"), first)
    XCTAssertTrue(first.contains(ISO8601DateFormatter().string(from: measured)), first)

    now.addTimeInterval(14 * 60)
    manager.onLocationRequest = { XCTFail("A valid approximate prefetch should be reused") }
    let cached = await service.currentLocationText(precise: false)
    XCTAssertEqual(cached, first)

    now.addTimeInterval(2 * 60)
    manager.onLocationRequest = {
      manager.deliver(latitude: 42, longitude: 3, timestamp: now, accuracy: 5000)
    }
    let refreshed = await service.currentLocationText(precise: false)
    XCTAssertTrue(refreshed.contains("Latitude 42.00000"), refreshed)
  }

  func testPoorAccuracyIsLabeledWithoutRelaxingPreciseFreshness() async {
    let now = Date(timeIntervalSince1970: 2_000)
    let manager = StubLocationManager(status: .authorizedWhenInUse)
    let service = LocationService(manager: manager, now: { now })
    manager.onLocationRequest = {
      manager.deliver(latitude: 41, longitude: 2, timestamp: now, accuracy: 5000)
    }
    let coarse = await service.currentLocationText()
    XCTAssertTrue(coarse.contains("Approximate location"), coarse)
    XCTAssertTrue(coarse.contains("accuracy ±5000 m"), coarse)

    manager.onLocationRequest = {
      manager.deliver(
        latitude: 41, longitude: 2,
        timestamp: now.addingTimeInterval(-60), accuracy: 5000)
    }
    let expired = await service.currentLocationText()
    XCTAssertTrue(expired.contains("Location unavailable"), expired)
  }

  // Switching settings while chat/weather are waiting must not share precise
  // coordinates with an approximate caller, or return the old coarse fix as precise.
  func testOverlappingPrecisionModesReceiveSeparateFixes() async {
    for firstPrecise in [true, false] {
      let manager = StubLocationManager(status: .authorizedWhenInUse)
      let service = LocationService(manager: manager)
      let requested = expectation(description: "First mode requested")
      manager.onLocationRequest = { requested.fulfill() }
      let first = Task { await service.currentLocationText(precise: firstPrecise) }
      await fulfillment(of: [requested], timeout: 10)

      service.requestAuthorization(precise: !firstPrecise)
      let joined = expectation(description: "Other mode queued")
      let second = Task {
        manager.onAuthorizationCheck = { joined.fulfill() }
        return await service.currentLocationText(precise: !firstPrecise)
      }
      await fulfillment(of: [joined], timeout: 10)
      manager.onLocationRequest = {
        manager.deliver(latitude: 42, longitude: 3, accuracy: firstPrecise ? 5000 : 5)
      }
      XCTAssertEqual(
        manager.desiredAccuracy,
        firstPrecise ? kCLLocationAccuracyBest : kCLLocationAccuracyReduced)
      manager.deliver(latitude: 41, longitude: 2, accuracy: firstPrecise ? 5 : 5000)
      let firstText = await first.value
      let secondText = await second.value
      XCTAssertTrue(firstText.contains("Latitude 41.00000"), firstText)
      XCTAssertTrue(secondText.contains("Latitude 42.00000"), secondText)
      XCTAssertEqual(firstText.contains("Approximate location"), !firstPrecise)
      XCTAssertEqual(secondText.contains("Approximate location"), firstPrecise)
    }
  }

  func testCancellationWithDifferentPrecisionLeavesTheOtherCallerAlive() async {
    for cancelActive in [true, false] {
      let manager = StubLocationManager(status: .authorizedWhenInUse)
      let service = LocationService(manager: manager)
      let requested = expectation(description: "Precise lookup requested")
      manager.onLocationRequest = { requested.fulfill() }
      let first = Task { await service.currentCoordinate() }
      await fulfillment(of: [requested], timeout: 10)

      let joined = expectation(description: "Approximate caller queued")
      let second = Task {
        manager.onAuthorizationCheck = { joined.fulfill() }
        return await service.currentCoordinate(precise: false)
      }
      await fulfillment(of: [joined], timeout: 10)
      manager.onLocationRequest = { manager.deliver(latitude: 42, longitude: 3, accuracy: 5000) }
      let cancelled = cancelActive ? first : second
      cancelled.cancel()
      let cancelledResult = await cancelled.value
      XCTAssertNil(cancelledResult)
      if !cancelActive { manager.deliver(latitude: 41, longitude: 2) }
      let survivor = await (cancelActive ? second : first).value
      XCTAssertEqual(survivor?.latitude, cancelActive ? 42 : 41)
    }
  }

  func testPreciseRequestDoesNotReuseAnInFlightApproximatePrefetch() async {
    let manager = StubLocationManager(status: .authorizedWhenInUse)
    let service = LocationService(manager: manager)
    service.prefetch(precise: false)
    let joined = expectation(description: "Precise caller queued behind prefetch")
    let request = Task {
      manager.onAuthorizationCheck = { joined.fulfill() }
      return await service.currentLocationText()
    }
    await fulfillment(of: [joined], timeout: 10)
    manager.onLocationRequest = { manager.deliver(latitude: 42, longitude: 3) }
    manager.deliver(latitude: 41, longitude: 2, accuracy: 5000)
    let text = await request.value
    XCTAssertTrue(text.contains("Latitude 42.00000"), text)
    XCTAssertFalse(text.contains("Approximate location"), text)
  }

  func testDenialAndRestrictionsReturnActionableContextWithoutRequestingGPS() async {
    for status in [CLAuthorizationStatus.denied, .restricted] {
      let manager = StubLocationManager(status: status)
      let service = LocationService(manager: manager)
      manager.onAuthorizationRequest = { XCTFail("Must not repeat a denied permission prompt") }
      manager.onLocationRequest = { XCTFail("Must not request a position without permission") }
      let text = await service.currentLocationText()
      XCTAssertTrue(text.contains("Location unavailable"))
      XCTAssertTrue(text.contains(status == .denied ? "iOS Settings" : "restricted"))
    }
  }

  func testDenyingFirstPermissionCompletesThePendingMessage() async {
    let manager = StubLocationManager(status: .notDetermined)
    let service = LocationService(manager: manager)
    let permission = expectation(description: "Permission requested")
    manager.onAuthorizationRequest = { permission.fulfill() }
    let request = Task { await service.currentLocationText() }
    await fulfillment(of: [permission], timeout: 10)
    manager.changeAuthorization(to: .denied)
    let text = await request.value
    XCTAssertTrue(text.contains("iOS Settings"))
  }

  func testOverlappingRequestsBothCompleteAndCancellationLeavesTheOtherRequestAlive() async throws {
    let manager = StubLocationManager(status: .authorizedWhenInUse)
    let service = LocationService(manager: manager)
    let requested = expectation(description: "First position requested")
    manager.onLocationRequest = { requested.fulfill() }
    let first = Task { await service.currentCoordinate() }
    await fulfillment(of: [requested], timeout: 10)
    let joined = expectation(description: "Second caller joined the pending lookup")
    let second = Task {
      manager.onAuthorizationCheck = { joined.fulfill() }
      return await service.currentCoordinate()
    }
    await fulfillment(of: [joined], timeout: 10)
    manager.deliver(latitude: 41, longitude: 2)
    let firstCoordinate = await first.value
    let secondCoordinate = await second.value
    XCTAssertEqual(firstCoordinate?.latitude, 41)
    XCTAssertEqual(secondCoordinate?.latitude, 41)

    let pending = expectation(description: "Next lookup requested")
    manager.onLocationRequest = { pending.fulfill() }
    let cancelled = Task { await service.currentCoordinate() }
    await fulfillment(of: [pending], timeout: 10)
    let otherJoined = expectation(description: "Other caller joined")
    let survivor = Task {
      manager.onAuthorizationCheck = { otherJoined.fulfill() }
      return await service.currentCoordinate()
    }
    await fulfillment(of: [otherJoined], timeout: 10)
    cancelled.cancel()
    let cancelledResult = await cancelled.value
    XCTAssertNil(cancelledResult)
    manager.deliver(latitude: 42, longitude: 3)
    let survivorResult = await survivor.value
    XCTAssertEqual(survivorResult?.latitude, 42)
  }

  func testCancellationWhileAwaitingPermissionCompletesWithoutALocation() async {
    let manager = StubLocationManager(status: .notDetermined)
    let service = LocationService(manager: manager)
    let permission = expectation(description: "Permission requested")
    manager.onAuthorizationRequest = { permission.fulfill() }
    let request = Task { await service.currentCoordinate() }
    await fulfillment(of: [permission], timeout: 10)
    request.cancel()
    let result = await request.value
    XCTAssertNil(result)
  }

  func testFailedOrStaleFixDoesNotReuseThePreviousPosition() async {
    let manager = StubLocationManager(status: .authorizedWhenInUse)
    let service = LocationService(manager: manager)
    manager.onLocationRequest = { manager.deliver(latitude: 41, longitude: 2) }
    let initial = await service.currentLocationText()
    XCTAssertTrue(initial.contains("Latitude 41.00000"))
    manager.onLocationRequest = {
      manager.deliver(latitude: 40, longitude: 1, timestamp: Date(timeIntervalSince1970: 0))
    }
    let stale = await service.currentLocationText()
    XCTAssertTrue(stale.contains("Location unavailable"))
    XCTAssertFalse(stale.contains("Latitude"))
    manager.onLocationRequest = { manager.fail() }
    let failure = await service.currentLocationText()
    XCTAssertTrue(failure.contains("Location unavailable"))
    XCTAssertEqual(service.lastLocationText, failure)
  }

  func testEachMessageReceivesTheUpdatedPositionAndDisabledToolsDoNotAccessGPS() async {
    let manager = StubLocationManager(status: .authorizedWhenInUse)
    let service = LocationService(manager: manager)
    var conversation = Conversation()
    conversation.toolsEnabled = true
    conversation.enabledTools = [.location]
    let settings = AppSettings()
    manager.onLocationRequest = { manager.deliver(latitude: 41, longitude: 2) }
    let first = await ContextBuilder.build(
      input: "What is here?", conversation: conversation, settings: settings,
      locationService: { service })
    manager.onLocationRequest = { manager.deliver(latitude: 42, longitude: 3) }
    let second = await ContextBuilder.build(
      input: "And here?", conversation: conversation, settings: settings,
      locationService: { service })
    XCTAssertTrue(first.text.contains("Latitude 41.00000"))
    XCTAssertTrue(second.text.contains("Latitude 42.00000"))
    conversation.toolsEnabled = false
    let disabled = await ContextBuilder.build(
      input: "No tools", conversation: conversation, settings: settings,
      locationService: {
        XCTFail("Disabled tools accessed GPS")
        return service
      })
    XCTAssertEqual(disabled.text, "")
    conversation.toolsEnabled = true
    conversation.enabledTools = []
    let unselected = await ContextBuilder.build(
      input: "No location", conversation: conversation, settings: settings,
      locationService: {
        XCTFail("Unselected Location accessed GPS")
        return service
      })
    XCTAssertEqual(unselected.text, "")
  }

  func testLocationSettingsDefaultToGPSAndPreserveSavedManualChoices() throws {
    let decoder = JSONDecoder()
    XCTAssertTrue(NativeToolSettings.defaults.preciseLocation)
    XCTAssertTrue(
      try decoder.decode(NativeToolSettings.self, from: Data("{}".utf8)).preciseLocation)
    let approximate = try decoder.decode(
      NativeToolSettings.self, from: Data(#"{"preciseLocation":false}"#.utf8))
    XCTAssertFalse(approximate.preciseLocation)
    XCTAssertEqual(
      try decoder.decode(NativeToolSettings.self, from: JSONEncoder().encode(approximate)),
      approximate)
    XCTAssertTrue(NativeToolSettings.defaults.useGPSLocation)
    XCTAssertTrue(try decoder.decode(NativeToolSettings.self, from: Data("{}".utf8)).useGPSLocation)
    for json in [#"{"useGPSLocation":false}"#, #"{"manualLocation":"Barcelona"}"#] {
      let settings = try decoder.decode(NativeToolSettings.self, from: Data(json.utf8))
      XCTAssertFalse(settings.useGPSLocation)
      XCTAssertEqual(
        try decoder.decode(NativeToolSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
  }
}

@MainActor
private final class StubLocationManager: LocationManaging {
  weak var delegate: (any CLLocationManagerDelegate)?
  private var status: CLAuthorizationStatus
  var authorizationStatus: CLAuthorizationStatus {
    let callback = onAuthorizationCheck
    onAuthorizationCheck = nil
    callback?()
    return status
  }
  var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
  var desiredAccuracy: CLLocationAccuracy = 0
  var onAccuracyRequest: (() -> Void)?
  private var accuracyCompletion: (@Sendable (Error?) -> Void)?
  var onAuthorizationCheck: (() -> Void)?
  var onAuthorizationRequest: (() -> Void)?
  var onLocationRequest: (() -> Void)?
  // Only supplies the delegate API's concrete parameter; it never requests access.
  private let callbackManager = CLLocationManager()

  init(status: CLAuthorizationStatus) { self.status = status }
  func requestWhenInUseAuthorization() { onAuthorizationRequest?() }
  func requestTemporaryFullAccuracyAuthorization(
    withPurposeKey purposeKey: String, completion: (@Sendable (Error?) -> Void)?
  ) {
    XCTAssertEqual(purposeKey, "PreciseLocation")
    accuracyCompletion = completion
    onAccuracyRequest?()
  }

  func completeAccuracyRequest(granted: Bool) {
    accuracyAuthorization = granted ? .fullAccuracy : .reducedAccuracy
    delegate?.locationManagerDidChangeAuthorization?(callbackManager)
    let completion = accuracyCompletion
    accuracyCompletion = nil
    completion?(nil)
  }

  func requestLocation() { onLocationRequest?() }
  func stopUpdatingLocation() {}

  func changeAuthorization(to status: CLAuthorizationStatus) {
    self.status = status
    delegate?.locationManagerDidChangeAuthorization?(callbackManager)
  }

  func deliver(
    latitude: Double, longitude: Double, timestamp: Date = Date(), accuracy: Double = 5
  ) {
    let location = CLLocation(
      coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
      altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5, timestamp: timestamp)
    delegate?.locationManager?(callbackManager, didUpdateLocations: [location])
  }

  func fail() {
    delegate?.locationManager?(callbackManager, didFailWithError: CLError(.locationUnknown))
  }
}
