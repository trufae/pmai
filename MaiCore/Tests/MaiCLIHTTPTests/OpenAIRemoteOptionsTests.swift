import Testing
@testable import MaiCLI

@Test("OpenAI REPL serving defaults to loopback with tools disabled")
func openAIRemoteDefaults() throws {
  let options = try OpenAIRemoteOptions(["--protocol", "openai"])
  #expect(options.host == "127.0.0.1")
  #expect(options.port == 11435)
  #expect(!options.allowTools)
}

@Test("OpenAI REPL serving accepts an explicit port, bind address and tools")
func openAIRemoteExplicitOptions() throws {
  let options = try OpenAIRemoteOptions([
    "--protocol", "openai", "--port", "8080", "--bind", "0.0.0.0", "--tools",
  ])
  #expect(options.host == "0.0.0.0")
  #expect(options.port == 8080)
  #expect(options.allowTools)
  #expect(OpenAIRemoteOptions.isLoopback("::1"))
  #expect(!OpenAIRemoteOptions.isLoopback("192.168.1.10"))
}

@Test("Invalid OpenAI serving options fail before opening a listener", arguments: [
  ["--port", "0"], ["--port", "65536"], ["--port", "abc"], ["--port"],
  ["--port", "8080", "--port", "8081"], ["--bind", "0.0.0.0", "--loopback"],
  ["--path", "/tmp"], ["--protocol", "local"], ["--tools", "--tools"],
])
func openAIRemoteInvalidOptions(arguments: [String]) {
  #expect(throws: (any Error).self) { try OpenAIRemoteOptions(arguments) }
}
