import Foundation
import MaiCore
import Testing

@testable import MaiVisual

@Test("Host path confirmations still surface after visual always-approval")
func visualPathApprovalsRemainInteractive() async throws {
  let approvals = VisualApprovalHandler(requiresConfirmation: {
    $0.tool.name == "files_path_access"
  })
  let (events, pending) = AsyncStream<VisualApprovalHandler.Pending>.makeStream()
  await approvals.attach { pending.yield($0) }
  await approvals.resolveAlways([])
  let request = ApprovalRequest(
    run: .init(runID: UUID(), parentRunID: nil, agentID: "test", depth: 0),
    tool: .init(name: "files_read", description: "Read"),
    call: .init(id: "normal", name: "files_read", arguments: .object([:])))
  #expect(try await approvals.decide(request) == .approve(arguments: request.call.arguments))
  var path = request
  path.tool.name = "files_path_access"
  path.call.name = "files_path_access"
  let task = Task { try await approvals.decide(path) }
  var iterator = events.makeAsyncIterator()
  let presented = try #require(await iterator.next())
  #expect(presented.request.tool.name == "files_path_access")
  await approvals.resolve(presented.id, with: .deny(reason: "Denied by person"))
  #expect(try await task.value == .deny(reason: "Denied by person"))
  pending.finish()
  await approvals.detach()
}
