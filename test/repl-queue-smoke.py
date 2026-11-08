#!/usr/bin/env python3
"""Exercise queue choices, cancellation and approval shutdown in a real REPL PTY."""
import fcntl
import json
from smoke import project_storage, expect_pty, read_chat
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
slow_done = threading.Event()


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.put(request)
        texts = [m.get('content') for m in request['messages'] if m['role'] == 'user']
        slow = texts[-1:] == ['slow'] and not release.is_set()
        if slow:
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
        elif texts[-1:] == ['shell'] or any('SHELL_PROCESS_TEST' in (text or '') for text in texts):
            message = {'role': 'assistant', 'content': None, 'tool_calls': [{
                'id': 'shell-1', 'type': 'function', 'function': {
                    'name': 'run_shell',
                    'arguments': json.dumps({'script':
                        'sh -c \'trap "" TERM; echo $$ > child.pid; exec sleep 30\' >/dev/null 2>&1 & wait'}),
                },
            }]}
        elif texts[-1:] == ['approval'] or (request['model'] == 'worker'
                and not texts[-1].endswith('\nuse x > y | z')):
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
        finally:
            if slow:
                slow_done.set()

    def do_GET(self):
        if self.path.endswith('/models'):
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
                       'hey', 'hey-empty', 'hey-idle', 'hey-approval', 'hey-shell', 'hey-all', 'hey-target', 'hey-child', 'hey-background',
                       'approval-eof', 'edit-eof', 'approval-exit', 'edit-exit',
                       'approval-quit', 'edit-quit', 'approval-interrupt', 'edit-interrupt',
                       'child-interrupt', 'child-edit-interrupt', 'child-kill',
                       'background-interrupt', 'background-edit-interrupt',
                       'shell-interrupt', 'shell-child-interrupt'):
            release.clear()
            slow_done.clear()
            with tempfile.TemporaryDirectory(prefix='pmai-queue-') as directory:
                root = Path(directory)
                config = root / 'config.json'
                config.write_text(json.dumps({
                    'version': 1, 'defaultAgent': 'smoke', 'ui': {'mode': 'classic'},
                    'providers': [{'id': 'smoke', 'kind': 'openAICompatible',
                                   'baseURL': f'http://127.0.0.1:{server.server_port}/v1',
                                   'apiKey': 'smoke', 'timeout': 60}],
                    'toolSources': [{'id': 'standard', 'kind': 'standard-tools',
                                     'options': {'tools': ['files_write', 'run_shell']}}],
                    'agents': [{'id': 'smoke', 'provider': 'smoke', 'model': 'smoke',
                                'toolNames': ['files_write', 'run_shell'], 'toolGroupNames': ['agents'], 'enabled': True,
                                'subagentNames': ['worker'],
                                'retry': {'attempts': 0}},
                               {'id': 'worker', 'provider': 'smoke', 'model': 'worker',
                                'toolNames': ['files_write', 'run_shell'], 'toolGroupNames': [], 'enabled': True,
                                'stream': False,
                                'retry': {'attempts': 0}}],
                    'approvals': {'mode': 'ask'},
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
                     '--no-stream', '--no-markdown'] + (['--tool-approval', 'yolo'] if choice.startswith('shell-') or choice == 'hey-shell' else []), cwd=root, env=env,
                    stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
                os.close(slave)
                output = bytearray()
                child_pid = None

                def send(text):
                    os.write(master, text.replace("\n", "\r").encode())

                def wait_for(text):
                    return expect_pty(master, process, output, text, 20)

                def next_request(mailbox, timeout=20):
                    # A terminal keeps consuming output while a request starts.
                    # Do the same here: help text and input redraws can fill the
                    # PTY buffer and block pmai before it reaches the provider.
                    deadline = time.monotonic() + timeout
                    while mailbox.empty():
                        assert time.monotonic() < deadline, (
                            choice, 'provider request timed out',
                            process.poll(), output.decode(errors='replace'))
                        assert process.poll() is None, (process.returncode, output)
                        if select.select([master], [], [], .1)[0]:
                            try:
                                output.extend(os.read(master, 65536))
                            except OSError as error:
                                raise AssertionError((process.poll(), output)) from error
                    return mailbox.get_nowait()

                def wait_for_exit(timeout=10):
                    deadline = time.monotonic() + timeout
                    while process.poll() is None:
                        assert time.monotonic() < deadline, (
                            choice, 'exit timed out', output.decode(errors='replace'))
                        if select.select([master], [], [], .1)[0]:
                            try:
                                output.extend(os.read(master, 65536))
                            except OSError:
                                break
                    process.wait(timeout=max(.1, deadline - time.monotonic()))

                def user_texts():
                    request = next_request(requests)
                    # The OpenAI-compatible provider joins adjacent user turns
                    # on the wire; these prompts are each one line, so split
                    # them back out to check the queue's order.
                    return [text for m in request['messages'] if m['role'] == 'user'
                            for text in m['content'].split('\n\n')]

                def shell_pid():
                    marker = root / 'child.pid'
                    deadline = time.monotonic() + 15
                    while not marker.exists() or not marker.read_text().strip():
                        assert time.monotonic() < deadline, output.decode(errors='replace')
                        assert process.poll() is None, process.returncode
                        if select.select([master], [], [], .05)[0]:
                            output.extend(os.read(master, 65536))
                    return int(marker.read_text())

                def assert_child_stopped():
                    status = subprocess.run(['ps', '-p', str(child_pid), '-o', 'stat='],
                                            capture_output=True, text=True).stdout.strip()
                    assert not status or status.startswith('Z'), (choice, child_pid, status)

                try:
                    wait_for('> ')
                    if choice == 'hey-idle':
                        # Idle /hey must send the new text, preserving completed
                        # exchanges instead of replaying or amending them.
                        main_texts = ['first x > y | z', 'next main message']
                        child_texts = ['first child message', 'next child x > y | z']
                        for index, prefix in enumerate(('', '@main ')):
                            send(f'{prefix}/hey {main_texts[index]}\n')
                            assert user_texts() == main_texts[:index + 1]
                            wait_for('✓ took')
                        send('/fork --empty idle\n')
                        fork = wait_for('and switched to it.')
                        pid = re.search(r'into agent#(\d+)', fork)[1]
                        send(f'/hey {child_texts[0]}\n')
                        assert user_texts() == child_texts[:1]
                        wait_for('✓ took')
                        send('/jobs focus main\n')
                        wait_for('Messages go to this chat again.')
                        send(f'@{pid} /hey {child_texts[1]}\n')
                        assert user_texts() == child_texts
                        wait_for('✓ took')
                        send('/exit\n')
                        wait_for_exit()
                        assert process.returncode == 0, process.returncode
                        chat_path, = (project_storage(root / 'home', root) / 'chats').glob('*.json')
                        chat = read_chat(chat_path)
                        child, = chat['subagents']
                        for conversation, expected in ((chat, main_texts), (child, child_texts)):
                            messages = [m for m in conversation['messages'] if m['role'] != 'system']
                            assert [m['role'] for m in messages] == ['user', 'assistant', 'user', 'assistant'], messages
                            assert [m['content'] for m in messages if m['role'] == 'user'] == [
                                [{'text': {'_0': text}}] for text in expected], messages
                        print('PASS hey-idle: new and completed chats, focused and addressed agents, saved history', flush=True)
                        continue
                    if choice in ('hey-all', 'hey-target'):
                        send('earlier exchange\n')
                        assert user_texts() == ['earlier exchange']
                        wait_for('✓ took')
                        pids = []
                        for title in ('first', 'second'):
                            send('/jobs focus main\n')
                            wait_for('Messages go to this chat again.')
                            send(f'/fork --empty {title}\n')
                            fork = wait_for('and switched to it.')
                            pids.append(re.search(r'into agent#(\d+)', fork)[1])
                            send('slow\n')
                            assert user_texts() == ['slow']
                        # Any addressed slash command is dispatched, including
                        # while an agent is awaiting a provider response.
                        send('@* /help hey\n')
                        for pid in pids:
                            wait_for(f'agent#{pid}: /help')
                            wait_for('targets all active agents.')
                        send('/jobs focus\n')
                        wait_for(f'Messages go to agent#{pids[-1]}.')
                        send('@*,99999 /hey must not arrive\n')
                        wait_for('No agent #99999')
                        targets = pids if choice == 'hey-all' else pids[:1]
                        address = '*' if choice == 'hey-all' else pids[0]
                        send(f'@{address} /hey use x > y | z\n')
                        for _ in targets:
                            assert user_texts() == ['slow\nuse x > y | z']
                        for _ in targets:
                            wait_for('✓ took')
                        if choice == 'hey-target':
                            send(f'@{pids[1]} /stop\n')
                            wait_for('✗ took')
                            send(f'@{pids[1]} /continue\n')
                            assert user_texts() == ['slow']
                            release.set()
                            wait_for('✓ took')
                        # Explicit commands can also address completed agents.
                        send(f'@{pids[0]} /copy 1 copied.txt\n')
                        wait_for('Copied ')
                        assert (root / 'copied.txt').read_text().strip() == 'answer'
                        send('/queue\n')
                        wait_for('Nothing is queued')
                        send('/exit\n')
                        wait_for_exit()
                        assert process.returncode == 0, process.returncode
                        chat_path, = (project_storage(root / 'home', root) / 'chats').glob('*.json')
                        children = read_chat(chat_path)['subagents']
                        assert len(children) == 2, children
                        for child in children:
                            messages = [m for m in child['messages'] if m['role'] != 'system']
                            assert [m['role'] for m in messages] == ['user', 'assistant'], messages
                            expected = 'slow\nuse x > y | z' if str(child['pid']) in targets else 'slow'
                            assert messages[0]['content'] == [{'text': {'_0': expected}}], child
                        print(f'PASS {choice}: addressed commands, focus, validation, restart, saved children', flush=True)
                        continue
                    if choice in ('hey-child', 'hey-background'):
                        prompt = 'background' if choice == 'hey-background' else 'subagent'
                        send(prompt + '\n')
                        assert user_texts() == [prompt]
                        wait_for("wants to run confirm tool 'agent_start'")
                        send('y\n')
                        started = [next_request(requests) for _ in range(2 if prompt == 'background' else 1)]
                        assert any(r['model'] == 'worker' for r in started), started
                        wait_for("wants to run confirm tool 'files_write'")
                        send('@* /hey use x > y | z\n')
                        replacements = [next_request(requests) for _ in range(2)]
                        assert sorted(r['model'] for r in replacements) == ['smoke', 'worker'], replacements
                        for request in replacements:
                            users = [m['content'] for m in request['messages'] if m['role'] == 'user']
                            if request['model'] == 'smoke':
                                # Adjacent user messages (including child
                                # deliveries) are joined on the OpenAI wire.
                                assert users[0].split('\n\n', 1)[0] == prompt + '\nuse x > y | z', request
                            else:
                                assert users[0].endswith('\nuse x > y | z'), request
                            assert 'Cancelled' not in json.dumps(request['messages']), request
                            assert not any(m.get('tool_calls') or m['role'] == 'tool' for m in request['messages']), request
                        for _ in replacements:
                            wait_for('✓ took')
                        send('/exit\n')
                        wait_for_exit()
                        assert process.returncode == 0, process.returncode
                        assert not (root / 'unapproved.txt').exists(), 'Cancelled child approval ran'
                        parent_requests = [r for r in replacements if r['model'] == 'smoke']
                        while not requests.empty():
                            # A restarted child delivers its new answer to its
                            # parent; the old cancellation must never leak in.
                            followup = requests.get_nowait()
                            assert followup['model'] == 'smoke', followup
                            assert 'Cancelled' not in json.dumps(followup['messages']), followup
                            parent_requests.append(followup)
                        assert any('Its answer:\nanswer' in m.get('content', '')
                                   for r in parent_requests for m in r['messages'] if m['role'] == 'user'), parent_requests
                        print(f'PASS {choice}: parent and child cancellation finish before broadcast restart', flush=True)
                        continue
                    if choice.startswith('hey'):
                        # Prevent a completed prompt being replayed by /hey.
                        send('earlier exchange\n')
                        assert user_texts() == ['earlier exchange']
                        wait_for('✓ took')
                        send('/hey\n')
                        wait_for('Use /hey TEXT to start a new prompt for idle agent#')
                        prompt = {'hey-approval': 'approval', 'hey-shell': 'shell'}.get(choice, 'slow')
                        send(prompt + '\n')
                        assert user_texts() == ['earlier exchange', prompt]
                        if choice == 'hey-approval':
                            wait_for("wants to run confirm tool 'files_write'")
                        if choice == 'hey-shell':
                            child_pid = shell_pid()
                        chat_path, = (project_storage(root / 'home', root) / 'chats').glob('*.json')
                        before = read_chat(chat_path)['messages']
                        original = next(m for m in reversed(before) if m['role'] == 'user')
                        addition = '' if choice == 'hey-empty' else 'use x > y | z'
                        send('/hey' + (' ' + addition if addition else '   ') + '\n')
                        # The replacement must reach the provider before the
                        # blocked response is released, without a tool-loop slot.
                        request = next_request(requests)
                        expected = prompt + ('\n' + addition if addition else '')
                        assert [m['content'] for m in request['messages'] if m['role'] == 'user'] == [
                            'earlier exchange', expected], request
                        assert [m['content'] for m in request['messages'] if m['role'] == 'assistant'] == ['answer'], request
                        assert not any(m['role'] == 'tool' or m.get('tool_calls') for m in request['messages']), request
                        if child_pid is not None:
                            assert_child_stopped()
                        release.set()
                        wait_for('✓ took')
                        send('/exit\n')
                        wait_for_exit()
                        assert process.returncode == 0, process.returncode
                        saved = read_chat(chat_path)['messages']
                        assert [m['role'] for m in saved if m['role'] != 'system'] == [
                            'user', 'assistant', 'user', 'assistant'], saved
                        amended, = [m for m in saved if m['id'] == original['id']]
                        assert amended['content'] == [{'text': {'_0': expected}}], amended
                        assert not (root / 'unapproved.txt').exists(), 'Cancelled approval ran'
                        assert requests.empty(), 'Unexpected extra model request'
                        print(f'PASS {choice}: interruption, retry, earlier context, compact saved history', flush=True)
                        continue
                    if choice.startswith('shell-'):
                        prompt = 'shell-child' if choice == 'shell-child-interrupt' else 'shell'
                        send(prompt + '\n')
                        assert user_texts() == [prompt]
                        child_pid = shell_pid()
                        if prompt == 'shell-child':
                            assert next_request(requests, timeout=5)['model'] == 'worker'
                        send('\x03')
                        wait_for('✗ took')
                        assert_child_stopped()
                        assert requests.empty(), 'Provider called after cancellation'
                        send('yes\n')
                        assert user_texts()[-1] == 'yes'
                        wait_for('✓ took')
                        send('/exit\n')
                        wait_for_exit()
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
                            models = sorted(next_request(requests)['model']
                                            for _ in range(2 if prompt == 'background' else 1))
                            assert models == (['smoke', 'worker'] if prompt == 'background' else ['worker']), models
                        approval = wait_for("wants to run confirm tool 'files_write'")
                        if prompt == 'background':
                            pid = re.search(r'agent#(\d+) wants', approval)[1]
                            send(f'/jobs focus {pid}\n')
                            wait_for(f'Messages go to agent#{pid}')
                        if 'edit-' in choice:
                            send('e\n')
                            wait_for('json> ')
                        action = choice.rsplit('-', 1)[1]
                        if action in ('interrupt', 'kill'):
                            if action == 'kill':
                                pid = re.search(r'agent#(\d+) wants', approval)[1]
                                send(f'/jobs kill {pid}\n')
                                assert user_texts() == ['subagent']
                                wait_for('✓ took')
                            else:
                                send('\x03')
                                if prompt != 'background':
                                    wait_for('✗ took')
                                if prompt == 'background':
                                    # Finished conversations keep their focus so
                                    # the person can inspect or continue them.
                                    wait_for(f'agent#{pid} ')
                                    wait_for('✗ killed')
                                    # The prompt may precede the batched completion notice.
                                    send('/jobs focus main\n')
                                    wait_for('Messages go to this chat again.')
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
                        wait_for_exit()
                        assert process.returncode == 0, process.returncode
                        assert not (root / 'unapproved.txt').exists(), 'Unapproved tool ran'
                        assert requests.empty(), 'Provider called again after shutdown'
                        assert termios.tcgetattr(master) == cooked, 'Exit left the tty in raw mode'
                        print(f'PASS {choice}')
                        continue
                    send('slow\n')
                    assert user_texts() == ['slow']
                    send('queued note\n')
                    wait_for('queued (1 waiting)')
                    send('/stop\n' if choice == 'stop' else '\x03')
                    wait_for('still waiting:')
                    release.set()
                    assert slow_done.wait(10), 'Cancelled provider request did not finish'
                    if choice in ('continue', 'stop'):
                        send('/continue\n')
                        actual = user_texts()
                        assert actual == ['slow', 'queued note'], (choice, actual)
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
                    wait_for_exit()
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
        server.shutdown()


if __name__ == '__main__':
    main()
