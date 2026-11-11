#!/usr/bin/env python3
"""Progress must reach stderr before the final answer, without polluting stdout."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer

from smoke import JSONProvider, clean_environment


class Provider(JSONProvider):
    def do_GET(self):
        self.respond({'data': [{'id': 'fixture'}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        final = any(message['role'] == 'tool' for message in request['messages'])
        if final and not self.server.release.wait(30):
            self.respond({'error': {'message': 'Progress was never observed'}}, 500)
            return
        text = 'FINAL ANSWER café' if final else 'Inspecting the fixture'
        calls = [] if final else [{
            'id': 'read-fixture', 'type': 'function',
            'function': {'name': 'files_read', 'arguments': json.dumps({'path': 'fixture.txt'})},
        }]
        finish = 'stop' if final else 'tool_calls'
        if request.get('stream'):
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            deltas = [{'role': 'assistant'}, {'content': text}]
            if calls:
                deltas.append({'tool_calls': [dict(calls[0], index=0)]})
            for delta in deltas:
                payload = {'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]}
                self.wfile.write(('data: ' + json.dumps(payload) + '\n\n').encode())
                self.wfile.flush()
            self.wfile.write(('data: ' + json.dumps({'choices': [
                {'index': 0, 'delta': {}, 'finish_reason': finish}]}) + '\n\ndata: [DONE]\n\n').encode())
            self.wfile.flush()
        else:
            message = {'role': 'assistant', 'content': text}
            if calls:
                message['tool_calls'] = calls
            self.respond({'choices': [{'message': message, 'finish_reason': finish}]})


def check(binary, server, *, stream, repl):
    server.release.clear()
    with tempfile.TemporaryDirectory(prefix='pmai-progress-test-') as directory:
        root = Path(directory)
        (root / 'fixture.txt').write_text('Evidence for the tool to read.')
        config = root / 'config.json'
        config.write_text(json.dumps({
            'defaultAgent': 'main',
            'providers': [{'id': 'local', 'kind': 'openAICompatible',
                           'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
            'agents': [{'id': 'main', 'provider': 'local', 'model': 'fixture',
                        'toolNames': ['files_read'], 'toolGroupNames': [],
                        'autocompact': {'tokens': 0}, 'retry': {'attempts': 0}}],
            'memory': {'enabled': False}, 'use': {'plan': False, 'agentsmd': 'off'},
            'approvals': {'mode': 'yolo'},
            'ui': {'tools': 0 if stream else 'icons', 'thinking': 'full'},
        }))
        command = [binary, '--config', str(config), '--home', str(root / 'home'),
                   '--no-markdown', '--progress']
        if not stream:
            command.append('--no-stream')
        if not repl:
            command.append('Inspect the fixture')
        env = clean_environment() | {'NO_PROXY': '127.0.0.1,localhost', 'NO_COLOR': '1'}
        with (root / 'stdout').open('w+') as output:
            process = subprocess.Popen(command, cwd=root, env=env, stdin=subprocess.PIPE,
                                       stdout=output, stderr=subprocess.PIPE)
            log = bytearray()
            try:
                if repl:
                    process.stdin.write(b'Inspect the fixture\n/exit\n')
                    process.stdin.flush()
                # The provider cannot produce its answer until this check releases it.
                deadline = time.monotonic() + 30
                while b'model turn 2' not in log:
                    remaining = deadline - time.monotonic()
                    assert remaining > 0, log.decode(errors='replace')
                    assert select.select([process.stderr], [], [], remaining)[0], log
                    chunk = os.read(process.stderr.fileno(), 65536)
                    assert chunk, (process.poll(), log.decode(errors='replace'))
                    log.extend(chunk)
                before = log.decode()
                assert 'files_read' in before and '✔' in before, before
                if stream:
                    assert 'Inspecting the fixture' in before, before
                server.release.set()
                _, rest = process.communicate(timeout=30)
                log.extend(rest)
                assert process.returncode == 0, log.decode(errors='replace')
                output.seek(0)
                stdout = output.read()
                assert 'FINAL ANSWER café' in stdout, stdout
                assert 'Inspecting the fixture' not in stdout and 'files_read' not in stdout, stdout
                if not repl:
                    assert stdout == 'FINAL ANSWER café\n', stdout
                assert '[pmai] done' in log.decode(), log
            finally:
                server.release.set()
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stderr.close()
                process.stdin.close()


def main():
    binary = str(Path(sys.argv[1]).resolve())
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    server.release = threading.Event()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for stream, repl in [(True, False), (False, False), (True, True)]:
            check(binary, server, stream=stream, repl=repl)
    finally:
        server.release.set()
        server.shutdown()
        server.server_close()
    print('repl progress smoke: ok')


if __name__ == '__main__':
    main()
