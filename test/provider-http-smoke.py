#!/usr/bin/env python3
"""Check complete uploads, live SSE delivery, redirects and HTTP errors via curl."""
import gzip
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from smoke import clean_environment


FIRST = threading.Event()
RELEASE = threading.Event()
DISCONNECTED = threading.Event()
BODY = 'UPLOAD_EVIDENCE café 🐢\n' * 6000  # Cross the reported 64 KB upload boundary.
RECEIVED = []
KEY = 'fixture-"quoted\\key'


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        size = int(self.headers['Content-Length'])
        body = self.rfile.read(size)
        request = json.loads(body)
        RECEIVED.append((self.path, body, self.headers.get('Authorization')))
        assert self.headers.get('Authorization') == 'Bearer ' + KEY
        assert any(BODY in value for value in strings(request['messages']))
        if self.path.startswith('/redirect/'):
            self.send_response(307)
            self.send_header('Location', '/ok/v1/chat/completions')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path.startswith('/cross/'):
            self.send_response(307)
            self.send_header('Location', f'http://localhost:{self.server.server_port}/leak')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path.startswith('/error/'):
            data = b'{"error":{"message":"FIXTURE_REJECTION"}}'
            self.send_response(429)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        stream = request.get('stream', False)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream' if stream else 'application/json')
        if self.path.startswith('/gzip/'):
            self.send_header('Content-Encoding', 'gzip')
        self.end_headers()
        if not stream:
            data = json.dumps({'choices': [{'message': {'content': 'COMPLETE café 🐢'},
                                           'finish_reason': 'stop'}]}).encode()
            self.wfile.write(gzip.compress(data) if self.path.startswith('/gzip/') else data)
            return
        first = ('data: ' + json.dumps({'choices': [{'delta': {'content': 'FIRST_CHUNK café 🐢'}}]},
                                      ensure_ascii=False) + '\n\n').encode()
        # Split Unicode and SSE framing across writes.
        for offset in range(0, len(first), 5):
            self.wfile.write(first[offset:offset + 5])
            self.wfile.flush()
        FIRST.set()
        if self.path.startswith('/cancel/'):
            self.connection.settimeout(90)
            try:
                if not self.connection.recv(1):
                    DISCONNECTED.set()
            except ConnectionResetError:
                DISCONNECTED.set()
            return
        if not RELEASE.wait(60):
            return
        self.wfile.write(b'data: {"choices":[{"delta":{"content":" COMPLETE"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')


def main():
    binary = str(Path(sys.argv[1]).resolve())
    environment = clean_environment()
    environment['NO_PROXY'] = '127.0.0.1,localhost'
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-provider-http-') as directory:
            root = Path(directory)
            for case, stream in [('ok', False), ('gzip', False), ('ok', True), ('redirect', True),
                                 ('cross', True), ('error', True), ('cancel', True)]:
                FIRST.clear()
                RELEASE.clear()
                DISCONNECTED.clear()
                start = len(RECEIVED)
                config = root / 'config.json'
                config.write_text(json.dumps({
                    'defaultAgent': 'main',
                    'providers': [{'id': 'fixture', 'kind': 'openAICompatible', 'apiKey': KEY,
                                   'baseURL': f'http://127.0.0.1:{server.server_port}/{case}/v1',
                                   'timeout': 90, 'options': {'httpTransport': 'curl'}}],
                    'agents': [{'id': 'main', 'provider': 'fixture', 'model': 'fixture',
                                'toolNames': [], 'toolGroupNames': [], 'context': 'cache',
                                'limits': {'maxSeconds': 3} if case == 'cancel' else {},
                                'retry': {'attempts': 0}}],
                    'memory': {'enabled': False}, 'use': {'plan': False},
                }))
                args = [binary, '--config', str(config), '--home', str(root / 'home'),
                        '--no-markdown', '--stdin', *([] if stream else ['--no-stream']),
                        'Review attached evidence.']
                output = bytearray()
                saw_first = threading.Event()
                with (root / 'stderr').open('wb') as errors:
                    process = subprocess.Popen(args, cwd=root, env=environment,
                                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
                    def collect():
                        while chunk := process.stdout.read(1):
                            output.extend(chunk)
                            if b'FIRST_CHUNK' in output:
                                saw_first.set()
                                RELEASE.set()
                    reader = threading.Thread(target=collect, daemon=True)
                    reader.start()
                    try:
                        process.stdin.write(BODY.encode())
                        process.stdin.close()
                        process.wait(timeout=90)
                        reader.join(timeout=10)
                        assert not reader.is_alive(), 'stdout did not finish'
                    finally:
                        RELEASE.set()
                        if process.poll() is None:
                            process.kill()
                            process.wait(timeout=10)
                        process.stdout.close()
                text = output.decode('utf-8') + (root / 'stderr').read_text()
                if case == 'cancel':
                    assert FIRST.is_set() and saw_first.is_set(), text
                    assert DISCONNECTED.wait(30), 'cancellation left curl connected'
                    assert 'COMPLETE' not in output.decode('utf-8'), text
                elif case in ('cross', 'error'):
                    assert process.returncode != 0, text
                    assert len(RECEIVED) == start + 1, 'redirect leaked a request'
                    if case == 'error':
                        assert 'FIXTURE_REJECTION' in text, text
                else:
                    assert process.returncode == 0 and 'COMPLETE' in text, text
                    if stream:
                        assert FIRST.is_set() and saw_first.is_set(), 'SSE was buffered until completion'
                        assert 'café 🐢' in text, text
                    if case == 'redirect':
                        assert RECEIVED[start][1:] == RECEIVED[start + 1][1:], '307 lost body or credentials'
                print(f'PASS curl {case} stream={stream}', flush=True)
    finally:
        RELEASE.set()
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
