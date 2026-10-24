#!/usr/bin/env python3
"""Deferred lines wait for tool loops and side questions, then dispatch in FIFO order."""
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
from smoke import JSONProvider, clean_environment, expect_pty, read_pty


requests = queue.Queue()
gates = {name: threading.Event() for name in ('main', 'tool-result', 'side', 'first')}


class Provider(JSONProvider):
    def do_GET(self):
        self.respond({'data': [{'id': 'test'}, {'id': 'next'}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        last = body['messages'][-1]
        prompt = 'tool-result' if last['role'] == 'tool' else last['content']
        requests.put((prompt, body))
        if prompt in gates:
            gates[prompt].wait(20)
        if prompt == 'main':
            message = {'role': 'assistant', 'content': '', 'tool_calls': [{
                'id': 'read', 'type': 'function', 'function': {
                    'name': 'files_read', 'arguments': json.dumps({'path': 'input.txt'})}}]}
        else:
            message = {'role': 'assistant', 'content': f'DONE-{prompt}'}
        try:
            self.respond({'choices': [{'message': message,
                'finish_reason': 'tool_calls' if prompt == 'main' else 'stop'}]})
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    binary = str(Path(sys.argv[1]).resolve())
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(clean_environment(), TERM='xterm-256color', NO_COLOR='1', NO_PROXY='127.0.0.1,localhost')
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-then-') as directory:
            root = Path(directory)
            (root / 'input.txt').write_text('fixture')
            skill = root / '.pmai/skills/extra'
            skill.mkdir(parents=True)
            (skill / 'SKILL.md').write_text('---\nname: extra\ndescription: Test skill\n---\nSKILL-$ARGUMENTS')
            config = root / 'config.json'
            config.write_text(json.dumps({
                'defaultAgent': 'test',
                'providers': [{'id': 'test', 'kind': 'openai',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                'toolSources': [{'id': 'standard', 'kind': 'standard-tools'}],
                'agents': [{'id': 'test', 'provider': 'test', 'model': 'test',
                            'toolNames': ['files_read'], 'toolGroupNames': ['skills'],
                            'autocompact': {'tokens': 0}, 'retry': {'attempts': 0}}],
                'memory': {'enabled': False}, 'use': {'plan': False}, 'approvals': {'mode': 'yolo'},
            }))
            command = [binary, '--config', str(config), '--home', str(root / 'home'),
                       '--no-stream', '--no-markdown']
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 200, 0, 0))
            process = subprocess.Popen(command, cwd=root, env=env, stdin=slave,
                                       stdout=slave, stderr=slave, start_new_session=True)
            os.close(slave)
            output = bytearray()

            def send(text):
                os.write(master, (text + '\r').encode())

            def wait(text):
                return expect_pty(master, process, output, text, 15)

            def request(expected, model='test'):
                deadline = time.monotonic() + 15
                while requests.empty():
                    assert time.monotonic() < deadline, output.decode(errors='replace')
                    read_pty(master, output, .05)
                prompt, body = requests.get_nowait()
                assert expected in prompt, (expected, prompt, body)
                assert body['model'] == model, body
                return body

            try:
                wait('pmai>')
                # /queue allocates a chat root even before its first turn.
                send('/queue')
                wait('pmai>')
                send('/then /version > idle-version.txt')
                deadline = time.monotonic() + 15
                while not (root / 'idle-version.txt').exists():
                    assert time.monotonic() < deadline, output.decode(errors='replace')
                    read_pty(master, output, .05)
                send('main')
                request('main')
                send('/then dropped')
                wait('then: queued (1 waiting)')
                send('/then')
                wait('1. dropped')
                send('/unthen')
                wait('Cleared /then queue.')
                send('/then')
                wait('No /then actions queued.')
                lines = ['first', '/model next', 'second', '/skills prompt extra payload',
                         '/version > queued-version.txt']
                for count, line in enumerate(lines, 1):
                    send('/then ' + line)
                    wait(f'then: queued ({count} waiting)')
                assert not (root / 'queued-version.txt').exists()
                send('/btw side')
                request('side')
                assert requests.empty()
                gates['main'].set()
                body = request('tool-result')
                users = [m['content'] for m in body['messages'] if m['role'] == 'user']
                assert users == ['main'], body
                gates['tool-result'].set()
                wait('DONE-tool-result')
                wait('✓ took')
                assert requests.empty(), 'Queue ran before the side question finished'
                gates['side'].set()
                body = request('first')
                assert any(m['role'] == 'assistant' and m.get('content') == 'DONE-tool-result'
                           for m in body['messages']), body
                assert requests.empty(), 'Deferred prompts overlapped'
                gates['first'].set()
                # /model assigns the tool specialist too: its stop decision
                # hands the same turn to the primary model for the final reply.
                request('second', model='next')
                request('second', model='next')
                request('SKILL-payload', model='next')
                body = request('SKILL-payload', model='next')
                assert any(m['role'] == 'assistant' and m.get('content') == 'DONE-second'
                           for m in body['messages']), body
                deadline = time.monotonic() + 15
                while not (root / 'queued-version.txt').exists():
                    assert time.monotonic() < deadline, output.decode(errors='replace')
                    read_pty(master, output, .05)
                send('/then')
                wait('No /then actions queued.')
                assert (root / 'queued-version.txt').read_text().strip()
                # Idle queues start without waiting for another completion event.
                send('/then idle')
                request('idle', model='next')
                request('idle', model='next')
                wait('DONE-idle')
                send('/exit')
                process.wait(timeout=10)
                assert process.returncode == 0
                assert requests.empty()
                print('PASS /then: tool-loop isolation, all-task idle, FIFO, clear, model, skills, redirection, idle start')
            finally:
                for gate in gates.values():
                    gate.set()
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
