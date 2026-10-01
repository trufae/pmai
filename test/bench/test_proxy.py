"""Regression checks for native API accounting (no model or network needed)."""
import unittest

from analyze import request_messages
from proxy import Assembler, MessagesAssembler, ResponsesAssembler


class AccountingTests(unittest.TestCase):
    def test_chat_stream_preserves_usage_and_arguments(self):
        asm = Assembler()
        asm.feed({"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "a",
            "function": {"name": "read", "arguments": '{"path":'}}]}}]})
        asm.feed({"choices": [{"delta": {"tool_calls": [{"index": 0,
            "function": {"arguments": '"app.py"}'}}]}, "finish_reason": "tool_calls"}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 5}})
        result = asm.message()
        self.assertEqual(result["tool_calls"], [{"id": "a", "name": "read", "arguments": '{"path":"app.py"}'}])
        self.assertEqual(result["usage"]["prompt_tokens"], 10)

    def test_responses_final_event_does_not_duplicate_tools(self):
        item = {"type": "function_call", "call_id": "a", "name": "shell", "arguments": "{}"}
        response = {"object": "response", "status": "completed", "output": [item],
                    "usage": {"input_tokens": 100, "output_tokens": 20,
                              "input_tokens_details": {"cached_tokens": 80}}}
        streamed = ResponsesAssembler()
        streamed.feed({"type": "response.output_item.done", "output_index": 0, "item": item})
        streamed.feed({"type": "response.completed", "response": response})
        plain = ResponsesAssembler()
        plain.feed(response)
        for asm in (streamed, plain):
            result = asm.message()
            self.assertEqual(len(result["tool_calls"]), 1)
            self.assertEqual(result["usage"]["prompt_tokens"], 100)
            self.assertEqual(result["usage"]["completion_tokens"], 20)

    def test_anthropic_stream_merges_usage_without_double_counting(self):
        asm = MessagesAssembler()
        asm.feed({"type": "message_start", "message": {"content": [], "usage": {
            "input_tokens": 10, "cache_read_input_tokens": 80, "cache_creation_input_tokens": 10,
            "output_tokens": 1}}})
        asm.feed({"type": "content_block_start", "index": 0,
                  "content_block": {"type": "tool_use", "id": "a", "name": "Read", "input": {}}})
        for fragment in ('{"path":', '"app.py"}'):
            asm.feed({"type": "content_block_delta", "index": 0,
                      "delta": {"type": "input_json_delta", "partial_json": fragment}})
        asm.feed({"type": "message_delta", "delta": {"stop_reason": "tool_use"},
                  "usage": {"output_tokens": 20}})
        result = asm.message()
        self.assertEqual(result["usage"]["prompt_tokens"], 100)
        self.assertEqual(result["usage"]["completion_tokens"], 20)
        self.assertEqual(result["tool_calls"][0]["arguments"], '{"path":"app.py"}')

    def test_histories_keep_tool_call_ids_and_errors(self):
        messages = request_messages({"system": [{"type": "text", "text": "system"}], "messages": [
            {"role": "assistant", "content": [{"type": "tool_use", "id": "a", "name": "Read", "input": {}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "a",
                                           "content": "missing file", "is_error": True}]}]})
        self.assertEqual(messages[0]["content"], "system")
        self.assertEqual(messages[1]["tool_calls"][0]["id"], messages[2]["tool_call_id"])
        self.assertEqual(messages[2]["content"], "Error: missing file")


if __name__ == "__main__":
    unittest.main()
