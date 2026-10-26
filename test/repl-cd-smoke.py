#!/usr/bin/env python3
"""Keep model context and tool cwd aligned after /cd, without a live model."""
import json
from http.server import ThreadingHTTPServer
from pathlib import Path
import sys
import tempfile
import threading

from smoke import JSONProvider, clean_environment, read_chat, run_repl


requests = []


class Provider(JSONProvider):
    def do_GET(self):
        self.respond({'data': [{'id': 'fixture'}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(request)
        last = request['messages'][-1]
        if last['role'] == 'tool':
            message = {'role': 'assistant', 'content': 'CWD CHECKED'}
        else:
            message = {'role': 'assistant', 'content': '', 'tool_calls': [{
                'id': f'cwd-{len(requests)}', 'type': 'function',
                'function': {'name': 'run_shell', 'arguments': json.dumps({'script': 'pwd'})}}]}
        self.respond({'choices': [{'message': message,
            'finish_reason': 'tool_calls' if message.get('tool_calls') else 'stop'}]})


def canonical(text):
    return str(text).replace('/private/var/', '/var/')


def main():
    binary = str(Path(sys.argv[1]).resolve())
    env = clean_environment()
    env.update(NO_PROXY='127.0.0.1,localhost', NO_COLOR='1')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-cd-') as directory:
            base = Path(directory).resolve()
            first, second = base / 'first', base / 'second repo'
            for folder, rules in ((first, 'FIRST REPO RULES'), (second, 'SECOND REPO RULES')):
                folder.mkdir()
                (folder / '.git').mkdir()
                (folder / 'AGENTS.md').write_text(rules)
            for mode in ('cache', 'size', 'smart', 'tools'):
                requests.clear()
                config = base / 'config.json'
                config.write_text(json.dumps({
                    'defaultAgent': 'main',
                    'providers': [{'id': 'local', 'kind': 'openAICompatible',
                                   'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                    'toolSources': [{'id': 'standard', 'kind': 'standard-tools',
                                     'options': {'tools': ['run_shell']}}],
                    'agents': [{'id': 'main', 'provider': 'local', 'model': 'fixture',
                                'toolNames': ['run_shell'], 'toolGroupNames': [],
                                'context': mode, 'retry': {'attempts': 0},
                                'autocompact': {'tokens': 0}}],
                    'approvals': {'mode': 'yolo'}, 'memory': {'enabled': False},
                    'use': {'plan': False, 'agentsmd': 'on'},
                }))
                output = run_repl([
                    binary, '--config', str(config), '--home', str(base / 'home'),
                    '--no-stream', '--no-markdown'], [
                    '/chat new', 'Check the current repository', '/cd ../second repo', '/pwd',
                    'Check the current repository again', '/cd missing-directory',
                    'Check after a failed directory change', '/cd ../first', 'Check back here'],
                    cwd=first, env=env, allow_errors=True)
                assert 'error: Not a directory:' in output, output
                assert len(requests) == 8, (requests, output)
                for index, folder in enumerate((first, second, second, first)):
                    for request in requests[index * 2:index * 2 + 2]:
                        context = [m['content'] for m in request['messages']
                                   if m['role'] == 'system'
                                   and '<execution_context>' in m['content']]
                        assert len(context) == 1, (mode, request)
                        assert context[0].count('<execution_context>') == 1, context
                        assert canonical(f'Current working directory: {folder}') in canonical(context[0]), context
                        rules = '\n'.join(m['content'] for m in request['messages']
                                          if m['role'] == 'system' and '<project_instructions>' in m['content'])
                        assert ('FIRST REPO RULES' if folder == first else 'SECOND REPO RULES') in rules, rules
                        assert ('SECOND REPO RULES' if folder == first else 'FIRST REPO RULES') not in rules, rules
                    result = requests[index * 2 + 1]['messages'][-1]
                    assert result['role'] == 'tool', result
                    assert canonical(result['content']).strip() == canonical(folder), result
                # Earlier results remain in history, but runtime context is refreshed
                # outside the stored transcript, so resume/compaction cannot freeze it.
                assert canonical(first) in canonical(json.dumps(requests[2]['messages'])), requests[2]
                for chat_path in (first / '.pmai/chats').glob('*.json'):
                    assert '<execution_context>' not in json.dumps(read_chat(chat_path)['messages']), chat_path
                print(f'PASS {mode}: model context, shell cwd, project rules, and failed /cd')
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
