#!/usr/bin/env python3
"""Side questions overlap real chat HTTP requests without changing their history."""
import fcntl
import json
import os
from pathlib import Path
import pty
import queue
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from http.server import ThreadingHTTPServer
from smoke import JSONProvider, clean_environment, expect_pty, read_pty, run_repl


requests = queue.Queue()
gates = {name: threading.Event() for name in
         ('main', 'first', 'second', 'cancel-side', 'cancel-main', 'exit-side')}


class Provider(JSONProvider):
    def do_GET(self):
        self.respond({'data': [{'id': 'test'}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        prompt = body['messages'][-1]['content']
        requests.put((self.path, body))
        try:
            if body.get('stream'):
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()

                def chunk(text):
                    payload = {'choices': [{'index': 0, 'delta': {'content': text}}]}
                    self.wfile.write(('data: ' + json.dumps(payload) + '\n\n').encode())
                    self.wfile.flush()

                chunk(f'BEGIN-{prompt}\n')
                if prompt in gates:
                    gates[prompt].wait(30)
                chunk(f'END-{prompt}\n')
                self.wfile.write(b'data: [DONE]\n\n')
                self.wfile.flush()
            else:
                if prompt in gates:
                    gates[prompt].wait(30)
                self.respond({'choices': [{'message': {'role': 'assistant', 'content': f'END-{prompt}'},
                                           'finish_reason': 'stop'}]})
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    binary = str(Path(sys.argv[1]).resolve())
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = clean_environment()
    env.update(TERM='xterm-256color', NO_COLOR='1', NO_PROXY='127.0.0.1,localhost')
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-btw-') as directory:
            root = Path(directory)
            config = root / 'config.json'
            config.write_text(json.dumps({
                'version': 1, 'defaultAgent': 'test',
                'providers': [{'id': 'test', 'kind': 'openai',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1'},
                              {'id': 'side', 'kind': 'openai',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/side/v1'}],
                'agents': [{'id': 'test', 'provider': 'test', 'model': 'test',
                            'toolNames': [], 'toolGroupNames': [], 'retry': {'attempts': 0}},
                           {'id': 'quick', 'provider': 'side', 'model': 'named-small',
                            'instructions': 'Answer briefly.',
                            'options': {'reasoningEffort': 'low'},
                            'toolNames': [], 'toolGroupNames': [], 'retry': {'attempts': 0}}],
                'memory': {'enabled': False}, 'use': {'plan': False},
            }))
            command = [binary, '--config', str(config), '--home', str(root / 'home'), '--no-markdown']
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 200, 0, 0))
            process = subprocess.Popen(command, cwd=root, env=env,
                                       stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
            os.close(slave)
            output = bytearray()

            def wait(text):
                return expect_pty(master, process, output, text, 10)

            def send(text):
                os.write(master, text.replace('\n', '\r').encode())

            def request(prompt, isolated=False, model='test', provider='test', effort=None):
                deadline = time.monotonic() + 10
                while requests.empty():
                    assert time.monotonic() < deadline, output.decode(errors='replace')
                    read_pty(master, output, .05)
                path, body = requests.get_nowait()
                assert path == ('/side' if provider == 'side' else '') + '/v1/chat/completions', path
                assert body['model'] == model, body
                if effort is not None:
                    assert body.get('reasoning_effort') == effort, body
                users = [m['content'] for m in body['messages'] if m['role'] == 'user']
                assert users[-1] == prompt, body
                if isolated:
                    assert users == [prompt], body
                    assert not any(m['role'] in ('assistant', 'tool') for m in body['messages']), body

            try:
                wait('pmai>')
                send('main\n')
                request('main')
                wait('BEGIN-main')
                send('/model -btw side::org/small:latest\n')
                wait('btw: task-btw (saved)')
                for prompt in ('first', 'second'):
                    send(f'/btw {prompt}\n')
                    request(prompt, isolated=True, model='org/small:latest', provider='side')
                # Both side requests reach the provider while the main stream is held.
                gates['second'].set()
                wait('│ END-second')
                wait('✓ btw took')
                assert not gates['main'].is_set()
                send('queued-main\n')
                wait('queued (1 waiting)')
                gates['first'].set()
                wait('│ END-first')
                wait('✓ btw took')
                gates['main'].set()
                wait('END-main')
                request('queued-main')
                wait('END-queued-main')
                wait('✓ took')

                # A chat can start while an idle /btw is still running.
                send('/model -btw quick\n')
                wait('btw: quick (saved)')
                send('/btw cancel-side\n')
                request('cancel-side', isolated=True, model='named-small', provider='side', effort='low')
                send('next-main\n')
                request('next-main')
                wait('END-next-main')
                wait('✓ took')
                send('\x03')
                wait('│ cancelled')
                wait('✗ btw took')

                # Stopping a side question restores Ctrl+C to the main turn.
                send('cancel-main\n')
                request('cancel-main')
                send('/btw cancel-side\n')
                request('cancel-side', isolated=True, model='named-small', provider='side', effort='low')
                send('\x03')
                wait('✗ btw took')
                send('\x03')
                wait('✗ took')
                send('/btw exit-side\n')
                request('exit-side', isolated=True, model='named-small', provider='side', effort='low')
                send('/exit\n')
                deadline = time.monotonic() + 10
                while process.poll() is None:
                    assert time.monotonic() < deadline, output.decode(errors='replace')
                    read_pty(master, output, .05)
                assert process.returncode == 0
                chats = [json.loads(path.read_text()) for path in (root / '.pmai/chats').glob('*.json')]
                users = [m['content'][0]['text']['_0'] for chat in chats for m in chat['messages']
                         if m['role'] == 'user']
                assert users == ['main', 'queued-main', 'next-main', 'cancel-main'], users
                print('PASS concurrent /btw: streaming, reverse completion, queue, cancellation, exit, history')
                output = run_repl(command + ['--no-stream'], ['/btw piped'], cwd=root, env=env)
                assert 'END-piped' in output and '✓ btw took' in output, output
                request('piped', isolated=True, model='named-small', provider='side', effort='low')
                print('PASS piped /btw waits for its answer before reading /exit')
                for clear in ('/model -btw -', '/model -btw default', '/model -btw'):
                    run_repl(command + ['--no-stream'],
                             ['/model -btw bare-small', '/btw bare', clear, '/btw fallback'],
                             cwd=root, env=env)
                    request('bare', isolated=True, model='bare-small')
                    request('fallback', isolated=True)
                    assert 'btw' not in json.loads(config.read_text())['taskAgents']
                print('PASS /model -btw: provider/model routing, saved agent effort, restart, bare model, reset')
            finally:
                for gate in gates.values():
                    gate.set()
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)
    finally:
        for gate in gates.values():
            gate.set()
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
