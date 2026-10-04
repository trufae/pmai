#!/usr/bin/env python3
"""Check tool-result summaries and live context sizes in a real REPL PTY."""
import fcntl
import json
import os
from pathlib import Path
import pty
import queue
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


calls = queue.Queue()
preparations = []
primary_requests = []
gates = []


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def respond(self, payload):
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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
            gate = threading.Event()
            gates.append(gate)
            calls.put((request, gate))
            gate.wait(30)
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
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('PMAI_', 'MAI_', 'OPENAI_'))
                   and key.lower() not in ('http_proxy', 'https_proxy', 'all_proxy')}
    environment.update(TERM='xterm-256color', NO_PROXY='127.0.0.1,localhost')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for mode in ('cache', 'tools'):
            preparations.clear()
            primary_requests.clear()
            gates.clear()
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
                    'ui': {'toolResultLines': 0},
                }))
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 240, 0, 0))
                process = subprocess.Popen([
                    binary, '--config', str(config), '--home', str(root / 'home'),
                    '--no-stream', '--no-markdown'], cwd=root, env=environment,
                    stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
                os.close(slave)
                output = bytearray()

                def read():
                    if select.select([master], [], [], .05)[0]:
                        output.extend(os.read(master, 65536))

                def wait_for(predicate):
                    deadline = time.monotonic() + 15
                    while not predicate():
                        assert time.monotonic() < deadline, (mode, output.decode(errors='replace'))
                        assert process.poll() is None, (process.returncode, output)
                        read()

                def send(text):
                    output.clear()
                    os.write(master, (text + '\r').encode())

                def next_call(expect_below=None):
                    wait_for(lambda: not calls.empty())
                    request, gate = calls.get_nowait()

                    def latest_size():
                        text = re.sub(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|[78])', '',
                                      output.decode(errors='replace'))
                        sizes = re.findall(r'(\d+) msg ~([\d,.]+)([kmb]?) tok', text)
                        if not sizes:
                            return None
                        messages, number, suffix = sizes[-1]
                        tokens = float(number.replace(',', '')) * {'': 1, 'k': 1000, 'm': 1e6, 'b': 1e9}[suffix]
                        return int(messages), tokens

                    # Provider calls and supervisor redraws arrive on separate
                    # tasks; wait for the projected context to reach the UI.
                    wait_for(lambda: latest_size() is not None
                             and (expect_below is None or latest_size()[1] < expect_below))
                    size = latest_size()
                    output.clear()
                    return request, gate, size

                try:
                    wait_for(lambda: b'pmai>' in output)
                    send('/model-compact local::tiny')
                    wait_for(lambda: b'(saved)' in output)
                    send(f'/set ctx.strategy {mode}')
                    wait_for(lambda: f'= {mode}'.encode() in output)
                    assert json.loads(config.read_text())['agents'][0]['context'] == mode
                    send('Inspect both files and preserve the boundary condition.')
                    first, gate, initial = next_call()
                    gate.set()
                    second, gate, grown = next_call()
                    assert evidence in json.dumps(second).replace('\\n', '\n'), second
                    assert grown[0] > initial[0] and grown[1] > initial[1] + 3000, (initial, grown)
                    gate.set()
                    third, gate, final = next_call(expect_below=grown[1] / 2 if mode == 'tools' else None)
                    assert final[0] > grown[0], (grown, final)
                    if mode == 'tools':
                        assert final[1] < grown[1] / 2, (grown, final)
                        assert '[Summary of earlier tool result]' in json.dumps(third), third
                        assert 'EXACT TAIL' not in json.dumps(third), third
                        assert len(preparations) == 1, preparations
                        assert 'EXACT TAIL' in preparations[0]['messages'][-1]['content']
                        assert not preparations[0].get('tools'), preparations[0]
                    else:
                        assert final[1] >= grown[1], (grown, final)
                        assert 'EXACT TAIL' in json.dumps(third) and not preparations
                    assert all('Inspect both files' in json.dumps(request)
                               and 'Keep the existing public API.' in json.dumps(request)
                               for request in (first, second, third))
                    gate.set()
                    wait_for(lambda: b'TASK COMPLETE' in output and b'took' in output)
                    send('/exit')
                    deadline = time.monotonic() + 10
                    while process.poll() is None:
                        assert time.monotonic() < deadline, output.decode(errors='replace')
                        try:
                            read()
                        except OSError:
                            break
                    assert process.wait(timeout=5) == 0
                    chat = json.loads(next((root / '.pmai/chats').glob('*.json')).read_text())
                    assert 'EXACT TAIL' in json.dumps(chat)
                    assert '[Summary of earlier tool result]' not in json.dumps(chat)
                    print(f'PASS {mode}: live context {initial[1]:.0f} -> {grown[1]:.0f} -> {final[1]:.0f} tokens')
                finally:
                    for gate in gates:
                        gate.set()
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=5)
                    os.close(master)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
