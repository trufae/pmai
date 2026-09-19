#!/usr/bin/env python3
"""Exercise queue choices, cancellation and approval shutdown in a real REPL PTY."""
import fcntl
import json
import os
from pathlib import Path
import pty
import queue
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


requests = queue.Queue()
release = threading.Event()
model_requests = queue.Queue()
models_release = threading.Event()


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.put(request)
        texts = [m.get('content') for m in request['messages'] if m['role'] == 'user']
        if texts == ['slow'] and not release.is_set():
            release.wait(30)
        message = {'role': 'assistant', 'content': 'answer'}
        if texts in (['subagent'], ['background'], ['shell-child']) and not any(m['role'] == 'tool' for m in request['messages']):
            message = {'role': 'assistant', 'content': None, 'tool_calls': [{
                'id': 'start-1', 'type': 'function', 'function': {
                    'name': 'agent_start',
                    'arguments': json.dumps({'agent': 'worker',
                                             'task': 'SHELL_PROCESS_TEST' if texts == ['shell-child'] else 'approval',
                                             'output': 'answer', 'wait': texts != ['background']}),
                },
            }]}
        elif texts == ['shell'] or any('SHELL_PROCESS_TEST' in (text or '') for text in texts):
            message = {'role': 'assistant', 'content': None, 'tool_calls': [{
                'id': 'shell-1', 'type': 'function', 'function': {
                    'name': 'run_sh',
                    'arguments': json.dumps({'script':
                        'sh -c \'trap "" TERM; echo $$ > child.pid; exec sleep 30\' >/dev/null 2>&1 & wait'}),
                },
            }]}
        elif texts == ['approval'] or request['model'] == 'worker':
            message = {'role': 'assistant', 'content': None, 'tool_calls': [{
                'id': 'write-1', 'type': 'function', 'function': {
                    'name': 'files_write',
                    'arguments': json.dumps({'path': 'unapproved.txt', 'content': 'must not run'}),
                },
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

    def do_GET(self):
        if self.path.endswith('/models'):
            model_requests.put(self.path)
            models_release.wait(30)
            body = json.dumps({'data': [{'id': 'smoke', 'owned_by': 'test'}]}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        self.send_error(404)


def main():
    binary = str(Path(sys.argv[1]).resolve())
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for choice in sys.argv[2:] or ('continue', 'submit', 'ignore', 'clear', 'stop',
                       'approval-eof', 'edit-eof', 'approval-exit', 'edit-exit',
                       'approval-quit', 'edit-quit', 'approval-interrupt', 'edit-interrupt',
                       'child-interrupt', 'child-edit-interrupt', 'child-kill',
                       'background-interrupt', 'background-edit-interrupt',
                       'shell-interrupt', 'shell-child-interrupt'):
            release.clear()
            with tempfile.TemporaryDirectory(prefix='pmai-queue-') as directory:
                root = Path(directory)
                config = root / 'config.json'
                config.write_text(json.dumps({
                    'version': 1, 'defaultAgent': 'smoke',
                    'providers': [{'id': 'smoke', 'kind': 'openAICompatible',
                                   'baseURL': f'http://127.0.0.1:{server.server_port}/v1',
                                   'apiKey': 'smoke', 'timeout': 60}],
                    'toolSources': [{'id': 'standard', 'kind': 'standard-tools',
                                     'options': {'tools': ['files_write', 'run_sh']}}],
                    'agents': [{'id': 'smoke', 'provider': 'smoke', 'model': 'smoke',
                                'toolNames': ['files_write', 'run_sh'], 'toolGroupNames': ['agents'], 'enabled': True,
                                'subagentNames': ['worker'],
                                'retry': {'attempts': 0}},
                               {'id': 'worker', 'provider': 'smoke', 'model': 'worker',
                                'toolNames': ['files_write', 'run_sh'], 'toolGroupNames': [], 'enabled': True,
                                'stream': False,
                                'retry': {'attempts': 0}}],
                    'approvals': {'confirm': 'ask', 'dangerous': 'ask', 'yolo': False},
                    'memory': {'enabled': False, 'scope': 'project'}, 'use': {'plan': False},
                }))
                master, slave = pty.openpty()
                cooked = termios.tcgetattr(slave)
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 200, 0, 0))
                env = {k: v for k, v in os.environ.items()
                       if not k.startswith(('PMAI_', 'MAI_', 'OPENAI_'))
                       and k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy')}
                env.update(TERM='xterm-256color', NO_PROXY='127.0.0.1,localhost')
                process = subprocess.Popen(
                    [binary, '--config', str(config), '--home', str(root / 'home'),
                     '--no-stream', '--no-markdown'] + (['-y'] if choice.startswith('shell-') else []), cwd=root, env=env,
                    stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
                os.close(slave)
                output = bytearray()
                child_pid = None

                def send(text):
                    os.write(master, text.replace("\n", "\r").encode())

                def wait_for(text):
                    deadline = time.monotonic() + 20
                    needle = text.encode()
                    while needle not in output:
                        assert time.monotonic() < deadline, (choice, text, output.decode(errors='replace'))
                        assert process.poll() is None, (process.returncode, output)
                        if select.select([master], [], [], .1)[0]:
                            try:
                                output.extend(os.read(master, 65536))
                            except OSError as error:
                                raise AssertionError((process.poll(), output.decode(errors='replace'))) from error
                    end = output.index(needle) + len(needle)
                    captured = bytes(output[:end]).decode(errors='replace')
                    del output[:end]
                    return captured

                def user_texts():
                    request = requests.get(timeout=20)
                    return [m['content'] for m in request['messages'] if m['role'] == 'user']

                try:
                    wait_for('pmai>')
                    if choice.startswith('shell-'):
                        prompt = 'shell-child' if choice == 'shell-child-interrupt' else 'shell'
                        send(prompt + '\n')
                        assert user_texts() == [prompt]
                        marker = root / 'child.pid'
                        deadline = time.monotonic() + 15
                        while not marker.exists() or not marker.read_text().strip():
                            assert time.monotonic() < deadline, output.decode(errors='replace')
                            assert process.poll() is None, process.returncode
                            if select.select([master], [], [], .05)[0]:
                                output.extend(os.read(master, 65536))
                        child_pid = int(marker.read_text())
                        if prompt == 'shell-child':
                            assert requests.get(timeout=5)['model'] == 'worker'
                        send('\x03')
                        wait_for('✗ took')
                        status = subprocess.run(['ps', '-p', str(child_pid), '-o', 'stat='],
                                                capture_output=True, text=True).stdout.strip()
                        assert not status or status.startswith('Z'), (choice, child_pid, status)
                        assert requests.empty(), 'Provider called after cancellation'
                        send('yes\n')
                        assert user_texts()[-1] == 'yes'
                        wait_for('✓ took')
                        send('/exit\n')
                        process.wait(timeout=10)
                        assert process.returncode == 0, process.returncode
                        print(f'PASS {choice}', flush=True)
                        continue
                    if choice.startswith(('approval-', 'edit-', 'child-', 'background-')):
                        prompt = ('background' if choice.startswith('background-') else
                                  'subagent' if choice.startswith('child-') else 'approval')
                        send(prompt + '\n')
                        assert user_texts() == [prompt]
                        if prompt != 'approval':
                            wait_for("wants to run confirm tool 'agent_start'")
                            send('y\n')
                            models = sorted(requests.get(timeout=20)['model']
                                            for _ in range(2 if prompt == 'background' else 1))
                            assert models == (['smoke', 'worker'] if prompt == 'background' else ['worker']), models
                        approval = wait_for("wants to run confirm tool 'files_write'")
                        if prompt == 'background':
                            pid = re.search(r'agent#(\d+) wants', approval)[1]
                            send(f'/agents focus {pid}\n')
                            wait_for(f'Messages go to agent#{pid}')
                        if 'edit-' in choice:
                            send('e\n')
                            wait_for('json> ')
                        action = choice.rsplit('-', 1)[1]
                        if action in ('interrupt', 'kill'):
                            if action == 'kill':
                                pid = re.search(r'agent#(\d+) wants', approval)[1]
                                send(f'/agents kill {pid}\n')
                                assert user_texts() == ['subagent']
                                wait_for('✓ took')
                            else:
                                send('\x03')
                                wait_for('✗ took')
                                if prompt == 'background':
                                    wait_for(f'agent#{pid} has ended; messages go to this chat again.')
                                    wait_for('1 queued')
                            assert requests.empty(), 'Unexpected request after cancellation'
                            # "yes" must reach the provider, not a stale approval prompt.
                            send('yes\n')
                            if prompt == 'background':
                                wait_for('[submit/ignore/clear]')
                                send('clear\n')
                            assert user_texts()[-1] == 'yes'
                            wait_for('✓ took')
                            send('/exit\n')
                        else:
                            send('\x04' if action == 'eof' else f'/{action}\n')
                        process.wait(timeout=10)
                        assert process.returncode == 0, process.returncode
                        assert not (root / 'unapproved.txt').exists(), 'Unapproved tool ran'
                        assert requests.empty(), 'Provider called again after shutdown'
                        assert termios.tcgetattr(master) == cooked, 'Exit left the tty in raw mode'
                        print(f'PASS {choice}')
                        continue
                    if choice == 'continue':
                        send('/help\n')
                        help_text = wait_for('Input:')
                        help_text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', help_text).replace('\r', '')
                        names = re.findall(r'(?m)^(/[a-z]+)\b', help_text)
                        assert len(names) > 20 and names == sorted(names), names
                        assert '/stop' in names and '/retry' not in names, names
                        # Slash commands used to run inside the event loop, so
                        # a stalled catalog request also stopped Ctrl+C and all
                        # subsequent input. It must be a normal cancellable job.
                        models_release.clear()
                        send('/models\n')
                        assert model_requests.get(timeout=20).endswith('/models')
                        send('\x03')
                        wait_for('cancelled /models')
                        send('/help\n')
                        wait_for('Input:')
                        models_release.set()
                    send('slow\n')
                    assert user_texts() == ['slow']
                    send('queued note\n')
                    wait_for('queued (1 waiting)')
                    send('/stop\n' if choice == 'stop' else '\x03')
                    wait_for('still waiting:')
                    release.set()
                    if choice in ('continue', 'stop'):
                        send('/continue\n')
                        assert user_texts() == ['slow', 'queued note']
                    else:
                        send('new message\n')
                        wait_for('Submit them before this message')
                        assert requests.empty(), 'New message sent before queue decision'
                        send(choice + '\n')
                        expected = ['slow', 'queued note', 'new message'] if choice == 'submit' else ['slow', 'new message']
                        assert user_texts() == expected
                    wait_for('took ')
                    send('/queue\n')
                    if choice == 'ignore':
                        wait_for('Queued messages (1)')
                        assert requests.empty(), 'Ignored queue was automatically submitted'
                        send('/continue\n')
                        assert user_texts() == ['slow', 'new message', 'queued note']
                        wait_for('took ')
                    else:
                        wait_for('Nothing is queued')
                    send('/exit\n')
                    process.wait(timeout=10)
                    assert process.returncode == 0
                    print(f'PASS queue {choice}')
                finally:
                    release.set()
                    if child_pid is not None:
                        try:
                            os.kill(child_pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    if process.poll() is None:
                        process.kill()
                        process.wait()
                    os.close(master)
    finally:
        release.set()
        models_release.set()
        server.shutdown()


if __name__ == '__main__':
    main()
