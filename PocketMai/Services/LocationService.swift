import Combine
import CoreLocation
import Foundation

@MainActor
protocol LocationManaging: AnyObject {
  var delegate: (any CLLocationManagerDelegate)? { get set }
  var authorizationStatus: CLAuthorizationStatus { get }
  var accuracyAuthorization: CLAccuracyAuthorization { get }
  var desiredAccuracy: CLLocationAccuracy { get set }
  func requestWhenInUseAuthorization()
  func requestTemporaryFullAccuracyAuthorization(
    withPurposeKey purposeKey: String, completion: (@Sendable (Error?) -> Void)?)
  func requestLocation()
  func stopUpdatingLocation()
}

extension CLLocationManager: LocationManaging {}

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
  @Published private(set) var lastLocationText = ""
  @Published private(set) var authorizationStatus: CLAuthorizationStatus

  @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization

  private struct LocationFix {
    let location: CLLocation
    let reducedAccuracy: Bool
  }

  private let manager: any LocationManaging
  private var continuations:
    [UUID: (precise: Bool, continuation: CheckedContinuation<LocationFix?, Never>)] = [:]
  private var requestPrecision: Bool?
  private var authorizationRequested = false
  private var preciseLocation = true
  private var accuracyRequested = false
  private var isRequestingAccuracy = false
  private var isRequestingLocation = false
  private var timeoutTask: Task<Void, Never>?
  private var prefetchPrecision: Bool?
  private var prefetchedLocation:
    (location: CLLocation, precise: Bool, accuracy: CLAccuracyAuthorization)?
  private let now: () -> Date

  init(manager: any LocationManaging = CLLocationManager(), now: @escaping () -> Date = Date.init) {
    self.manager = manager
    self.now = now
    authorizationStatus = manager.authorizationStatus
    accuracyAuthorization = manager.accuracyAuthorization
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBest
  }

  var permissionText: String {
    switch authorizationStatus {
    case .notDetermined:
      "Location permission has not been requested."
    case .denied:
      "Location access is denied or Location Services are off. Enable access in iOS Settings."
    case .restricted:
      "Location access is restricted on this device."
    case .authorizedWhenInUse, .authorizedAlways:
      accuracyAuthorization == .fullAccuracy
        ? "Precise location access is allowed while using PocketMai."
        : "Only approximate location is allowed. Enable Precise Location in iOS Settings for better accuracy."
    @unknown default:
      "Location access is unavailable."
    }
  }

  func requestAuthorization(precise: Bool = true) {
    // A settings change or another caller must not change an in-flight lookup.
    let precise = requestPrecision ?? precise
    preciseLocation = precise
    manager.desiredAccuracy = precise ? kCLLocationAccuracyBest : kCLLocationAccuracyReduced
    authorizationStatus = manager.authorizationStatus
    accuracyAuthorization = manager.accuracyAuthorization
    if authorizationStatus == .notDetermined {
      guard !authorizationRequested else { return }
      authorizationRequested = true
      manager.requestWhenInUseAuthorization()
    } else {
      requestPreciseAuthorizationIfNeeded()
    }
  }

  private func requestPreciseAuthorizationIfNeeded() {
    guard preciseLocation, manager.accuracyAuthorization == .reducedAccuracy,
      authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways,
      !accuracyRequested, !isRequestingAccuracy
    else { return }
    accuracyRequested = true
    isRequestingAccuracy = true
    manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "PreciseLocation") {
      [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.accuracyRequested = true
        self.isRequestingAccuracy = false
        self.resumeAfterAuthorization()
      }
    }
  }

  func currentLocationText(precise: Bool = true) async -> String {
    guard let fix = await requestLocation(precise: precise) else {
      let authorized =
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
      let reason =
        authorized
        ? "Could not obtain a recent position. Try again with a clear GPS signal." : permissionText
      let text = "Location unavailable. \(reason)"
      lastLocationText = text
      return text
    }
    let location = fix.location
    let approximate = fix.reducedAccuracy || location.horizontalAccuracy > 100
    let text =
      (approximate ? "Approximate location: " : "")
      + String(
        format: "Latitude %.5f, longitude %.5f (accuracy ±%.0f m; measured %@)",
        locale: Locale(identifier: "en_US_POSIX"),
        location.coordinate.latitude, location.coordinate.longitude,
        location.horizontalAccuracy, ISO8601DateFormatter().string(from: location.timestamp))
    lastLocationText = text
    return text
  }

  func currentCoordinate(precise: Bool = true) async -> CLLocationCoordinate2D? {
    await requestLocation(precise: precise)?.location.coordinate
  }

  func prefetch(precise: Bool) {
    guard
      manager.authorizationStatus == .authorizedWhenInUse
        || manager.authorizationStatus == .authorizedAlways,
      !precise || manager.accuracyAuthorization == .fullAccuracy,
      continuations.isEmpty, !isRequestingLocation, !isRequestingAccuracy,
      recentPrefetchedLocation(precise: precise) == nil
    else { return }
    prefetchPrecision = precise
    requestPrecision = precise
    requestAuthorization(precise: precise)
    resumeAfterAuthorization()
  }

  private func recentPrefetchedLocation(precise: Bool) -> LocationFix? {
    guard let prefetchedLocation, prefetchedLocation.precise == precise,
      prefetchedLocation.accuracy == manager.accuracyAuthorization,
      manager.authorizationStatus == .authorizedWhenInUse
        || manager.authorizationStatus == .authorizedAlways,
      isRecent(
        prefetchedLocation.location,
        reducedAccuracy:
          !precise || prefetchedLocation.accuracy == .reducedAccuracy)
    else { return nil }
    return LocationFix(
      location: prefetchedLocation.location,
      reducedAccuracy: !precise || prefetchedLocation.accuracy == .reducedAccuracy)
  }

  private func isRecent(_ location: CLLocation, reducedAccuracy: Bool) -> Bool {
    // Reduced accuracy positions are refreshed only a few times per hour.
    let maximumAge: TimeInterval = reducedAccuracy ? 30 * 60 : 30
    let age = now().timeIntervalSince(location.timestamp)
    return location.horizontalAccuracy >= 0 && age >= -30 && age <= maximumAge
  }

  private func requestLocation(precise: Bool) async -> LocationFix? {
    guard !Task.isCancelled else { return nil }
    if let location = recentPrefetchedLocation(precise: precise) { return location }
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: nil)
          return
        }
        continuations[id] = (precise, continuation)
        if requestPrecision == nil { requestPrecision = precise }
        requestAuthorization(precise: precise)
        resumeAfterAuthorization()
      }
    } onCancel: {
      Task { @MainActor in
        guard let pending = self.continuations.removeValue(forKey: id) else { return }
        pending.continuation.resume(returning: nil)
        if !self.continuations.values.contains(where: { $0.precise == self.requestPrecision }) {
          self.stopRequest()
          self.startNextRequest()
        }
      }
    }
  }

  private func resumeAfterAuthorization() {
    authorizationStatus = manager.authorizationStatus
    accuracyAuthorization = manager.accuracyAuthorization
    guard !continuations.isEmpty || prefetchPrecision != nil else { return }
    switch authorizationStatus {
    case .notDetermined:
      // Keep the first message pending until the user answers the system prompt.
      return
    case .authorizedWhenInUse, .authorizedAlways:
      if !continuations.values.contains(where: { $0.precise == requestPrecision }),
        preciseLocation, accuracyAuthorization != .fullAccuracy
      {
        finishRequest(with: nil)
        return
      }
      requestPreciseAuthorizationIfNeeded()
      guard !isRequestingAccuracy, !isRequestingLocation else { return }
      isRequestingLocation = true
      timeoutTask = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        self?.finishRequest(with: nil)
      }
      manager.requestLocation()
    default:
      finishRequest(with: nil)
    }
  }

  private func stopRequest() {
    timeoutTask?.cancel()
    timeoutTask = nil
    if isRequestingLocation { manager.stopUpdatingLocation() }
    isRequestingLocation = false
    accuracyRequested = false
    prefetchPrecision = nil
    requestPrecision = nil
  }

  private func startNextRequest() {
    guard let next = continuations.values.first else { return }
    requestPrecision = next.precise
    requestAuthorization(precise: next.precise)
    resumeAfterAuthorization()
  }

  private func finishRequest(with location: CLLocation?) {
    if let location, let precise = prefetchPrecision, precise == preciseLocation {
      prefetchedLocation = (location, precise, manager.accuracyAuthorization)
    }
    let fix = location.map {
      LocationFix(
        location: $0,
        reducedAccuracy: requestPrecision == false
          || manager.accuracyAuthorization == .reducedAccuracy)
    }
    let pending = continuations.filter { $0.value.precise == requestPrecision }
    stopRequest()
    for (id, request) in pending {
      continuations.removeValue(forKey: id)
      request.continuation.resume(returning: fix)
    }
    startNextRequest()
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    Task { @MainActor in
      if self.manager.authorizationStatus != .notDetermined { authorizationRequested = false }
      resumeAfterAuthorization()
    }
  }

  nonisolated func locationManager(
    _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
  ) {
    Task { @MainActor in
      guard isRequestingLocation else { return }
      // Never describe an old cached fix as the user's current position.
      let reducedAccuracy =
        requestPrecision == false || self.manager.accuracyAuthorization == .reducedAccuracy
      let location = locations.last { self.isRecent($0, reducedAccuracy: reducedAccuracy) }
      finishRequest(with: location)
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    Task { @MainActor in
      guard isRequestingLocation else { return }
      finishRequest(with: nil)
    }
  }
}
