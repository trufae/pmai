#!/usr/bin/env python3
"""Check tool context through provider requests and saved history, without a PTY."""
import json
from pathlib import Path
import sys
import tempfile
import threading
from http.server import ThreadingHTTPServer

from smoke import JSONProvider, clean_environment, read_chat, run_repl


preparations = []
primary_requests = []


class Provider(JSONProvider):
    def do_GET(self):
        self.respond({'data': [{'id': 'large'}, {'id': 'tiny'}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if request['model'] == 'tiny':
            preparations.append(request)
            message = {'role': 'assistant', 'content': json.dumps({
                '0': 'Large.swift defines the boundary condition. Keep the existing public API.'})}
        else:
            primary_requests.append(request)
            turn = len(primary_requests)
            message = {'role': 'assistant', 'content': 'TASK COMPLETE'}
            if turn < 3:
                path = 'Large.swift' if turn == 1 else 'Small.swift'
                message = {'role': 'assistant', 'content': f'Read {path}', 'tool_calls': [{
                    'id': f'read-{turn}', 'type': 'function',
                    'function': {'name': 'files_read', 'arguments': json.dumps({
                        'path': path, 'max_bytes': 32000})},
                }]}
        self.respond({'choices': [{'message': message,
            'finish_reason': 'tool_calls' if 'tool_calls' in message else 'stop'}]})


def main():
    binary = str(Path(sys.argv[1]).resolve())
    environment = clean_environment()
    environment['NO_PROXY'] = '127.0.0.1,localhost'
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for mode in ('cache', 'tools'):
            preparations.clear()
            primary_requests.clear()
            with tempfile.TemporaryDirectory(prefix='pmai-tool-context-') as directory:
                root = Path(directory)
                evidence = '// boundary condition code\n' * 700 + '// EXACT TAIL\n'
                (root / 'Large.swift').write_text(evidence)
                (root / 'Small.swift').write_text('// short regression check\n')
                config = root / 'config.json'
                config.write_text(json.dumps({
                    'defaultAgent': 'main',
                    'providers': [{'id': 'local', 'kind': 'openAICompatible',
                                   'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                    'agents': [{'id': 'main', 'provider': 'local', 'model': 'large',
                                'instructions': 'Keep the existing public API.',
                                'toolNames': ['files_read'], 'toolGroupNames': [],
                                'retry': {'attempts': 0}, 'autocompact': {'tokens': 0}}],
                    'memory': {'enabled': False}, 'use': {'plan': False},
                    'approvals': {'mode': 'yolo'},
                    'ui': {'tools': 0},
                }))
                output = run_repl([
                    binary, '--config', str(config), '--home', str(root / 'home'),
                    '--no-stream', '--no-markdown'], [
                        '/model -compact local::tiny', f'/set ctx.strategy {mode}',
                        'Inspect both files and preserve the boundary condition.',
                    ], cwd=root, env=environment)
                assert json.loads(config.read_text())['agents'][0]['context'] == mode
                assert 'TASK COMPLETE' in output, output
                assert len(primary_requests) == 3, primary_requests
                first, second, third = primary_requests
                assert evidence in json.dumps(second).replace('\\n', '\n'), second
                if mode == 'tools':
                    assert '[Summary of earlier tool result]' in json.dumps(third), third
                    assert 'EXACT TAIL' not in json.dumps(third), third
                    assert len(preparations) == 1, preparations
                    assert 'EXACT TAIL' in preparations[0]['messages'][-1]['content']
                    assert not preparations[0].get('tools'), preparations[0]
                else:
                    assert 'EXACT TAIL' in json.dumps(third) and not preparations
                assert '// short regression check' in json.dumps(third), third
                assert all('Inspect both files' in json.dumps(request)
                           and 'Keep the existing public API.' in json.dumps(request)
                           for request in (first, second, third))
                chat = read_chat(next((root / '.pmai/chats').glob('*.json')))
                assert 'EXACT TAIL' in json.dumps(chat)
                assert '[Summary of earlier tool result]' not in json.dumps(chat)
                print(f'PASS {mode}: exact tool requests and lossless saved history')
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
