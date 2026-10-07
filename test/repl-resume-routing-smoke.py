#!/usr/bin/env python3
"""Verify resumed inference and named children reach the saved HTTP endpoints."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


requests = []
hold_nested = threading.Event()
nested_started = threading.Event()
release_nested = threading.Event()


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append((self.path, dict(self.headers), request))
        model = request['model']
        if model == 'nested-model' and hold_nested.is_set():
            nested_started.set()
            release_nested.wait(15)
        message = {'role': 'assistant', 'content': f'{model} finished'}
        if request['messages'][-1]['role'] != 'tool' and model in ('main-model', 'worker-model'):
            if 'inspect history' in str(request['messages'][-1]['content']):
                name, arguments = 'agent_status', {'tree': True}
            else:
                name = 'agent_start'
                arguments = {'agent': 'worker' if model == 'main-model' else 'nested',
                             'task': 'Delegate this work.', 'output': 'One line.', 'wait': True}
            message = {'role': 'assistant', 'content': None, 'tool_calls': [{
                'id': f'call-{len(requests)}', 'type': 'function',
                'function': {'name': name, 'arguments': json.dumps(arguments)},
            }]}
        body = json.dumps({'choices': [{'message': message,
                                       'finish_reason': 'tool_calls' if 'tool_calls' in message else 'stop'}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    binary = str(Path(sys.argv[1]).resolve())
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('PMAI_', 'MAI_', 'OPENAI_'))
           and k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy')}
    env['NO_PROXY'] = '127.0.0.1,localhost'
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-resume-routing-') as directory:
            root = Path(directory)
            config = root / 'config.json'
            base = f'http://127.0.0.1:{server.server_port}'
            config.write_text(json.dumps({
                'defaultAgent': 'main', 'taskAgents': {'compact': 'summary'},
                'providers': [
                    {'id': name, 'kind': 'openAICompatible', 'baseURL': f'{base}/{name}/v1',
                     'apiKey': 'original-key', 'headers': {'x-chat-session': '{{session}}'}}
                    for name in ('chat', 'tasks')],
                'agents': [
                    {'id': 'main', 'provider': 'chat', 'model': 'main-model',
                     'toolGroupNames': ['agents'], 'subagentNames': ['worker'],
                     'stream': False, 'retry': {'attempts': 0}},
                    {'id': 'worker', 'provider': 'tasks', 'model': 'worker-model',
                     'instructions': 'Saved worker instructions.',
                     'toolGroupNames': ['agents'], 'subagentNames': ['nested'],
                     'stream': False, 'retry': {'attempts': 0}},
                    {'id': 'nested', 'provider': 'tasks', 'model': 'nested-model', 'stream': False},
                    {'id': 'summary', 'provider': 'tasks', 'model': 'summary-model', 'stream': False},
                ],
                'approvals': {'mode': 'yolo'}, 'memory': {'enabled': False},
                'use': {'plan': False},
            }))

            def run(commands=(), args=()):
                result = subprocess.run(
                    [binary, '--config', str(config), '--home', str(root / 'home'),
                     '--no-stream', '--no-markdown', *args], cwd=root, env=env,
                    input='\n'.join([*commands, '/exit', '']),
                    capture_output=True, text=True, timeout=30)
                output = result.stdout + result.stderr
                assert result.returncode == 0 and 'error:' not in output, output
                return output

            run(['/chat rename routed'], ['--base-url', f'{base}/effective/v1'])
            output = run(args=['-r', 'routed', 'Delegate the first task.'])
            saved_path = next((root / '.pmai/chats').glob('*.json'))
            saved = json.loads(saved_path.read_text())
            assert len(saved['subagents']) == 2, (saved['subagents'], output, requests)
            assert 'original-key' not in saved_path.read_text()

            changed = json.loads(config.read_text())
            changed['taskAgents'] = {}
            for provider in changed['providers']:
                provider['baseURL'] = f'{base}/wrong/v1'
                provider['apiKey'] = 'rotated-key'
            for agent in changed['agents']:
                agent['model'] = 'wrong-model'
            config.write_text(json.dumps(changed))
            requests.clear()
            run(args=['-r', 'routed', 'Delegate a second task.'])
            assert {request['model'] for _, _, request in requests} == {
                'main-model', 'worker-model', 'nested-model'}, requests
            for route, headers, request in requests:
                expected = '/effective/v1/chat/completions' if request['model'] == 'main-model' else '/tasks/v1/chat/completions'
                assert route == expected, (route, request['model'])
                assert headers['Authorization'] == 'Bearer rotated-key', headers
                assert headers['x-chat-session'] == saved['sessionID'], headers
                if request['model'] == 'worker-model':
                    assert 'Saved worker instructions.' in str(request['messages']), request
            assert len(json.loads(saved_path.read_text())['subagents']) == 4

            requests.clear()
            run(args=['-r', 'routed', 'inspect history'])
            tool_results = [m['content'] for _, _, request in requests
                            for m in request['messages'] if m['role'] == 'tool']
            assert any('worker' in text and 'nested' in text for text in tool_results), tool_results
            requests.clear()
            run(['/chat recap'], ['-r', 'routed'])
            assert any(route == '/tasks/v1/chat/completions' and request['model'] == 'summary-model'
                       for route, _, request in requests), requests

            # A terminated interactive process still leaves the submitted turn
            # and its running descendants on disk, before the parent can finish.
            hold_nested.set()
            with (root / 'interrupted.log').open('w') as output:
                process = subprocess.Popen(
                    [binary, '--config', str(config), '--home', str(root / 'home'),
                     '--no-stream', '--no-markdown', '-r', 'routed'],
                    cwd=root, env=env, stdin=subprocess.PIPE, stdout=output, stderr=output,
                    text=True)
                try:
                    process.stdin.write('Delegate an interrupted task.\n')
                    process.stdin.flush()
                    assert nested_started.wait(10), (root / 'interrupted.log').read_text()
                    deadline = time.monotonic() + 5
                    while True:
                        checkpoint = json.loads(saved_path.read_text())
                        if len(checkpoint['subagents']) == 6:
                            break
                        assert time.monotonic() < deadline, checkpoint
                        time.sleep(.02)
                    assert 'Delegate an interrupted task.' in str(checkpoint['messages'])
                    assert any(r['state'] == 'running' for r in checkpoint['subagents'])
                finally:
                    process.kill()
                    process.wait(timeout=5)
                    process.stdin.close()
                    release_nested.set()
                    hold_nested.clear()
            run(['/jobs tree'], ['-r', 'routed'])
            resumed = json.loads(saved_path.read_text())
            assert len(resumed['subagents']) == 6
            assert all(r['state'] in ('completed', 'cancelled') for r in resumed['subagents'])
            print('PASS resume routing: main, nested agents and recap use saved models/endpoints; '
                  'credentials rotate, one-shot tools see history, interrupted children are saved')
    finally:
        release_nested.set()
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
