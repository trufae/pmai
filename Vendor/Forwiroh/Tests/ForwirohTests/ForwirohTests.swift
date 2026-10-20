import Foundation
import Testing
@testable import Forwiroh

@Test func capabilitiesAndQR() throws {
    #expect(!Forwiroh.version.isEmpty)
    #expect(try Forwiroh.cryptoInfo()["identity_algorithm"]?.string == "Ed25519")
    let qr = try Forwiroh.qrCode("forwiroh SwiftPM")
    #expect(qr.width > 0)
    #expect(qr.pixels.count == qr.width * qr.width)
    #expect(qr.pixels.first == true)
    #expect(throws: ForwirohError.self) { try Forwiroh.qrCode("before\0after") }
    #expect(throws: ForwirohError.self) { try Forwiroh.qrCode(String(repeating: "x", count: 5000)) }
}

@Test func responseShapesAndErrors() throws {
    #expect(try response(.object(["data": .null])) == .null)
    #expect(try response(.object(["data": .array([])])) == .array([]))
    #expect(throws: ForwirohError("denied")) { try response(.object(["error": .string("denied")])) }
    #expect(throws: ForwirohError.self) { try response(.object([:])) }
    let policy = PeerPolicy(restricted: true, services: ["ssh": "127.0.0.1:22"], socksPorts: [443])
    let data = try JSONEncoder().encode(policy)
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(value["socks_ports"] == .array([.integer(443)]))
    #expect(try value.decode(PeerPolicy.self) == policy)
}

@Test func invalidIdentityAndCString() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    await #expect(throws: ForwirohError.self) {
        try await Forwiroh.open(stateDirectory: path, name: "test", identity: Data(count: 31))
    }
    await #expect(throws: ForwirohError.self) {
        try await Forwiroh.open(stateDirectory: path, name: "before\0after")
    }
    #expect(!FileManager.default.fileExists(atPath: path.path))
}

#if os(macOS) || os(Linux)
@Test(.timeLimit(.minutes(1))) func lifecyclePersistenceAndConcurrentShutdown() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    let core = try await Forwiroh.open(stateDirectory: path, name: "SwiftPM")
    let snapshot = try await core.status()
    #expect(snapshot.name == "SwiftPM")
    #expect(snapshot.peers.isEmpty)
    let invitation = try await core.invite()
    #expect(invitation.uri.hasPrefix("forwiroh:"))
    try await core.cancelInvitation(id: invitation.id)
    #expect(try await core.pendingPairings().isEmpty)
    await #expect(throws: ForwirohError.self) {
        try await Forwiroh.open(stateDirectory: path, name: "duplicate")
    }
    await #expect(throws: ForwirohError.self) { try await core.command(["op": .string("not_a_command")]) }
    await #expect(throws: ForwirohError.self) { try await core.receivePacket(session: "missing") }
    let reader = Task { for await _ in core.events {} }
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 { group.addTask { _ = try? await core.status() } }
        for _ in 0..<4 { group.addTask { await core.close() } }
    }
    await reader.value
    await #expect(throws: ForwirohError.self) { try await core.status() }
    let reopened = try await Forwiroh.open(stateDirectory: path, name: "second")
    #expect(try await reopened.status().id == snapshot.id)
    await reopened.close()
}

@Test(.timeLimit(.minutes(1))) func droppingOwnerReleasesDirectoryWithEventReader() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    var core: Forwiroh? = try await Forwiroh.open(stateDirectory: path, name: "owner")
    let events = core!.events
    core = nil
    for await _ in events {}
    // The open worker can briefly retain its result after resuming our task.
    // If it performs deinit, the event reader can finish before shutdown frees
    // the handle and its directory lock. Verify eventual cleanup, not ordering
    // between those threads; explicit close() is the synchronous reuse barrier.
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while true {
        do {
            let reopened = try await Forwiroh.open(stateDirectory: path, name: "new-owner")
            await reopened.close()
            return
        } catch let error as ForwirohError
            where error.message == "state is already in use; use the running daemon"
                && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Test(.timeLimit(.minutes(1))) func pairingAndTunnelCommands() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try await Forwiroh.open(stateDirectory: root.appendingPathComponent("server"), name: "server")
    let client = try await Forwiroh.open(stateDirectory: root.appendingPathComponent("client"), name: "client")
    do {
        try await server.setPairingPolicy(PeerPolicy(restricted: true, services: ["pmai-acp": "127.0.0.1:19283"]))
        try await client.setPairingPolicy(PeerPolicy(restricted: true))
        let invitation = try await server.invite()
        let pairing = Task { try await client.pair(invitation: invitation.uri, device: "SwiftPM") }
        var pending: [PairingRequest] = []
        for _ in 0..<100 {
            pending = try await server.pendingPairings()
            if !pending.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let request = pending.first {
            #expect(request.name == "client")
            try await server.approve(id: request.id)
        } else {
            try await client.cancelPair()
            _ = try? await pairing.value
            throw ForwirohError("Pair request did not reach the local server")
        }
        let peer = try await pairing.value
        #expect(try await client.status().peers.first?.id == peer)
        #expect(try await client.status().peers.first?.policy.restricted == true)
        #expect(try await server.status().peers.first?.policy.services == ["pmai-acp": "127.0.0.1:19283"])
        let forward = try await client.forward(peer: peer, listen: "127.0.0.1:0", service: "127.0.0.1:22")
        let socks = try await client.socks(peer: peer, listen: "127.0.0.1:0")
        let tunnels = try await client.status().tunnels
        #expect(Set(tunnels.map(\.id)) == Set([forward, socks]))
        try await client.stopTunnel(id: forward)
        try await client.stopTunnel(id: socks)
        try await client.rename(peer: peer, name: "home")
        #expect(try await client.status().peers.first?.name == "home")
        try await client.setPolicy(peer: peer, policy: PeerPolicy(restricted: true))
        #expect(try await client.status().peers.first?.policy.restricted == true)
        try await client.revoke(peer: peer)
        #expect(try await client.status().peers.isEmpty)
    } catch {
        await client.close()
        await server.close()
        throw error
    }
    await client.close()
    await server.close()
}
#endif
