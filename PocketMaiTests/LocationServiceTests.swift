import CoreLocation
import XCTest

@testable import PocketMai

@MainActor
final class LocationServiceTests: XCTestCase {
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
  var desiredAccuracy: CLLocationAccuracy = 0
  var onAuthorizationCheck: (() -> Void)?
  var onAuthorizationRequest: (() -> Void)?
  var onLocationRequest: (() -> Void)?
  // Only supplies the delegate API's concrete parameter; it never requests access.
  private let callbackManager = CLLocationManager()

  init(status: CLAuthorizationStatus) { self.status = status }
  func requestWhenInUseAuthorization() { onAuthorizationRequest?() }
  func requestLocation() { onLocationRequest?() }
  func stopUpdatingLocation() {}

  func changeAuthorization(to status: CLAuthorizationStatus) {
    self.status = status
    delegate?.locationManagerDidChangeAuthorization?(callbackManager)
  }

  func deliver(latitude: Double, longitude: Double, timestamp: Date = Date()) {
    let location = CLLocation(
      coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
      altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: timestamp)
    delegate?.locationManager?(callbackManager, didUpdateLocations: [location])
  }

  func fail() {
    delegate?.locationManager?(callbackManager, didFailWithError: CLError(.locationUnknown))
  }
}
