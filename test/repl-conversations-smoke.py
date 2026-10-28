#!/usr/bin/env python3
"""Exercise agent tabs, isolated history, drafts, background output, and resume."""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from http.server import ThreadingHTTPServer

from smoke import clean_environment, JSONProvider, read_pty

CSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
MOVE = re.compile(r'\x1b\[(\d+);(\d+)H')
requests = []
background_started = threading.Event()
release_background = threading.Event()


class Provider(JSONProvider):
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(request)
        users = [m['content'] for m in request['messages'] if m['role'] == 'user']
        latest = users[-1]
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        if latest == 'BACKGROUND_REQUEST':
            background_started.set()
            release_background.wait(20)
        answer = f'ANSWER_{latest}\n'
        if latest == 'ROOT_REQUEST':
            answer = ''.join(f'ROOT_ROW_{i}\n' for i in range(45)) + answer
        for chunk in (answer[:len(answer)//2], answer[len(answer)//2:]):
            event = {'choices': [{'index': 0, 'delta': {'content': chunk}, 'finish_reason': None}]}
            self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())
            self.wfile.flush()
        self.wfile.write(b'data: [DONE]\n\n')
        self.wfile.flush()


def main(binary):
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-conversations-') as directory:
            root = Path(directory)
            config = root / 'config.json'
            config.write_text(json.dumps({
                'defaultAgent': 'main',
                'providers': [{'id': 'mock', 'kind': 'openAICompatible',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                'agents': [{'id': 'main', 'provider': 'mock', 'model': 'fixture',
                            'instructions': 'SYSTEM_FOR_FORKS', 'toolNames': [],
                            'toolGroupNames': [], 'retry': {'attempts': 0}}],
                'approvals': {'mode': 'yolo'}, 'memory': {'enabled': False},
                'use': {'plan': False}, 'ui': {'mode': 'buffer'},
            }))
            env = clean_environment() | {'TERM': 'xterm-256color', 'NO_PROXY': '127.0.0.1,localhost'}

            def launch(extra=()):
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 26, 140, 0, 0))
                process = subprocess.Popen([binary, '--config', str(config), '--home', str(root / 'home'),
                    '--no-markdown', *extra], cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave,
                    start_new_session=True)
                os.close(slave)
                return master, process

            master, process = launch()
            captured = bytearray()
            screen = {}

            def read_for(seconds=.15):
                data = bytearray()
                read_pty(master, data, seconds)
                captured.extend(data)
                text = data.decode(errors='replace')
                moves = list(MOVE.finditer(text))
                for index, move in enumerate(moves):
                    row, column = map(int, move.groups())
                    end = moves[index + 1].start() if index + 1 < len(moves) else len(text)
                    content = text[move.end():end]
                    if column == 1 and '\x1b[2K' in content:
                        screen[row] = CSI.sub('', content).replace('\x1b7', '').replace('\x1b8', '')

            def wait_for(text):
                deadline = time.monotonic() + 15
                while text.encode() not in captured:
                    assert process.poll() is None, captured.decode(errors='replace')
                    assert time.monotonic() < deadline, (text, captured.decode(errors='replace'))
                    read_for(.05)
                read_for()

            def send(text):
                captured.clear()
                os.write(master, text.encode())

            def output():
                return '\n'.join(screen.get(row, '') for row in range(1, 25))

            def users(request):
                return [m['content'] for m in request['messages'] if m['role'] == 'user']

            try:
                wait_for('pmai>')
                send('/chat rename Tab parent\r')
                wait_for('Chat renamed')
                send('ROOT_REQUEST\r')
                wait_for('✓ took')
                send('\x1b[5~')
                read_for()
                scroll_position = output()
                assert 'ROOT_ROW_0' not in scroll_position and 'ROOT_ROW_' in scroll_position
                send('/fork First child\r')
                wait_for('and switched to it.')
                send('CHILD_ONE_REQUEST\r')
                wait_for('✓ took')
                assert users(requests[-1]) == ['ROOT_REQUEST', 'CHILD_ONE_REQUEST'], requests[-1]
                assert 'ANSWER_CHILD_ONE_REQUEST' in output(), screen
                # Return using a single Alt+number chord, keeping the parent's anchor.
                send('\x1b1')
                read_for()
                assert 'ANSWER_CHILD_ONE_REQUEST' not in output(), screen
                assert 'ROOT_ROW_' in output(), screen
                send('\x1b[5~')
                read_for()
                anchor = output()
                send('\x1b2')
                read_for()
                send('\x1b1')
                read_for()
                assert output() == anchor, screen
                assert '↑ scroll' in screen[25], screen
                send('\x1b[6~')
                read_for()
                send('/fork --empty Second child\r')
                wait_for('and switched to it.')
                assert 'ROOT_ROW_' not in output(), screen
                send('CHILD_TWO_REQUEST\r')
                wait_for('✓ took')
                assert users(requests[-1]) == ['CHILD_TWO_REQUEST'], requests[-1]
                system = requests[-1]['messages'][0]
                assert system['role'] == 'system', system
                assert system['content'].split('\n\n<execution_context>', 1)[0] == 'SYSTEM_FOR_FORKS', system
                # Drafts (including paste boundaries and cursor position) belong to a tab.
                send('\x1b[200~two draft\x1b[201~\x1b[D')
                read_for()
                send('\x1b[50;5u')  # Ctrl+2, kitty protocol
                read_for()
                assert 'two draft' not in screen[26], screen
                send('one draft')
                read_for()
                send('\x1b[1;5C')  # Ctrl+Right -> third slot
                read_for()
                assert 'two draft' in screen[26], screen
                send('X\r')
                wait_for('✓ took')
                assert users(requests[-1]) == ['CHILD_TWO_REQUEST', 'two drafXt'], requests[-1]
                send('\x1b2')
                read_for()
                assert 'one draft' in screen[26], screen
                send('\r')
                wait_for('✓ took')
                assert users(requests[-1]) == ['ROOT_REQUEST', 'CHILD_ONE_REQUEST', 'one draft'], requests[-1]
                # Hidden streaming output stays in its destination buffer.
                send('BACKGROUND_REQUEST\r')
                deadline = time.monotonic() + 10
                while not background_started.is_set():
                    assert time.monotonic() < deadline
                    read_for(.05)
                send('\x1b1')
                read_for()
                release_background.set()
                deadline = time.monotonic() + 10
                while '[1..]' not in screen.get(25, ''):
                    assert time.monotonic() < deadline, screen
                    read_for(.05)
                assert 'ANSWER_BACKGROUND_REQUEST' not in output(), screen
                send('\x1b2')
                read_for()
                assert 'ANSWER_BACKGROUND_REQUEST' in output(), screen
                assert 'pmai#2>' in screen[26], screen
                send('/fork Nested child\r')
                wait_for('and switched to it.')
                send('/subagents parent\r')
                read_for()
                assert 'pmai#2>' in screen[26], screen
                send('/jobs focus main\r')
                wait_for('Messages go to this chat again.')
                send('/subagents\r')
                wait_for('Agent conversations:')
                assert 'First child' in output() and 'Second child' in output(), screen
                send('/exit\r')
                deadline = time.monotonic() + 10
                while process.poll() is None:
                    assert time.monotonic() < deadline, captured.decode(errors='replace')
                    read_for(.05)
                assert process.returncode == 0
                saved = next((root / '.pmai/chats').glob('*.json'))
                chat = json.loads(saved.read_text())
                assert len(chat['subagents']) == 3, chat
                assert all(r['conversationRequest']['messages'] == [] for r in chat['subagents'])
                master_old = master
                master, process = launch(('-r', 'Tab parent'))
                os.close(master_old)
                captured.clear()
                screen.clear()
                wait_for('pmai#1>')
                send('/subagents 2\r')
                wait_for('Messages go to agent#2')
                send('RESUMED_CHILD\r')
                wait_for('✓ took')
                assert users(requests[-1])[-1] == 'RESUMED_CHILD', requests[-1]
                assert 'BACKGROUND_REQUEST' in users(requests[-1]), requests[-1]
                assert 'CHILD_TWO_REQUEST' not in users(requests[-1]), requests[-1]
                send('/copy 1 branch-reply.txt\r')
                wait_for('Copied ')
                assert (root / 'branch-reply.txt').read_text().strip() == 'ANSWER_RESUMED_CHILD'
                send('/last\r')
                wait_for('ANSWER_RESUMED_CHILD')
                send('/continue\r')
                wait_for('Nothing to continue: the last reply was complete.')
                send('/msg edit 2 Edited shared history\r')
                wait_for('Edited message 2.')
                send('EDITED_CHILD_FOLLOWUP\r')
                wait_for('✓ took')
                assert users(requests[-1])[0] == 'Edited shared history', requests[-1]
                current = json.loads(saved.read_text())
                assert current['messages'][1]['content'][0]['text']['_0'] == 'ROOT_REQUEST', current
                send('/exit\r')
                deadline = time.monotonic() + 10
                while process.poll() is None:
                    assert time.monotonic() < deadline, captured.decode(errors='replace')
                    read_for(.05)
                print('PASS conversations: isolated forks, empty history, tab keys, per-agent drafts and scroll, '
                      'background streaming, continued children, nested parents, job focus, and durable resume')
            finally:
                release_background.set()
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)
    finally:
        server.shutdown()


if __name__ == '__main__':
    main(str(Path(sys.argv[1]).resolve()))
