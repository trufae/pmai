import Foundation
import Testing
@testable import MaiACP

private let firstKey = "nodekey:" + String(repeating: "a", count: 64)
private let secondKey = "nodekey:" + String(repeating: "b", count: 64)

private func tailcatFixture() throws -> TailcatStore {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tailcat-\(UUID())")
  let store = TailcatStore(directory: directory)
  try store.initializeWorker(name: "worker", workspace: FileManager.default.temporaryDirectory)
  try store.transaction { $0.worker?.address = "tc" + String(repeating: "x", count: 80) }
  return store
}

@Test("Pairing invites round-trip, expire, and cannot be redeemed by a second identity")
func tailcatPairingLifecycle() throws {
  let store = try tailcatFixture()
  defer { try? FileManager.default.removeItem(at: store.directory) }
  let now = Date()
  let invite = try store.invite(now: now)
  #expect(try TailcatInvite(url: invite.url, now: now) == invite)
  #expect(throws: JSONRPCError.self) { try TailcatInvite(url: invite.url, now: now.addingTimeInterval(301)) }
  #expect(throws: JSONRPCError.self) { try store.authorize(firstKey) }
  #expect(throws: JSONRPCError.self) { try store.enroll(token: "wrong", nodeKey: firstKey, name: "controller", now: now) }
  let paired = try store.enroll(token: invite.token, nodeKey: firstKey, name: "controller", now: now)
  #expect(paired.peers.count == 1)
  #expect(try store.authorize(firstKey).name == "controller")
  // A lost response may be retried by the original identity only.
  #expect(try store.enroll(token: invite.token, nodeKey: firstKey, name: "controller", now: now).peers.count == 1)
  #expect(throws: JSONRPCError.self) { try store.enroll(token: invite.token, nodeKey: secondKey, name: "other", now: now) }
  try store.revoke(paired.peers[0].id)
  #expect(throws: JSONRPCError.self) { try store.authorize(firstKey) }
  #expect(throws: JSONRPCError.self) { try store.enroll(token: invite.token, nodeKey: firstKey, name: "controller", now: now) }
  let fresh = try store.invite(now: now)
  _ = try store.enroll(token: fresh.token, nodeKey: firstKey, name: "controller", now: now)
  #expect(try !store.authorize(firstKey).revoked)
  let audit = try String(contentsOf: store.directory.appendingPathComponent("audit.jsonl"), encoding: .utf8)
  #expect(!audit.contains(invite.token))
  #expect(!audit.contains(invite.address))
}

@Test("Concurrent enrollment claims authorize exactly one identity")
func tailcatConcurrentEnrollment() async throws {
  let store = try tailcatFixture()
  defer { try? FileManager.default.removeItem(at: store.directory) }
  let invite = try store.invite()
  let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
    for key in [firstKey, secondKey] {
      group.addTask { (try? store.enroll(token: invite.token, nodeKey: key, name: "controller")) != nil }
    }
    var count = 0
    for await accepted in group { if accepted { count += 1 } }
    return count
  }
  #expect(successes == 1)
  #expect(try store.read().worker?.peers.count == 1)
}

@Test("Expired, replaced, and malformed pairing credentials do not grant access")
func tailcatInvalidInvites() throws {
  let store = try tailcatFixture()
  defer { try? FileManager.default.removeItem(at: store.directory) }
  let now = Date()
  let old = try store.invite(now: now)
  let fresh = try store.invite(now: now)
  #expect(throws: JSONRPCError.self) { try store.enroll(token: old.token, nodeKey: firstKey, name: "old", now: now) }
  #expect(throws: JSONRPCError.self) { try store.enroll(token: fresh.token, nodeKey: firstKey, name: "late", now: now.addingTimeInterval(301)) }
  #expect(throws: JSONRPCError.self) { try store.enroll(token: fresh.token, nodeKey: "not-a-key", name: "bad", now: now) }
  #expect(throws: JSONRPCError.self) { try TailcatInvite(url: "pmai-tailcat://pair/garbage") }
  #expect(!TailcatInvite.validAddress("tc" + String(repeating: "x", count: 20) + "\n"))
  #expect(try store.read().worker?.peers.isEmpty == true)
}
