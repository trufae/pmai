#!/usr/bin/env python3
"""Keep local commands and Ctrl+C responsive while 80 agents make progress."""
import fcntl
import json
import os
from pathlib import Path
import pty
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from http.server import ThreadingHTTPServer

from smoke import clean_environment, expect_pty, JSONProvider, read_pty


def main(binary, mode):
    started = set()
    lock = threading.Lock()
    progress = threading.Event()
    finish = threading.Event()

    class Provider(JSONProvider):
        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            turns = sum(m['role'] == 'tool' for m in request['messages'])
            if request['model'] == 'root':
                if turns:
                    finish.wait(60)
                    message = {'role': 'assistant', 'content': 'ROOT-DONE'}
                else:
                    calls = [('agent_start', {'agent': 'worker', 'task': f'worker {i}',
                              'output': 'Read the fixtures.', 'wait': False}) for i in range(80)]
                    message = self.calls(calls)
            else:
                name = next(m['content'] for m in request['messages'] if m['role'] == 'user')
                with lock:
                    started.add(name)
                if turns == 0:
                    message = self.calls([('run_shell', {'command': 'sleep 1'})])
                elif turns == 9:
                    progress.set()
                    message = self.calls([('run_shell', {'command': 'sleep 30'})])
                elif turns > 9:
                    message = {'role': 'assistant', 'content': 'WORKER-DONE'}
                else:
                    message = self.calls([('files_read', {'path': f'fixture-{turns - 1}.txt'})])
                    message['content'] = 'Progress on the fixture. ' * 170
            try:
                self.respond({'choices': [{'message': message, 'finish_reason':
                    'tool_calls' if 'tool_calls' in message else 'stop'}]})
            except (BrokenPipeError, ConnectionResetError):
                pass

        @staticmethod
        def calls(calls):
            return {'role': 'assistant', 'content': None, 'tool_calls': [
                {'id': f'call-{i}', 'type': 'function', 'function': {
                    'name': name, 'arguments': json.dumps(args)}}
                for i, (name, args) in enumerate(calls)]}

    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    server.request_queue_size = 128
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-subagent-load-') as directory:
            root = Path(directory)
            config = root / 'config.json'
            config.write_text(json.dumps({
                'defaultAgent': 'root',
                'providers': [{'id': 'mock', 'kind': 'openAICompatible',
                    'baseURL': f'http://127.0.0.1:{server.server_port}/v1', 'timeout': 90}],
                'toolSources': [{'id': 'standard', 'kind': 'standard-tools',
                    'options': {'tools': ['files_read', 'run_shell']}}],
                'agents': [
                    {'id': 'root', 'provider': 'mock', 'model': 'root', 'stream': False,
                     'toolGroupNames': ['agents'], 'subagentNames': ['worker'],
                     'useToolProxy': False, 'retry': {'attempts': 0},
                     'limits': {'maxSubagents': 80, 'maxToolCalls': 100}},
                    {'id': 'worker', 'provider': 'mock', 'model': 'worker', 'stream': False,
                     'toolNames': ['files_read', 'run_shell'], 'useToolProxy': False,
                     'retry': {'attempts': 0}}],
                'approvals': {'mode': 'yolo'}, 'memory': {'enabled': False},
                'use': {'plan': False, 'agentsmd': 'off'},
                'ui': {'mode': mode, 'subagentOutput': 'none'},
            }))
            for i in range(8):
                (root / f'fixture-{i}.txt').write_text('fixture data\n')
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 180, 0, 0))
            env = clean_environment() | {'TERM': 'xterm-256color', 'NO_COLOR': '1',
                                        'NO_PROXY': '127.0.0.1,localhost'}
            process = subprocess.Popen([str(Path(binary).resolve()), '--config', str(config),
                '--home', str(root / 'home'), '--no-stream', '--no-markdown'],
                cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
            os.close(slave)
            output = bytearray()

            def send(text):
                os.write(master, (text + '\r').encode())

            def wait(text, timeout=5):
                return expect_pty(master, process, output, text, timeout)

            def until(predicate, message):
                deadline = time.monotonic() + 40
                while not predicate():
                    assert process.poll() is None and time.monotonic() < deadline, (
                        message, len(started), output.decode(errors='replace'))
                    read_pty(master, output, .05)

            try:
                wait('pmai> ', 15)
                send('Start 80 workers')
                until(lambda: len(started) == 80, '80 workers did not start')
                send('/history')
                wait('1. Start 80 workers')
                until(progress.is_set, 'workers did not make progress')
                for command, expected in [
                    ('/history path', str(root / 'home/history.json')),
                    ('/history clear', 'Input history cleared.'),
                    ('/history', 'No input history.'),
                    ('/help history', '/history del N'),
                ]:
                    send(command)
                    wait(expected)
                # Interrupt while child commands are still running, then type again.
                os.write(master, b'\x03')
                send('/history path')
                wait(str(root / 'home/history.json'))
                finish.set()
                send('/exit')
                deadline = time.monotonic() + 15
                while process.poll() is None:
                    assert time.monotonic() < deadline, output.decode(errors='replace')
                    read_pty(master, output, .05)
                assert process.wait() == 0
            finally:
                finish.set()
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
                os.close(master)
    finally:
        server.shutdown()
        server.server_close()
    print(f'80-agent UI responsiveness ({mode}): PASS')


if __name__ == '__main__':
    for mode in ('classic', 'buffer'):
        main(sys.argv[1], mode)
