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
            if not requests[-1].get('stream'):
                count = sum(not request.get('stream') for request in requests)
                self.respond({'choices': [{'message': {'role': 'assistant', 'content': f'VIEW_SUMMARY_{count}'},
                                          'finish_reason': 'stop'}]})
                return
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
            subprocess.run(['git', 'init', '-q'], cwd=root, check=True)
            subprocess.run(['git', 'add', 'file.txt'], cwd=root, check=True)
            subprocess.run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.org',
                            'commit', '-qm', 'fixture'], cwd=root, check=True)
            env = clean_environment() | {'TERM': 'xterm-256color', 'NO_PROXY': '127.0.0.1,localhost'}
            env.pop('NO_COLOR', None)
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
            scrollbar_spans = {}
            captured = bytearray()
            cursor_visible = True

            def read_for(seconds=.15):
                nonlocal cursor_visible
                data = bytearray()
                read_pty(master, data, seconds)
                captured.extend(data)
                assert b'Fatal access conflict' not in data, data.decode(errors='replace')
                text = data.decode(errors='replace')
                for visibility in re.finditer(r'\x1b\[\?25([hl])', text):
                    cursor_visible = visibility[1] == 'h'
                moves = list(MOVE.finditer(text))
                for index, move in enumerate(moves):
                    row, column = map(int, move.groups())
                    assert 1 <= row <= rows and 1 <= column <= columns, (row, column, rows, columns)
                    end = moves[index + 1].start() if index + 1 < len(moves) else len(text)
                    content = text[move.end():end]
                    if column == 1 and '\x1b[2K' in content:
                        scrollbar.pop(row, None)
                        scrollbar_spans.pop(row, None)
                    match = re.search(r'\x1b\[([0-9;]+)m( +)\x1b\[0m', content)
                    if match and (column > 1 or row < rows - 1):
                        scrollbar[row] = match[1]
                        scrollbar_spans[row] = (column, len(match[2]))
                    if column == 1 and '\x1b[2K' in content:
                        styled_screen[row] = content
                        screen[row] = CSI.sub('', content).replace('\x1b7', '').replace('\x1b8', '')
                    span = scrollbar_spans.get(row)
                    if span and span[0] == 1 and column == span[1] + 1:
                        styled_screen[row] += content
                        screen[row] = CSI.sub('', content).replace('\x1b7', '').replace('\x1b8', '')

            def wait_for(text):
                deadline = time.monotonic() + 15
                while (text.encode() not in captured
                       and text not in CSI.sub('', captured.decode(errors='replace'))):
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
                send('/view history\r')
                wait_for('── view: input history')
                assert '/view history' in top(), screen
                send('/history clear\r')
                wait_for('Input history cleared.')
                assert 'No input history.' in top(), screen
                send('/view off\r')
                read_for()
                before_blank = dict(screen)
                send('\r\r')
                read_for()
                assert screen == before_blank, (before_blank, screen)
                send('/view tod\t')
                wait_for('/view todo')
                send('\r')
                wait_for('── view: project todo')
                assert 'No todos.' in top(), screen
                send('/todo add REMOVED_WORD\x17KEPT_WORD\r')
                wait_for('Todo list saved')
                assert 'KEPT_WORD' in top() and 'REMOVED_WORD' not in top(), screen
                assert 'view focused' not in screen[separator()] and cursor_visible, screen
                send('/todo clear\r')
                wait_for('Todo list cleared.')
                send('\x17')  # An empty prompt must also keep its focus.
                read_for()
                assert 'view focused' not in screen[separator()] and cursor_visible, screen
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
                send('/view prompt $tldr\r')
                wait_for('Waiting for a completed reply')
                assert not requests, requests
                send('FIRST_PROMPT_VIEW_REQUEST\r')
                chunks.put('FIRST_PROMPT_VIEW_ANSWER\n')
                chunks.put(None)
                wait_for('VIEW_SUMMARY_1')
                assert 'VIEW_SUMMARY_1' in top() and 'FIRST_PROMPT_VIEW_ANSWER' in bottom(), screen
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
                for width in (0, 2, -1, -2, 1):
                    send(f'/set ui.scrollbar {width}\r')
                    wait_for(f'Set ui.scrollbar = {width}.')
                    assert len(screen[separator()]) == columns, screen[separator()]
                    if width:
                        start = 1 if width < 0 else columns - width + 1
                        end = start + abs(width) - 1
                        assert all(scrollbar_spans.get(row) == (start, abs(width))
                                   for row in range(1, separator())), scrollbar_spans
                        if abs(width) == 2:
                            conversation = bottom()
                            send(f'\x1b[<0;{start};1M\x1b[<0;{start};1m')
                            read_for()
                            assert top().startswith('THOUGHT_00\n') and bottom() == conversation, screen
                            send(f'\x1b[<0;{end};{separator()-1}M\x1b[<0;{end};{separator()-1}m')
                            read_for()
                            assert 'THOUGHT_39' in top() and bottom() == conversation, screen
                    else:
                        assert not scrollbar_spans, scrollbar_spans
                        watched = top()
                        send(f'\x1b[<0;{columns};1M\x1b[<32;{columns};{separator()-1}M\x1b[<0;{columns};{separator()-1}m')
                        read_for()
                        assert top() == watched, screen
                # Drag the view scrollbar without focusing it; the chat stays put.
                conversation = bottom()
                handles = [row for row in range(1, separator()) if scrollbar.get(row) == '44']
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
                assert '\x1b[44;97;1m' in styled_screen[separator()], styled_screen
                assert len(screen[separator()]) == columns, screen[separator()]
                assert not cursor_visible
                send('\x17')  # Ctrl+W cannot toggle focus from the read-only view either.
                read_for()
                assert 'view focused' in screen[separator()] and not cursor_visible, screen
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
                send('cannot_type\x1b[200~pasted\ntext\x1b[201~')
                read_for()
                assert 'cannot_type' not in screen[rows] and 'pasted' not in screen[rows], screen
                assert len(requests) == 3, requests
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
                send('\x02')  # Ctrl+B pages back like K.
                read_for()
                assert top() == previous_page and bottom() == original_bottom, screen
                send('\x06')
                wait_for('LIVE_THOUGHT')
                assert top() == latest and bottom() == original_bottom, screen
                send('\x1b[<64;2;2M')
                read_for()
                assert top() != latest and bottom() == original_bottom, screen
                send('\x1b[<65;2;2M')
                wait_for('LIVE_THOUGHT')
                send('\t')
                wait_for('Tab on empty prompt')
                assert cursor_visible
                assert '\x1b[48;2;0;34;68m' in styled_screen[separator()], styled_screen
                send('\x1b[6~' * 20)  # Resume following the conversation after its scrollbar tests.
                read_for()
                chunks.put('STREAM_ANSWER\n')
                chunks.put(None)
                wait_for('✓ took')
                assert 'FOLLOWED_THOUGHT' not in bottom() and 'STREAM_ANSWER' in bottom(), screen
                send('/view prompt $tldr\r')
                wait_for('VIEW_SUMMARY')
                assert 'VIEW_SUMMARY' in top() and 'VIEW_SUMMARY' not in bottom(), screen
                summary_request = requests[-1]
                assert 'STREAM_ANSWER' in json.dumps(summary_request['messages']), summary_request
                assert not summary_request.get('tools'), summary_request
                send('/view tools\r')
                wait_for('── view: tools')
                assert 'FOLLOWED_THOUGHT' in bottom(), screen
                send('/view thinking\r')
                wait_for('── view: thinking')
                assert 'FOLLOWED_THOUGHT' not in bottom(), screen
                send('/view prompt $tldr\r')
                wait_for('VIEW_SUMMARY_3')
                for count in (4, 5):
                    send(f'PROMPT_REFRESH_{count}\r')
                    chunks.put('REPEATED_ANSWER\n')
                    wait_for('REPEATED_ANSWER')
                    assert sum(not request.get('stream') for request in requests) == count - 1, requests
                    chunks.put(None)
                    wait_for(f'VIEW_SUMMARY_{count}')
                    assert f'VIEW_SUMMARY_{count}' in top() and f'VIEW_SUMMARY_{count}' not in bottom(), screen
                    assert 'REPEATED_ANSWER' in json.dumps(requests[-1]['messages']), requests[-1]
                    assert not requests[-1].get('tools'), requests[-1]
                send('/todo\r')
                read_for()
                assert sum(not request.get('stream') for request in requests) == 5, requests
                send('/view tools\r')
                wait_for('── view: tools')
                send('PROMPT_VIEW_REPLACED\r')
                chunks.put('NO_PROMPT_REFRESH\n')
                chunks.put(None)
                wait_for('✓ took')
                assert sum(not request.get('stream') for request in requests) == 5, requests
                send('/view thinking\r')
                wait_for('── view: thinking')
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
                wait_for('── view: git diff')
                wait_for('+NEW_LINE')
                assert '-OLD_LINE' in top() and '+NEW_LINE' in top(), screen
                added_row = next(row for row in range(1, separator()) if '+NEW_LINE' in screen.get(row, ''))
                removed_row = next(row for row in range(1, separator()) if '-OLD_LINE' in screen.get(row, ''))
                assert '\x1b[38;2;217;247;227m' in styled_screen[added_row], styled_screen[added_row]
                assert '\x1b[48;2;22;58;36m' in styled_screen[added_row], styled_screen[added_row]
                assert '\x1b[38;2;255;217;221m' in styled_screen[removed_row], styled_screen[removed_row]
                # A timer refresh must keep the chosen viewport even when the diff grows.
                (root / 'file.txt').write_text(''.join(f'NEW_DIFF_{i:02d}\n' for i in range(40)))
                wait_for('+NEW_DIFF_00')
                send('\t' + 'j' * 10)
                read_for()
                anchored = top()
                with (root / 'file.txt').open('a') as output:
                    output.write('REFRESH_END\n')
                read_for(5.2)
                assert top() == anchored, screen
                send('G')
                wait_for('+REFRESH_END')
                send('g\t')
                read_for()
                (root / 'file.txt').write_text('NEW_LINE\n')
                wait_for('+NEW_LINE')
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
                assert not any(row in scrollbar_spans for row in range(1, separator())), scrollbar_spans
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
                send('/msg pin\r')
                wait_for('Pinned')
                send('/view pi\t')
                wait_for('/view pins')
                send('\r')
                wait_for('── view: pinned messages')
                assert 'READ_ANSWER' in top() and 'EDIT_ANSWER' not in top(), screen
                send('/msg unpin -1\r')
                wait_for('Unpinned')
                assert 'No pinned messages.' in top(), screen
                send('/msg pin\r')
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
                child_pid = re.search(r'View child #(\d+)', screen[separator()])[1]
                assert 'CHILD_INITIAL' in top(), screen
                chunks.put('CHILD_BACKGROUND\n')
                wait_for('CHILD_BACKGROUND')
                assert 'CHILD_BACKGROUND' in top() and 'CHILD_BACKGROUND' not in bottom(), screen
                chunks.put(None)
                wait_for('✓ took')
                send('/view pins\r')
                wait_for('── view: pinned messages')
                assert 'READ_ANSWER' in top() and 'CHILD_BACKGROUND' not in top(), screen
                send(f'/jobs focus {child_pid}\r')
                wait_for('Messages go to agent#')
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
                assert cursor_visible
                assert b'\x1b[?1002h' in captured, captured
                assert all('── view:' not in screen.get(row, '') for row in range(1, rows)), screen
                send('/view current\r')  # q returns focus to the prompt without submitting anything.
                wait_for('── view: current conversation')
                send('\t')
                wait_for('view focused')
                resize(3, 60)  # No room for the split: focus must return to the prompt.
                assert cursor_visible
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
                wait_for('── view: git diff')
                wait_for('+NEW_LINE')
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
                send('G')
                read_for()
                # Search remains local, saves ui.highlight, and jumps from the tail to the first hit.
                request_count = len(requests)
                send('/PAGED_000\r')
                wait_for('Set ui.highlight = PAGED_000.')
                assert 'PAGED_000' in top(), screen
                assert b'\x1b[0;30;47mPAGED_000' in captured, captured
                assert json.loads(config.read_text())['ui']['highlight'] == 'PAGED_000'
                assert len(requests) == request_count
                send('G/PAGED_000\r')
                wait_for('Set ui.highlight = PAGED_000.')
                assert 'PAGED_000' in top(), screen  # Repeating the same search jumps again.
                send('/DISCARD')
                read_for()
                assert cursor_visible
                send('\x1b')
                read_for()
                assert not cursor_visible
                assert json.loads(config.read_text())['ui']['highlight'] == 'PAGED_000'
                # Space rotates the panes; Enter expands/restores without sending a message.
                send(' ')
                read_for()
                assert '│'.encode() in captured, captured
                view_column = columns - (columns - 1) // 2 + 1
                painted = captured.decode(errors='replace')
                assert re.search(rf'\x1b\[1;{view_column}H[^H]*user: .*PAGED_000', painted), painted
                # Drag the vertical divider; keyboard resizing uses columns in this layout.
                divider = view_column - 1
                send(f'\x1b[<0;{divider};4M\x1b[<32;35;4M\x1b[<0;35;4m')
                read_for()
                assert '\x1b[1;36H' in captured.decode(errors='replace'), captured
                send('v')
                read_for()
                assert '\x1b[1;35H' in captured.decode(errors='replace'), captured
                send('V')
                read_for()
                # Left scrollbars stay within the right-hand view and keep a one-column gutter.
                send('\t/set ui.scrollbar -1\r')
                wait_for('Set ui.scrollbar = -1.')
                painted = captured.decode(errors='replace')
                assert re.search(r'\x1b\[1;36H\x1b\[[0-9;]+m \x1b\[0m\x1b\[1;37H', painted), painted
                send('\t')
                read_for()
                send(f'\x1b[<0;36;{rows-3}M\x1b[<0;36;{rows-3}m')
                wait_for('PAGED_129')
                send('\x1b[<0;36;1M\x1b[<0;36;1m')
                wait_for('PAGED_000')
                assert all(int(move[2]) >= 35 for move in MOVE.finditer(captured.decode(errors='replace'))
                           if int(move[1]) < rows - 2), captured
                send('\t/set ui.scrollbar 1\r')
                wait_for('Set ui.scrollbar = 1.')
                send('\t')
                read_for()
                send('\r')
                read_for()
                assert separator() == rows - 2, screen
                assert '│'.encode() not in captured, captured
                send('\r')
                read_for()
                assert '│'.encode() in captured, captured
                send(' ')
                read_for()
                assert separator() < rows - 2, screen
                assert len(requests) == request_count
                send('\t')
                read_for()
                send('/highlight\r')
                wait_for('Set ui.highlight = none.')
                assert json.loads(config.read_text())['ui']['highlight'] == ''
                send('/set ui.highlight PAGED_004\r')
                wait_for('Set ui.highlight = PAGED_004.')
                assert b'\x1b[0;30;47mPAGED_004' in captured, captured
                send('/set ui.highlight none\r')
                wait_for('Set ui.highlight = none.')
                send('/view pins\r')
                wait_for('── view: pinned messages')
                send('/msg unpin 1\r')
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
                send('/set ui.tools icons\r')
                wait_for('Set ui.tools = icons.')
                assert '🩹📖📖' in '\n'.join(screen.values()), screen
                send('/view ico\t')
                wait_for('/view iconlog')
                send('\r')
                wait_for('── view: tool icons')
                assert top().strip() == '🩹📖📖', screen
                assert '🩹' not in bottom_output() and '📖' not in bottom_output(), screen
                send('/set ui.tools all\r')
                wait_for('Set ui.tools = all.')
                assert top().strip() == '🩹📖📖', screen
                send('ICON_REQUEST\r')
                tool('files_read', {'path': 'file.txt'})
                wait_for('🩹📖📖📖')  # Live, before the provider returns its next reply.
                assert 'files_read' not in bottom_output(), screen
                chunks.put('ICON_ANSWER\n')
                chunks.put(None)
                wait_for('✓ took')
                send('/view off\r')
                wait_for('files_read')
                assert 'GROUP_LINE' in '\n'.join(screen.values()), screen
                quit_repl()
                output = run_repl([binary, '--config', str(config), '--home', str(root / 'pipe-home')],
                                 ['/view thinking', '/help view'], cwd=root, env=env, allow_errors=True)
                assert 'error: /view requires ui.mode=buffer.' in output and '/view off' in output
                print('PASS view: Markdown settings, horizontal/vertical layouts, fullscreen restore, highlight search/persistence/cancellation, mode guard, sources, pins, first-line message log, read-only focus, Ctrl+W word deletion, focus colors/cursor visibility, blank Enter, history, prompt, independent scrolling, live thinking/tools/diffs, '
                      'background agents, J/K and Ctrl+B/F paging, g/G top/bottom, divider background, v/V resizing, q close, separator dragging, mouse cleanup, '
                      'live ui.tools previews and iconlog, resize, saved reasoning/results, off and cleanup')
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

