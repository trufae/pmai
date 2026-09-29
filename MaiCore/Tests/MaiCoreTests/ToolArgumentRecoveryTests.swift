import Foundation
import Testing

@testable import MaiCore
@testable import MaiStandardTools

private let recoveryScript = #"sed -i '' 's/placement\.push(Tok\.XOR/push(Tok.XOR/' lexer.ts; grep -n 'field_peek\|placement' lexer.ts"#
private let recoveryHeredoc = """
python3 - <<'PYEOF'
src = 'field_peek\\|placement'
print(src)
PYEOF
"""

@Test("Native argument keys from the failed run_sh calls recover without changing shell text",
  arguments: [
    (["": "", "script": recoveryScript], ["script": recoveryScript]),
    (["script=\"\(recoveryScript)\"": ""], ["script": recoveryScript]),
    (["command=\"\(recoveryScript)\"": ""], ["command": recoveryScript]),
    (["": "script=\"\(recoveryHeredoc)\""], ["script": recoveryHeredoc]),
    (["": "", "script": "echo test"], ["script": "echo test"]),
    (["script=\"echo test\"": ""], ["script": "echo test"]),
    (["": "", #"args='{"cwd": ".", "script": "printf \"hello\\n\""}'"#: ""],
     ["cwd": ".", "script": "printf \"hello\\n\""]),
  ])
func recoverNativeArgumentKeys(fixture: ([String: String], [String: String])) {
  let definition = MaiRunTool(configuration: MaiRunConfiguration()).definition
  let input = JSONValue.object(fixture.0.mapValues(JSONValue.string))
  let expected = JSONValue.object(fixture.1.mapValues(JSONValue.string))
  let repaired = ToolSchemaValidator.repairArgumentKeys(input, definition: definition)
  #expect(repaired == expected)
  #expect(ToolSchemaValidator.validate(arguments: repaired, definition: definition) == nil)
  #expect(ToolSchemaValidator.repairArgumentKeys(repaired, definition: definition) == expected)
  #expect(AgentTooling.normalizeArguments(fixture.0.mapValues(JSONValue.string), for: definition)
    == expected.objectValue)
}

@Test("Argument recovery leaves ambiguous or unknown fields for validation",
  arguments: [
    ["script=\"echo one\"": "echo two"],
    ["script": "echo one", "script=\"echo two\"": ""],
    ["script=\"echo one\"": "", "script='echo two'": ""],
    ["script=\"echo one\" cwd=\"/tmp\"": ""],
    ["script=\"echo one": ""],
    ["script=echo one": ""],
    ["": "echo one"],
    ["unexpected=\"echo one\"": ""],
    [#"args='{"script":"echo one","unexpected":true}'"#: ""],
    ["script": "echo one", #"args='{"script":"echo two"}'"#: ""],
  ])
func rejectAmbiguousArgumentKeys(arguments: [String: String]) {
  let definition = MaiRunTool(configuration: MaiRunConfiguration()).definition
  let input = JSONValue.object(arguments.mapValues(JSONValue.string))
  let repaired = ToolSchemaValidator.repairArgumentKeys(input, definition: definition)
  #expect(repaired == input)
  #expect(ToolSchemaValidator.validate(arguments: repaired, definition: definition) != nil)
  let proxy = ToolProxy.resolveCall(arguments: [
    "name": .string("run_sh"), "arguments": input,
  ], definitions: [definition])
  #expect(proxy.call?.argumentValues == input.objectValue)
}

@Test("Argument recovery preserves valid payloads and open object schemas")
func preserveValidArgumentKeys() {
  let definition = MaiRunTool(configuration: MaiRunConfiguration()).definition
  let arguments = JSONValue.object([
    "script": .string("  cat <<'EOF'\n  leading and trailing spaces  \n\t\\n \\\" $HOME `pwd`\nEOF\n"),
    "stdin": .string("\n input \n"), "args": .array([.string("script=\"literal\"")]),
    "cwd": .string("."), "timeout_seconds": .integer(10),
  ])
  #expect(ToolSchemaValidator.repairArgumentKeys(arguments, definition: definition) == arguments)
  let open = ToolDefinition(name: "object", description: "Accept arbitrary keys")
  let arbitrary = JSONValue.object(["": .string(""), "script=\"literal\"": .string("")])
  #expect(ToolSchemaValidator.repairArgumentKeys(arbitrary, definition: open) == arbitrary)
}

@Test("Invalid empty argument names are visible in validation errors")
func emptyArgumentNameDiagnostic() {
  let definition = MaiRunTool(configuration: MaiRunConfiguration()).definition
  let error = ToolSchemaValidator.validate(arguments: .object(["": .string("unparsed")]), definition: definition)
  #expect(error?.contains("unknown field: \"\"") == true)
  #expect(error?.contains("Received: \"\"") == true)
}

@Test("Proxied run_sh calls use the same argument recovery")
func recoverProxiedArgumentKeys() throws {
  let definition = MaiRunTool(configuration: MaiRunConfiguration()).definition
  let result = ToolProxy.resolveCall(arguments: [
    "name": .string("run_sh"),
    "arguments": .object(["": .string("script=\"\(recoveryHeredoc)\"")]),
  ], definitions: [definition])
  let call = try #require(result.call)
  #expect(call.argumentValues == ["script": .string(recoveryHeredoc)])
}

@Test("Structured argument recovery validates element types and preserves script strings")
func recoverStructuredArgumentValues() {
  let definition = MaiRunTool(configuration: MaiRunConfiguration()).definition
  let valid = JSONValue.object([
    "script": .string(#"{"literal":"\\n"}"#), "args": .string(#"["-lc","echo test"]"#),
  ])
  let repaired = ToolSchemaValidator.repairArgumentKeys(valid, definition: definition)
  #expect(repaired.objectValue?["script"] == valid.objectValue?["script"])
  #expect(repaired.objectValue?["args"] == .array([.string("-lc"), .string("echo test")]))
  for malformed in ["[true]", "{\"script\":\"echo test\"}", "[\"truncated\""] {
    let input = JSONValue.object(["args": .string(malformed)])
    #expect(ToolSchemaValidator.repairArgumentKeys(input, definition: definition) == input)
    #expect(ToolSchemaValidator.validate(arguments: input, definition: definition) != nil)
  }
}

@Test("Malformed argument diagnostics bound whole-script keys and explain the JSON shape")
func boundedArgumentKeyDiagnostics() throws {
  let definition = MaiRunTool(configuration: MaiRunConfiguration()).definition
  let key = "</think><tool_call>run_sh\tscript=\"\n" + String(repeating: "x", count: 20_000)
  let input = JSONValue.object([key: .string("")])
  #expect(ToolSchemaValidator.repairArgumentKeys(input, definition: definition) == input)
  let error = try #require(ToolSchemaValidator.validate(arguments: input, definition: definition))
  #expect(error.count < 1_000)
  #expect(!error.contains("\n") && !error.contains("\t"))
  #expect(error.contains("\\n") && error.contains("\\t"))
  #expect(error.contains("characters)"))
  #expect(error.contains("Use exact field names as JSON keys"))
  #expect(error.contains("Accepted fields:"))
}
