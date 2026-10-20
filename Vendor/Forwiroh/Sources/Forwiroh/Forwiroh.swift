import CForwiroh
import Foundation

/// An embedded networking endpoint. Keep it alive while tunnels are in use and
/// await close() before opening the same state directory in another process.
public final class Forwiroh: Sendable {
    private let handle: CoreHandle
    /// Single-consumer stream. A resync event means fetch status/pending again.
    /// Cancelling the consumer stops observation; close() stops networking.
    public let events: AsyncStream<CoreEvent>

    private init(handle: CoreHandle) {
        self.handle = handle
        let (stream, continuation) = AsyncStream<CoreEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
        events = stream
        // Only the handle is retained by this reader, so dropping Forwiroh can
        // still shut it down. A dedicated thread avoids starving command work.
        Thread.detachNewThread {
            defer { continuation.finish() }
            while true {
                do {
                    let value: JSONValue? = try handle.call { pointer in
                        guard let raw = forwiroh_next_event(pointer) else { return nil }
                        return try ownedJSON(raw)
                    }
                    guard let value else { return }
                    let event = CoreEvent(name: value["event"]?.string ?? "unknown", payload: value)
                    switch continuation.yield(event) {
                    case .terminated: return
                    case .dropped:
                        continuation.yield(CoreEvent(name: "resync", payload: .object(["event": .string("resync")])))
                    default: break
                    }
                } catch { return }
            }
        }
    }

    deinit { handle.close() }

    /// If identity is supplied it must be a persistent 32-byte seed, kept in the
    /// app's Keychain/Keystore. Otherwise the core persists an owner-only file.
    public static func open(stateDirectory: URL, name: String, identity: Data? = nil) async throws -> Forwiroh {
        guard stateDirectory.isFileURL else { throw ForwirohError("State directory must be a file URL") }
        let path = stateDirectory.path
        try validateCString(path)
        try validateCString(name)
        if let identity, identity.count != 32 { throw ForwirohError("Identity must contain exactly 32 bytes") }
        #if os(iOS) || os(Android)
        guard identity != nil else { throw ForwirohError("Supply a persistent Keychain/Keystore identity on mobile") }
        #endif
        return try await onWorker {
            var error: UnsafeMutablePointer<CChar>?
            let pointer = path.withCString { path in
                name.withCString { name in
                    if let identity {
                        return identity.withUnsafeBytes { bytes in
                            forwiroh_open(path, name, bytes.bindMemory(to: UInt8.self).baseAddress, &error)
                        }
                    }
                    return forwiroh_open_desktop(path, name, &error)
                }
            }
            defer { forwiroh_string_free(error) }
            guard let pointer else {
                let message = error.map { String(cString: $0) } ?? "Cannot start networking"
                let value = try? JSONDecoder().decode(JSONValue.self, from: Data(message.utf8))
                throw ForwirohError(value?["error"]?.string ?? message)
            }
            return Forwiroh(handle: CoreHandle(pointer: pointer))
        }
    }

    public static var version: String { String(cString: forwiroh_version()) }

    public static func cryptoInfo() throws -> JSONValue { try ownedJSON(forwiroh_crypto_info()) }

    public static func qrCode(_ text: String) throws -> QRCode {
        try validateCString(text)
        return try text.withCString { try response(ownedJSON(forwiroh_qr_code($0))).decode(QRCode.self) }
    }

    /// Commands remain concurrent so approval/cancellation can complete while a
    /// pair operation waits. Task cancellation does not cancel a core operation;
    /// use cancelPair(), stopTunnel(), stopVPN(), or close() as appropriate.
    public func command(_ command: [String: JSONValue]) async throws -> JSONValue {
        let data = try JSONEncoder().encode(command)
        let json = String(decoding: data, as: UTF8.self)
        try validateCString(json)
        return try await onWorker { [handle] in
            try handle.call { pointer in
                try json.withCString { try response(ownedJSON(forwiroh_command(pointer, $0))) }
            }
        }
    }

    private func request(_ op: String, _ fields: [String: JSONValue] = [:]) async throws -> JSONValue {
        var command = fields
        command["op"] = .string(op)
        return try await self.command(command)
    }
    private func identifier(_ op: String, _ fields: [String: JSONValue]) async throws -> String {
        let value = try await request(op, fields)
        guard let id = value["id"]?.string else { throw ForwirohError("Missing core identifier") }
        return id
    }

