#!/usr/bin/env python3
"""Check recursive agents and /agents trees against a deterministic local provider."""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


leaf_started = threading.Event()
release_leaf = threading.Event()
requests = []
max_depth = 3


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        users = [m['content'] for m in request['messages'] if m['role'] == 'user']
        depth = int(re.search(r'level (\d+)', users[0])[1])
        requests.append((depth, request))
        results = [m for m in request['messages'] if m['role'] == 'tool']
        message = {'role': 'assistant', 'content': f'level {depth} done'}
        if depth == max_depth:
            leaf_started.set()
            release_leaf.wait(30)
        elif not results:
            arguments = {'task': f'level {depth + 1}', 'output': 'One line.',
                         'wait': request['model'].endswith('blocking')}
            if request['model'].startswith('named'):
                arguments['agent'] = 'worker'
            message = {'role': 'assistant', 'content': None, 'tool_calls': [{
                'id': f'start-{depth}', 'type': 'function',
                'function': {'name': 'agent_start', 'arguments': json.dumps(arguments)},
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
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for mode in ('named-blocking', 'derived-blocking', 'named-background', 'derived-background'):
            leaf_started.clear()
            release_leaf.clear()
            requests.clear()
            with tempfile.TemporaryDirectory(prefix='pmai-agents-') as directory:
                root = Path(directory)
                config = root / 'config.json'
                config.write_text(json.dumps({
                    'version': 1, 'defaultAgent': 'worker',
                    'providers': [{'id': 'smoke', 'kind': 'openAICompatible',
                                   'baseURL': f'http://127.0.0.1:{server.server_port}/v1',
                                   'apiKey': 'smoke', 'timeout': 60}],
                    'agents': [{'id': 'worker', 'provider': 'smoke', 'model': mode,
                                'toolGroupNames': ['agents'], 'subagentNames': ['worker'],
                                'stream': False, 'retry': {'attempts': 0},
                                'limits': {'maxSubagents': 1, 'maxSubagentDepth': max_depth}}],
                    'approvals': {'confirm': 'allow', 'dangerous': 'deny'},
                    'memory': {'enabled': False}, 'use': {'plan': False},
                }))
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 220, 0, 0))
                env = {k: v for k, v in os.environ.items()
                       if not k.startswith(('PMAI_', 'MAI_', 'OPENAI_'))
                       and k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy')}
                env.update(TERM='xterm-256color', NO_PROXY='127.0.0.1,localhost')
                process = subprocess.Popen(
                    [binary, '--config', str(config), '--home', str(root / 'home'),
                     '--no-stream', '--no-markdown'], cwd=root, env=env,
                    stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
                os.close(slave)
                output = bytearray()

                def send(text):
                    os.write(master, (text + '\r').encode())

                def wait_for(text):
                    deadline = time.monotonic() + 15
                    needle = text.encode()
                    while needle not in output:
                        assert time.monotonic() < deadline, (mode, text, output.decode(errors='replace'))
                        assert process.poll() is None, (process.returncode, output)
                        if select.select([master], [], [], .1)[0]:
                            output.extend(os.read(master, 65536))
                    end = output.index(needle) + len(needle)
                    captured = bytes(output[:end]).decode(errors='replace')
                    del output[:end]
                    return re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', captured).replace('\r', '')

                def check_tree(state):
                    tree = wait_for('Total:')
                    for depth in range(1, max_depth + 1):
                        name = 'worker' if mode.startswith('named') else 'worker' + '.worker' * depth
                        prefix = '    ' * (depth - 1) + '└── '
                        assert re.search(rf'(?m)^{prefix}#\d+ {re.escape(name)}\s+\[{state}\]', tree), tree

                try:
                    wait_for('pmai>')
                    send('level 0')
                    assert leaf_started.wait(15), f'{mode}: recursive leaf never started'
                    send('/agents')
                    check_tree('run')
                    release_leaf.set()
                    wait_for('✓ took')
                    send('/agents tree')
                    check_tree('done')
                    assert {depth for depth, _ in requests} == set(range(max_depth + 1)), requests
                    for depth, request in requests:
                        tools = {t['function']['name'] for t in request.get('tools', [])}
                        assert ('agent_start' in tools) == (depth < max_depth), (depth, tools)
                    for depth, request in dict(requests).items():
                        if depth < max_depth:
                            role = 'tool' if mode.endswith('blocking') else 'user'
                            assert any(f'level {depth + 1} done' in m['content']
                                       for m in request['messages'] if m['role'] == role), request
                    send('/exit')
                    process.wait(timeout=10)
                    assert process.returncode == 0, process.returncode
                    print(f'PASS {mode}: depth {max_depth}, one child slot, live and completed trees')
                finally:
                    release_leaf.set()
                    if process.poll() is None:
                        process.kill()
                        process.wait()
                    os.close(master)
    finally:
        release_leaf.set()
        server.shutdown()


if __name__ == '__main__':
    main()
