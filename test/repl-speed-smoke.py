#!/usr/bin/env python3
"""Check per-turn output rates, streaming windows, and buffered fallbacks."""
import json
from pathlib import Path
import re
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer

from smoke import clean_environment, JSONProvider, run_repl


class Provider(JSONProvider):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        prompt = next(m['content'] for m in reversed(body['messages']) if m['role'] == 'user')
        if not body.get('stream'):
            time.sleep(.2)
            self.respond({'choices': [{'message': {'role': 'assistant', 'content': 'x' * 80},
                                       'finish_reason': 'stop'}]})
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()

        def send(payload):
            self.wfile.write(('data: ' + json.dumps(payload) + '\n\n').encode())
            self.wfile.flush()

        # Initial and trailing waits should not dilute a paced stream's rate.
        time.sleep(.4)
        chunks = 1 if prompt == 'burst' else 3
        interval = .4 if prompt == 'slower' else .2
        for index in range(chunks):
            if index:
                time.sleep(interval)
            send({'choices': [{'index': 0, 'delta': {'content': 'x' * 80},
                               'finish_reason': None}]})
        time.sleep(.4)
        # The slower backend includes unreported thinking in its completion total.
        send({'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}],
              'usage': {'prompt_tokens': 1000,
                        'completion_tokens': 4000 if prompt == 'slower' else chunks * 20}})
        self.wfile.write(b'data: [DONE]\n\n')
        self.wfile.flush()


def main():
    binary = str(Path(sys.argv[1]).resolve())
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = clean_environment() | {'NO_PROXY': '127.0.0.1,localhost', 'NO_COLOR': '1'}
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-speed-') as directory:
            root = Path(directory)
            config = root / 'config.json'
            config.write_text(json.dumps({
                'defaultAgent': 'main',
                'providers': [{'id': 'fixture', 'kind': 'openAICompatible',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                'agents': [{'id': 'main', 'provider': 'fixture', 'model': 'fixture',
                            'toolNames': [], 'toolGroupNames': [],
                            'retry': {'attempts': 0}, 'autocompact': {'tokens': 0}}],
                'memory': {'enabled': False}, 'use': {'plan': False},
            }))
            command = [binary, '--config', str(config), '--home', str(root / 'home'),
                       '--no-markdown']

            def rates(output):
                footers = [line for line in output.splitlines() if '✓ took ' in line]
                matches = [re.search(r' · avg (~?)(\d+\.\d+) tok/s', line) for line in footers]
                assert matches and all(matches), output
                return [(match[1], float(match[2])) for match in matches]

            output = run_repl(command, ['paced', 'slower', 'burst'], cwd=root, env=env)
            speeds = rates(output)
            assert len(speeds) == 3, output
            assert speeds[0][0] == '' and 110 < speeds[0][1] < 190, output
            assert speeds[1][0] == '~' and 55 < speeds[1][1] < 95, output
            assert speeds[2][0] == '' and 15 < speeds[2][1] < 35, output
            output = run_repl(command + ['--no-stream'], ['unstreamed'], cwd=root, env=env)
            speed, = rates(output)
            assert speed[0] == '~' and 60 < speed[1] < 140, output
    finally:
        server.shutdown()
        server.server_close()
    print('PASS response speed: per-turn rates, stream timing, hidden thinking, burst and no-usage fallbacks')


if __name__ == '__main__':
    main()