    public func status() async throws -> Status { try await request("status").decode(Status.self) }
    public func invite() async throws -> Invitation { try await request("invite").decode(Invitation.self) }
    /// Permissions applied atomically when new peers pair in either direction.
    /// Set before inviting or pairing. Existing peers keep their saved policy.
    /// Requires core 0.1.1 or later; this setting lasts until close().
    public func setPairingPolicy(_ policy: PeerPolicy) async throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(policy))
        _ = try await request("pairing_policy", ["policy": value])
    }
    public func pendingPairings() async throws -> [PairingRequest] {
        try await request("pending").decode([PairingRequest].self)
    }
    public func cancelInvitation(id: String) async throws { _ = try await request("cancel_invite", ["id": .string(id)]) }
    @discardableResult
    public func pair(invitation: String, device: String) async throws -> String {
        try await identifier("pair", ["uri": .string(invitation), "device": .string(device)])
    }
    public func cancelPair() async throws { _ = try await request("cancel_pair") }
    public func approve(id: String, accept: Bool = true) async throws {
        _ = try await request("approve", ["id": .string(id), "accept": .bool(accept)])
    }
    public func rename(peer: String, name: String) async throws {
        _ = try await request("rename", ["peer": .string(peer), "name": .string(name)])
    }
    public func revoke(peer: String) async throws { _ = try await request("revoke", ["peer": .string(peer)]) }
    public func disconnect(peer: String) async throws { _ = try await request("disconnect", ["peer": .string(peer)]) }
    public func services(peer: String) async throws -> JSONValue { try await request("services", ["peer": .string(peer)]) }
    public func setPolicy(peer: String, policy: PeerPolicy) async throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(policy))
        _ = try await request("policy", ["peer": .string(peer), "policy": value])
    }
    public func allow(peer: String, service: String, destination: String) async throws {
        _ = try await request("allow", ["peer": .string(peer), "service": .string(service), "destination": .string(destination)])
    }

    /// Listen is a numeric IP:port. Service is a name or destination IP:port on the peer.
    @discardableResult
    public func forward(peer: String, listen: String = "127.0.0.1:0", service: String) async throws -> String {
        try await identifier("forward", ["peer": .string(peer), "listen": .string(listen), "service": .string(service)])
    }
    @discardableResult
    public func reverse(peer: String, port: UInt16, target: String) async throws -> String {
        try await identifier("reverse", ["peer": .string(peer), "port": .integer(Int64(port)), "target": .string(target)])
    }
    @discardableResult
    public func socks(peer: String, listen: String = "127.0.0.1:1080") async throws -> String {
        try await identifier("socks", ["peer": .string(peer), "listen": .string(listen)])
    }
    public func stopTunnel(id: String) async throws { _ = try await request("stop", ["id": .string(id)]) }
    public func networkChanged() async throws { _ = try await request("network_change") }

    /// Starts packet transport; the host app owns its NetworkExtension/VpnService.
    public func startVPN(peer: String, routes: [String]) async throws -> VPNSession {
        try await request("vpn_start", ["peer": .string(peer), "routes": .array(routes.map(JSONValue.string))]).decode(VPNSession.self)
    }
    public func stopVPN(id: String) async throws { _ = try await request("stop_vpn", ["id": .string(id)]) }
    public func vpnStats(id: String) async throws -> JSONValue { try await request("vpn_stats", ["id": .string(id)]) }
    public func sendPacket(session: String, data: Data) async throws {
        try validateCString(session)
        guard !data.isEmpty, data.count <= 65_535 else { throw ForwirohError("Invalid packet size") }
        try await onWorker { [handle] in
            try handle.call { pointer in
                let result = session.withCString { session in
                    data.withUnsafeBytes { forwiroh_send_packet(pointer, session, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
                }
                guard result == 0 else { throw ForwirohError("Cannot send VPN packet") }
            }
        }
    }
    /// Nil means the session closed. Errors (including unknown sessions) throw.
    public func receivePacket(session: String) async throws -> Data? {
        try validateCString(session)
        return try await onWorker { [handle] in
            try handle.call { pointer in
                var bytes = [UInt8](repeating: 0, count: 65_535)
                let count = session.withCString { session in
                    bytes.withUnsafeMutableBufferPointer { forwiroh_receive_packet(pointer, session, $0.baseAddress, $0.count) }
                }
                guard count >= 0 else { throw ForwirohError("Cannot receive VPN packet") }
                return count == 0 ? nil : Data(bytes.prefix(Int(count)))
            }
        }
    }

    /// Idempotent; every concurrent close waits for shutdown and all FFI readers.
    public func close() async { try? await onWorker { [handle] in handle.close() } }

    #if os(Android)
    /// Call from a JNI entry point on its current thread before open(). Supply
    /// JNIEnv* and the Application jobject; the core retains a global reference.
    /// A JNI exception remains pending if initialization fails; the host must check it.
    public static func initializeAndroid(environment: UnsafeMutableRawPointer, application: UnsafeMutableRawPointer) {
        forwiroh_android_init(environment, application)
    }
    #endif
}
