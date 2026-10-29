import Testing

@testable import MaiCore

@Test("Batch tool registration preserves duplicate and reserved-name validation")
func toolCatalogBatchValidation() async throws {
  let runtime = AgentRuntime()
  func tool(_ name: String) -> any AgentTool {
    ClosureTool(definition: ToolDefinition(name: name, description: name)) { _, _ in
      ToolOutput(text: name)
    }
  }
  try await runtime.register(tools: [tool("first"), tool("second")])
  #expect(await runtime.availableTools().map(\.name) == ["first", "second"])
  await #expect(throws: AgentToolError.duplicateName("first")) {
    try await runtime.register(tools: [tool("first")])
  }
  await #expect(throws: AgentRuntimeError.reservedToolName(AgentRuntime.agentStartToolName)) {
    try await runtime.register(tools: [tool(AgentRuntime.agentStartToolName)])
  }
  try await runtime.register(tools: [tool("first")], replacingExisting: true)
  #expect(await runtime.availableTools().map(\.name) == ["first", "second"])
}
