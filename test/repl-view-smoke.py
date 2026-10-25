#!/usr/bin/env python3
"""Exercise read-only views, focus, streaming, agent isolation and resize in a PTY."""
import fcntl
import json
import os
from pathlib import Path
import pty
import queue
import re
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from http.server import ThreadingHTTPServer

from smoke import clean_environment, JSONProvider, read_pty, run_repl

CSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
MOVE = re.compile(r'\x1b\[(\d+);(\d+)H')


def main(binary):
    chunks = queue.Queue()
    requests = []

    class Provider(JSONProvider):
        def do_POST(self):
            requests.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            while True:
                chunk = chunks.get(timeout=20)
                if chunk is None:
                    self.wfile.write(b'data: [DONE]\n\n')
                    self.wfile.flush()
                    return
                delta = chunk if isinstance(chunk, dict) else {'content': chunk}
                event = {'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]}
                self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())
                self.wfile.flush()

    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-view-') as directory:
            root = Path(directory)
            config = root / 'config.json'
            config.write_text(json.dumps({
                'defaultAgent': 'main',
                'providers': [{'id': 'mock', 'kind': 'openAICompatible',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                'toolSources': [{'id': 'standard', 'kind': 'standard-tools',
                                 'options': {'tools': ['files_patch', 'files_read']}}],
                'agents': [{'id': 'main', 'provider': 'mock', 'model': 'fixture',
                            'toolNames': ['files_patch', 'files_read'], 'toolGroupNames': [],
                            'retry': {'attempts': 0}}],
                'approvals': {'mode': 'yolo'}, 'memory': {'enabled': False},
                'use': {'plan': False}, 'ui': {'mode': 'buffer', 'thinking': 'full'},
            }))
            (root / 'file.txt').write_text('OLD_LINE\n')
            env = clean_environment() | {'TERM': 'xterm-256color', 'NO_PROXY': '127.0.0.1,localhost'}
            master, slave = pty.openpty()
            rows, columns = 24, 120
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
            process = subprocess.Popen([binary, '--config', str(config), '--home', str(root / 'home'),
                '--no-markdown'], cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave,
                start_new_session=True)
            os.close(slave)
            screen = {}
            styled_screen = {}
            scrollbar = {}
            captured = bytearray()

            def read_for(seconds=.15):
                data = bytearray()
                read_pty(master, data, seconds)
                captured.extend(data)
                text = data.decode(errors='replace')
                moves = list(MOVE.finditer(text))
                for index, move in enumerate(moves):
                    row, column = map(int, move.groups())
                    assert 1 <= row <= rows and 1 <= column <= columns, (row, column, rows, columns)
                    end = moves[index + 1].start() if index + 1 < len(moves) else len(text)
                    content = text[move.end():end]
                    if column == columns:
                        match = re.search(r'\x1b\[(47|100)m ', content)
                        if match:
                            scrollbar[row] = int(match[1])
                    if column == 1 and '\x1b[2K' in content:
                        styled_screen[row] = content
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

            def separator():
                return next(row for row in range(1, rows - 1) if '── view:' in screen.get(row, ''))

            def top():
                return '\n'.join(screen.get(row, '') for row in range(1, separator()))

            def bottom():
                return '\n'.join(screen.get(row, '') for row in range(separator() + 1, rows - 2))

            def bottom_output():
                return '\n'.join(line for line in bottom().splitlines()
                                 if not re.match(r'^pmai[^>]*> ', line))

            def resize(height, width):
                nonlocal rows, columns
                rows, columns = height, width
                screen.clear()
                fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
                os.kill(process.pid, signal.SIGWINCH)
                read_for()

            def drag_separator(target, legacy=False):
                start = separator()
                if legacy:
                    def packet(button, row):
                        return '\x1b[M' + chr(button + 32) + chr(42) + chr(row + 32)
                    send(packet(0, start) + packet(32, target) + packet(3, target))
                else:
                    send(f'\x1b[<0;10;{start}M\x1b[<32;10;{target}M\x1b[<0;10;{target}m')
                read_for()

            def tool(name, arguments):
                chunks.put({'tool_calls': [{'index': 0, 'id': name, 'type': 'function',
                    'function': {'name': name, 'arguments': json.dumps(arguments)}}]})
                chunks.put(None)

            def quit_repl():
                send('/exit\r')
                deadline = time.monotonic() + 10
                while process.poll() is None:
                    assert time.monotonic() < deadline, captured.decode(errors='replace')
                    read_for(.05)
                assert process.returncode == 0

            try:
                wait_for('pmai>')
                send('/view tod\t')
                wait_for('/view todo')
                send('\r')
                wait_for('── view: project todo')
                assert 'No todos.' in top(), screen
                send('/todo add VIEW_TODO_ITEM\r')
                wait_for('Todo list saved')
                assert 'Todo (1 pending, 0 done):' in top(), screen
                assert '1. [ ] VIEW_TODO_ITEM' in top(), screen
                send('/todo done 1\r')
                wait_for('Todo list saved')
                assert 'Todo (0 pending, 1 done):' in top(), screen
                assert '1. [x] VIEW_TODO_ITEM' in top(), screen
                send('/todo clear\r')
                wait_for('Todo list cleared.')
                assert 'No todos.' in top() and 'VIEW_TODO_ITEM' not in top(), screen
                send('/view pins\r')
                wait_for('── view: pinned messages')
                assert 'No pinned messages.' in top(), screen
                send('/view log\r')
                wait_for('── view: message log')
                send('/set ui.mode classic\r')
                wait_for('\x1b[?1049l')
                send('/view thinking\r')
                wait_for('error: /view requires ui.mode=buffer.')
                send('/set ui.mode buffer\r')
                wait_for('\x1b[?1049h')
                send('/view thinking\r')
                wait_for('── view: thinking')
                assert '\x1b[48;2;0;34;68m' in styled_screen[separator()], styled_screen
                assert b'\x1b[?1002h' in captured, captured
                assert 'No matching output yet.' in top(), screen
                send('STREAM_REQUEST\r')
                chunks.put({'reasoning_content': ''.join(f'THOUGHT_{i:02d}\n' for i in range(40))})
                wait_for('THOUGHT_39')
                assert 'THOUGHT_' not in bottom(), screen
                for mode in ('three', 'status', 'full'):
                    send(f'/set ui.thinking {mode}\r')
                    wait_for(f'Set ui.thinking = {mode}.')
                    assert 'THOUGHT_39' in top(), screen
                    below = '\n'.join(screen.get(row, '') for row in range(separator() + 1, rows))
                    assert 'THOUGHT_' not in below and 'Thinking…' not in below, screen
                # Drag the view scrollbar without focusing it; the chat stays put.
                conversation = bottom()
                handles = [row for row in range(1, separator()) if scrollbar.get(row) == 47]
                assert 0 < len(handles) < separator() - 1, scrollbar
                grab = handles[-1]
                send(f'\x1b[<0;{columns};{grab}M\x1b[<32;{columns};1M\x1b[<0;{columns};1m')
                read_for()
                assert top().startswith('THOUGHT_00\n') and bottom() == conversation, screen
                assert 'view focused' not in screen[separator()], screen
                send(f'\x1b[<0;{columns};1M\x1b[<32;{columns};{separator()-1}M\x1b[<0;{columns};{separator()-1}m')
                read_for()
                assert 'THOUGHT_39' in top() and bottom() == conversation, screen
                # Dragging the lower pane leaves the view at its own position.
                watched = top()
                send(f'\x1b[<0;{columns};{rows-3}M\x1b[<32;{columns};{separator()+1}M\x1b[<0;{columns};{separator()+1}m')
                read_for()
                assert top() == watched, screen
                send(f'\x1b[<0;{columns};{rows-3}M\x1b[<0;{columns};{rows-3}m')
                read_for()
                original_top, original_bottom = top(), bottom()
                send('\t')
                wait_for('view focused')
                assert '\x1b[48;2;0;34;68;1m' in styled_screen[separator()], styled_screen
                send('g')
                read_for()
                assert top().startswith('THOUGHT_00\n') and bottom() == original_bottom, screen
                first_page = top()
                send('g')
                read_for()
                assert top() == first_page, screen
                send('G')
                read_for()
                assert top() == original_top and bottom() == original_bottom, screen
                send('kkk')
                read_for()
                assert top() != original_top and bottom() == original_bottom, screen
                anchored = top()
                send('cannot type\x1b[200~pasted\ntext\x1b[201~\r')
                read_for()
                assert 'cannot type' not in screen[rows] and 'pasted' not in screen[rows], screen
                assert len(requests) == 1, requests
                chunks.put({'reasoning_content': 'LIVE_THOUGHT\n'})
                read_for()
                assert top() == anchored, screen  # Stream updates preserve the view's anchor.
                send('G')
                wait_for('LIVE_THOUGHT')
                chunks.put({'reasoning_content': 'FOLLOWED_THOUGHT\n'})
                wait_for('FOLLOWED_THOUGHT')
                latest = top()
                send('\x1b[5~')
                read_for()
                assert top() != latest and bottom() == original_bottom, screen
                previous_page = top()
                send('\x1b[6~')
                wait_for('LIVE_THOUGHT')
                send('K')
                read_for()
                assert top() == previous_page and bottom() == original_bottom, screen
                send('J')
                wait_for('LIVE_THOUGHT')
                assert top() == latest and bottom() == original_bottom, screen
                send('\x1b[<64;2;2M')
                read_for()
                assert top() != latest and bottom() == original_bottom, screen
                send('\x1b[<65;2;2M')
                wait_for('LIVE_THOUGHT')
                send('\t')
                wait_for('Tab on empty prompt')
                chunks.put('STREAM_ANSWER\n')
                chunks.put(None)
                wait_for('✓ took')
                assert 'FOLLOWED_THOUGHT' not in bottom() and 'STREAM_ANSWER' in bottom(), screen
                send('/view tools\r')
                wait_for('── view: tools')
                assert 'FOLLOWED_THOUGHT' in bottom(), screen
                send('/view thinking\r')
                wait_for('── view: thinking')
                assert 'FOLLOWED_THOUGHT' not in bottom(), screen
                send('/set ui.thinking status\r')
                wait_for('Set ui.thinking = status.')
                send('/vi\t')
                wait_for('/view')
                assert 'view focused' not in screen[separator()], screen
                draft = screen[rows]
                drag_separator(6)
                assert separator() == 6 and screen[rows] == draft, screen
                assert 'view focused' not in screen[separator()], screen
                send('\x1b[<32;10;9M')  # A released drag cannot keep resizing the view.
                read_for()
                assert separator() == 6, screen
                send('\x1b[<0;10;2M\x1b[<32;10;9M\x1b[<0;10;9m')
                read_for()
                assert separator() == 6, screen  # Presses outside the separator are ignored.
                send('\x1b[<2;10;6M\x1b[<34;10;9M\x1b[<2;10;9m')
                read_for()
                assert separator() == 6, screen  # Only the left button starts a resize.
                drag_separator(10, legacy=True)
                assert separator() == 10 and screen[rows] == draft, screen
                drag_separator(1)
                assert separator() == 2 and screen[rows] == draft, screen
                drag_separator(rows)
                assert separator() == rows - 3 and screen[rows] == draft, screen
                drag_separator(12)
                assert separator() == 12 and screen[rows] == draft, screen
                send('\x03')
                read_for()
                send('\t')
                wait_for('view focused')
                drag_separator(8)
                assert separator() == 8 and 'view focused' in screen[separator()], screen
                send('v')
                read_for()
                assert separator() == 9 and 'view focused' in screen[separator()], screen
                send('V')
                read_for()
                assert separator() == 8, screen
                send('v' * rows)
                read_for()
                assert separator() == rows - 3, screen
                send('V' * rows)
                read_for()
                assert separator() == 2, screen
                send('\t')
                wait_for('Tab on empty prompt')
                drag_separator(12)
                resize(18, columns)
                assert separator() == 12, screen
                resize(24, columns)
                assert separator() == 12, screen
                send('/view tools files_patch\r')
                wait_for('── view: tool files_patch')
                assert separator() == 12, screen  # Source changes retain the chosen height.
                send('EDIT_REQUEST\r')
                tool('files_patch', {'path': 'file.txt', 'find': 'OLD_LINE', 'replace': 'NEW_LINE'})
                chunks.put('EDIT_ANSWER\n')
                chunks.put(None)
                wait_for('✓ took')
                assert (root / 'file.txt').read_text() == 'NEW_LINE\n'
                assert 'files_patch' in top() and 'EDIT_ANSWER' not in top(), screen
                assert 'files_patch' not in bottom_output() and 'EDIT_ANSWER' in bottom(), screen
                assert '+NEW_LINE' not in top() and '+NEW_LINE' not in bottom(), screen
                send('/set ui.tools 1\r')
                wait_for('Set ui.tools = 1.')
                assert 'files_patch' in top() and '+NEW_LINE' not in top(), screen
                send('/set ui.tools relevant\r')
                wait_for('Set ui.tools = relevant.')
                assert '+NEW_LINE' in top(), screen
                assert 'files_patch' not in bottom_output() and '+NEW_LINE' not in bottom(), screen
                send('/set ui.tools all\r')
                wait_for('Set ui.tools = all.')
                assert '+NEW_LINE' in top(), screen
                send('/view tools\r')
                wait_for('── view: tools')
                assert '+NEW_LINE' in top(), screen
                send('/set ui.tools 0\r')
                wait_for('Set ui.tools = 0.')
                assert 'files_patch' in top() and '+NEW_LINE' not in top(), screen
                send('/view diffs\r')
                wait_for('── view: applied diffs')
                assert '-OLD_LINE' in top() and '+NEW_LINE' in top(), screen
                diff_rows, main_rows = top(), bottom()
                send('\x1b[5~')
                read_for()
                assert top() == diff_rows and bottom() != main_rows, screen
                send('\x1b[6~')
                read_for()
                send('/set ui.tools all\r')
                wait_for('Set ui.tools = all.')
                send('/view files_read\r')
                wait_for('── view: tool files_read')
                assert 'No matching output yet.' in top(), screen
                send('READ_REQUEST\r')
                tool('files_read', {'path': 'file.txt'})
                chunks.put('READ_ANSWER\n')
                chunks.put(None)
                wait_for('✓ took')
                assert 'NEW_LINE' in top() and 'READ_ANSWER' not in top(), screen
                assert 'files_read' not in bottom_output() and 'NEW_LINE' not in bottom(), screen
                send('/view lo\t')
                wait_for('/view log')
                send('\r')
                wait_for('── view: message log')
                assert 'user: READ_REQUEST' in top() and 'assistant: READ_ANSWER' in top(), screen
                assert '✓ took' not in top() and '/view' not in top(), screen
                send('/chat pin\r')
                wait_for('Pinned')
                send('/view pi\t')
                wait_for('/view pins')
                send('\r')
                wait_for('── view: pinned messages')
                assert 'READ_ANSWER' in top() and 'EDIT_ANSWER' not in top(), screen
                send('/chat unpin -1\r')
                wait_for('Unpinned')
                assert 'No pinned messages.' in top(), screen
                send('/chat pin\r')
                wait_for('Pinned')
                send('/fork View child\r')
                wait_for('and switched to it.')
                send('/view main\r')
                wait_for('── view: main')
                assert '📌 Pinned message' in top(), screen
                send('CHILD_REQUEST\r')
                chunks.put('CHILD_INITIAL\n')
                wait_for('CHILD_INITIAL')
                send('/jobs focus main\r')
                wait_for('Messages go to this chat again.')
                send('/view View child\r')
                wait_for('── view: View child #')
                assert 'CHILD_INITIAL' in top(), screen
                chunks.put('CHILD_BACKGROUND\n')
                wait_for('CHILD_BACKGROUND')
                assert 'CHILD_BACKGROUND' in top() and 'CHILD_BACKGROUND' not in bottom(), screen
                chunks.put(None)
                wait_for('✓ took')
                send('/view pins\r')
                wait_for('── view: pinned messages')
                assert 'READ_ANSWER' in top() and 'CHILD_BACKGROUND' not in top(), screen
                send('/jobs focus 2\r')
                wait_for('Messages go to agent#2')
                send('/view log\r')
                wait_for('── view: message log')
                assert 'user: CHILD_REQUEST' in top() and 'assistant: CHILD_INITIAL' in top(), screen
                assert 'CHILD_BACKGROUND' not in top(), screen  # Only the reply's first line.
                send('/jobs focus main\r')
                wait_for('Messages go to this chat again.')
                assert 'user: CHILD_REQUEST' not in top(), screen
                send('/view agents\r')
                wait_for('── view: agent conversations')
                send('/view off\r')
                read_for()
                assert b'\x1b[?1002h' in captured, captured
                assert all('── view:' not in screen.get(row, '') for row in range(1, rows)), screen
                send('/view current\r')
                wait_for('── view: current conversation')
                send('\t')
                wait_for('view focused')
                send('q')
                read_for()
                assert b'\x1b[?1002h' in captured, captured
                assert all('── view:' not in screen.get(row, '') for row in range(1, rows)), screen
                send('/view current\r')  # q returns focus to the prompt without submitting anything.
                wait_for('── view: current conversation')
                send('\t')
                wait_for('view focused')
                resize(3, 60)  # No room for the split: focus must return to the prompt.
                resize(30, 100)
                assert 'view focused' not in screen[separator()], screen
                assert 'Messages go to this chat again.' in top(), screen
                send('/set ui.mode classic\r')
                wait_for('\x1b[?1049l')
                assert b'\x1b[?1002l' in captured, captured
                send('/set ui.mode buffer\r')
                wait_for('\x1b[?1049h')
                assert all('── view:' not in screen.get(row, '') for row in range(1, rows)), screen
                send('/tools enable todo\r')
                wait_for("Tool selection 'todo': enable")
                send('/view todo\r')
                wait_for('── view: project todo')
                send('TODO_REQUEST\r')
                tool('todo_add', {'title': 'TOOL_TODO_ITEM'})
                chunks.put('TODO_ANSWER\n')
                chunks.put(None)
                wait_for('✓ took')
                assert '1. [ ] TOOL_TODO_ITEM' in top(), screen
                assert 'TODO_ANSWER' not in top(), screen
                quit_repl()
                os.close(master)
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
                process = subprocess.Popen([binary, '--config', str(config), '--home', str(root / 'home'),
                    '--no-markdown', '-r'], cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave,
                    start_new_session=True)
                os.close(slave)
                captured.clear()
                screen.clear()
                wait_for('pmai#1>')
                send('/view pins\r')
                wait_for('── view: pinned messages')
                assert 'READ_ANSWER' in top(), screen
                send('/view log\r')
                wait_for('── view: message log')
                assert 'user: READ_REQUEST' in top() and 'assistant: READ_ANSWER' in top(), screen
                send('/view thinking\r')
                wait_for('── view: thinking')
                assert 'LIVE_THOUGHT' in top(), screen
                send('/view diffs\r')
                wait_for('── view: applied diffs')
                assert '+NEW_LINE' in top(), screen
                send('/view View child\r')
                wait_for('── view: View child #')
                assert 'CHILD_BACKGROUND' in top(), screen
                quit_repl()
                # Saved history larger than one page must still expose early pins and log entries.
                saved = next((root / '.pmai/chats').glob('*.json'))
                chat = json.loads(saved.read_text())
                chat['messages'] = [{'id': f'paged-{i}',
                    'role': 'user' if i % 2 == 0 else 'assistant',
                    'content': [{'text': {'_0': f'PAGED_{i:03d}\nDETAIL_{i:03d}'}}],
                    'isPinned': i == 0} for i in range(130)]
                chat['subagents'] = []
                chat['commands'] = []
                saved.write_text(json.dumps(chat))
                os.close(master)
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
                process = subprocess.Popen([binary, '--config', str(config), '--home', str(root / 'home'),
                    '--no-markdown', '-r'], cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave,
                    start_new_session=True)
                os.close(slave)
                captured.clear()
                screen.clear()
                wait_for('pmai>')
                send('/view pins\r')
                wait_for('── view: pinned messages')
                assert 'PAGED_000' in top() and 'DETAIL_000' in top(), screen
                assert 'PAGED_000' not in bottom(), screen
                send('/view log\r')
                wait_for('── view: message log')
                assert 'assistant: PAGED_129' in top() and 'DETAIL_' not in top(), screen
                send('\t')
                wait_for('view focused')
                conversation = bottom()
                send('g')
                read_for()
                assert top().startswith('user: PAGED_000\nassistant: PAGED_001'), screen
                assert bottom() == conversation, screen
                send('G\t')
                read_for()
                send('/view pins\r')
                wait_for('── view: pinned messages')
                send('/chat unpin 1\r')
                wait_for('Unpinned message 1')
                assert 'No pinned messages.' in top(), screen
                # Filtering the first call must leave later calls grouped and clickable.
                send('/set ui.toolgroups on\r')
                wait_for('Set ui.toolgroups = on.')
                send('/set ui.tools all\r')
                wait_for('Set ui.tools = all.')
                send('/clear\r')
                read_for()
                send('/view files_patch\r')
                wait_for('── view: tool files_patch')
                send('GROUP_REQUEST\r')
                tool('files_patch', {'path': 'file.txt', 'find': 'NEW_LINE', 'replace': 'GROUP_LINE'})
                tool('files_read', {'path': 'file.txt'})
                tool('files_read', {'path': 'file.txt'})
                chunks.put('GROUP_ANSWER\n')
                chunks.put(None)
                wait_for('✓ took')
                assert '+GROUP_LINE' in top() and 'files_patch' not in bottom_output(), screen
                group_row = next(row for row in range(separator() + 1, rows - 2)
                                 if '▸ ' in screen.get(row, ''))
                send(f'\x1b[<0;2;{group_row}M\x1b[<0;2;{group_row}m')
                read_for()
                assert 'files_read' in bottom_output() and 'files_patch' not in bottom_output(), screen
                send('/view tools\r')
                wait_for('── view: tools')
                assert 'files_' not in bottom_output() and 'GROUP_LINE' not in bottom(), screen
                send('/view off\r')
                wait_for('GROUP_LINE')
                assert 'files_patch' in '\n'.join(screen.values()), screen
                quit_repl()
                output = run_repl([binary, '--config', str(config), '--home', str(root / 'pipe-home')],
                                 ['/view thinking', '/help view'], cwd=root, env=env, allow_errors=True)
                assert 'error: /view requires ui.mode=buffer.' in output and '/view off' in output
                print('PASS view: mode guard, sources, pins, first-line message log, read-only focus, independent scrolling, live thinking/tools/diffs, '
                      'background agents, J/K paging, g/G top/bottom, divider background, v/V resizing, q close, separator dragging, mouse cleanup, '
                      'live ui.tools previews, resize, saved reasoning/results, off and cleanup')
            finally:
                chunks.put(None)
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)
    finally:
        server.shutdown()


if __name__ == '__main__':
    main(str(Path(sys.argv[1]).resolve()))
