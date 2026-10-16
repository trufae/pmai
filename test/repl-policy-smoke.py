#!/usr/bin/env python3
"""Check policy rejection handling and retained history against a local fixture."""
import json
import os
from pathlib import Path
import pty
import subprocess
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer
from smoke import JSONProvider, clean_environment, expect_pty, read_pty


requests = []


class Provider(JSONProvider):
    def do_GET(self):
        self.respond({'data': [{'id': 'http'}, {'id': 'stream'}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(request)
        error = {'error': {'code': 'cyber_policy', 'message': 'Policy fixture rejection'}}
        streamed = request['model'] == 'stream'
        body = (('data: ' + json.dumps(error) + '\n\n') if streamed else json.dumps(error)).encode()
        self.send_response(200 if streamed else 403)
        self.send_header('Content-Type', 'text/event-stream' if streamed else 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('x-request-id', 'req-policy-fixture')
        self.end_headers()
        self.wfile.write(body)


def main():
    binary = str(Path(sys.argv[1]).resolve())
    env = clean_environment() | {'NO_COLOR': '1', 'NO_PROXY': '127.0.0.1,localhost'}
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for mode in ('http', 'stream'):
            requests.clear()
            with tempfile.TemporaryDirectory(prefix='pmai-policy-') as directory:
                root = Path(directory)
                config = root / 'config.json'
                config.write_text(json.dumps({
                    'defaultAgent': 'main',
                    'providers': [{'id': 'fixture', 'kind': 'openAICompatible',
                                   'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                    'agents': [{'id': 'main', 'provider': 'fixture', 'model': mode,
                                'retry': {'attempts': 2, 'delaySeconds': 0},
                                'autocompact': {'tokens': 0}}],
                    'memory': {'enabled': False},
                }))
                master, slave = pty.openpty()
                process = subprocess.Popen(
                    [binary, '--config', str(config), '--home', str(root / 'home'),
                     '--no-markdown'], cwd=root, env=env,
                    stdin=slave, stdout=slave, stderr=slave)
                os.close(slave)
                output = bytearray()
                try:
                    expect_pty(master, process, output, 'pmai> ', 15)
                    os.write(master, b'Review my code\r')
                    diagnostics = expect_pty(master, process, output, 'Automatic retries skipped', 30)
                    assert 'error: Policy fixture rejection' in diagnostics, diagnostics
                    assert 'code: cyber_policy' in diagnostics and 'req-policy-fixture' in diagnostics
                    assert f'HTTP {200 if mode == "stream" else 403}' in diagnostics, diagnostics
                    expect_pty(master, process, output, 'took', 10)
                    os.write(master, b'/export json after.json\r/exit\r')
                    deadline = time.monotonic() + 10
                    while process.poll() is None:
                        assert time.monotonic() < deadline, output.decode(errors='replace')
                        read_pty(master, output, .1)
                    assert process.returncode == 0, output.decode(errors='replace')
                    assert len(requests) == 1, requests
                    after = json.loads((root / 'after.json').read_text())['chat']['messages']
                    users = [message for message in after if message['role'] == 'user']
                    assert len(users) == 1 and 'Review my code' in json.dumps(users[0]), after
                    assert not any(message['role'] == 'assistant' for message in after), after
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.wait(timeout=5)
                    os.close(master)
    finally:
        server.shutdown()
        server.server_close()
    print('REPL policy rejection smoke passed')


if __name__ == '__main__':
    main()
