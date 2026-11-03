#!/usr/bin/env python3
"""Opt-in, credential-free Windows URLSession/curl upload comparison.

Compile urlsession-upload.swift first, then:
  python3 sys/diagnostics/http-upload-probe.py ./urlsession-upload.exe
The loopback receiver deliberately drains slowly to exercise socket backpressure.
This is a diagnostic, not a throughput benchmark or required CI test.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


RESULTS = {}
FINISHED = {}
LOCK = threading.Lock()


class Receiver(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        expected = int(self.headers['Content-Length'])
        actual = 0
        digest = hashlib.sha256()
        event = threading.Event()
        with LOCK:
            FINISHED[self.path] = event
        self.connection.settimeout(45)
        try:
            while actual < expected:
                chunk = self.rfile.read(min(4096, expected - actual))
                if not chunk:
                    break
                digest.update(chunk)
                actual += len(chunk)
                # Intentional workload: constrain receiver progress so a large
                # sender has to stop and resume. No timing threshold is asserted.
                time.sleep(0.002)
            result = {'expectedBytes': expected, 'receivedBytes': actual,
                      'sha256': digest.hexdigest(), 'complete': actual == expected}
            with LOCK:
                RESULTS[self.path] = result
            response = json.dumps(result).encode()
            self.send_response(200 if actual == expected else 400)
            self.send_header('Content-Length', str(len(response)))
            self.end_headers()
            self.wfile.write(response)
        except (OSError, TimeoutError) as error:
            with LOCK:
                RESULTS[self.path] = {'expectedBytes': expected, 'receivedBytes': actual,
                                      'sha256': digest.hexdigest(), 'complete': actual == expected,
                                      'receiverError': str(error)}
        finally:
            event.set()


class SlowServer(ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self):
        # Apply before listen/accept so the accepted socket inherits this small
        # receive window, rather than negotiating a large loopback buffer first.
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        super().server_bind()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('probe', type=Path)
    parser.add_argument('--sizes', default='32768,131072,1048576')
    args = parser.parse_args()
    sizes = [int(value) for value in args.sizes.split(',')]
    if not all(0 < size <= 16_777_216 for size in sizes):
        parser.error('sizes must be between 1 and 16777216 bytes')
    curl = (str(Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/curl.exe')
            if os.name == 'nt' else shutil.which('curl'))
    if not curl:
        parser.error('curl executable not found')
    print('platform:', platform.platform(), platform.machine(), flush=True)
    for command in [['swift', '--version'], [curl, '--version']]:
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        print(result.stdout.strip(), flush=True)
    environment = dict(os.environ, NO_PROXY='127.0.0.1,localhost')
    server = SlowServer(('127.0.0.1', 0), Receiver)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='swift-upload-probe-') as directory:
            body = Path(directory) / 'body'
            for size in sizes:
                body.write_bytes(b'a' * size)
                for mode in ('data', 'upload', 'curl'):
                    path = f'/{mode}/{size}'
                    url = f'http://127.0.0.1:{server.server_port}{path}'
                    if mode == 'curl':
                        command = [curl, '-q', '--silent', '--show-error', '--max-time', '45',
                                   '--output', os.devnull, '--write-out', 'HTTP=%{http_code} uploaded=%{size_upload}\n',
                                   '--data-binary', '@' + str(body), url]
                    else:
                        command = [str(args.probe.resolve()), url, str(size), mode]
                    print(f'\n--- {mode} {size} bytes ---', flush=True)
                    try:
                        result = subprocess.run(command, env=environment, capture_output=True,
                                                text=True, timeout=70)
                        print(result.stdout + result.stderr, end='', flush=True)
                        print('exit:', result.returncode, flush=True)
                    except subprocess.TimeoutExpired:
                        print('client exceeded the probe deadline', flush=True)
                    with LOCK:
                        event = FINISHED.get(path)
                    if event:
                        event.wait(50)
                    with LOCK:
                        received = RESULTS.get(path, {'receivedBytes': 0, 'complete': False})
                    print('receiver:', json.dumps(received), flush=True)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
