import Network

/// Observes the system network path without making requests to a probe server.
final class NetworkAvailabilityMonitor {
  private let monitor = NWPathMonitor()

  init(update: @escaping @Sendable (Bool) -> Void) {
    monitor.pathUpdateHandler = { path in
      update(path.status == .satisfied)
    }
    monitor.start(queue: DispatchQueue(label: "PocketMai.network-availability"))
  }

  deinit { monitor.cancel() }
}
