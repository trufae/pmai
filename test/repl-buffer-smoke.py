#!/usr/bin/env python3
"""Exercise transcript navigation, live output, reflow, and terminal cleanup in a PTY."""
import fcntl
import json
import os
import platform
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

from smoke import clean_environment, JSONProvider, read_pty

CSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
MOVE = re.compile(r'\x1b\[(\d+);(\d+)H')


def main(binary):
    chunks = queue.Queue()

    class Provider(JSONProvider):
        def do_POST(self):
            self.rfile.read(int(self.headers['Content-Length']))
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            while True:
                content = chunks.get(timeout=20)
                if content is None:
                    self.wfile.write(b'data: [DONE]\n\n')
                    self.wfile.flush()
                    return
                delta = content if isinstance(content, dict) else {'content': content}
                event = {'choices': [{'index': 0, 'delta': delta,
                                      'finish_reason': None}]}
                self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())
                self.wfile.flush()

    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-buffer-') as directory:
            root = Path(directory)
            config = root / 'config.json'
            config.write_text(json.dumps({
                'defaultAgent': 'main',
                'providers': [{'id': 'mock', 'kind': 'openAICompatible',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                'toolSources': [{'id': 'standard', 'kind': 'standard-tools',
                                 'options': {'tools': ['files_read']}}],
                'agents': [{'id': 'main', 'provider': 'mock', 'model': 'fixture',
                            'toolNames': ['files_read'], 'toolGroupNames': [], 'retry': {'attempts': 0}}],
                'approvals': {'mode': 'yolo'},
                'memory': {'enabled': False}, 'use': {'plan': False},
                'ui': {'mode': 'buffer'},
            }))
            (root / 'tool-output.txt').write_text(''.join(f'TOOL_ROW{i}\n' for i in range(8)))
            editor = root / 'editor.py'
            editor.write_text("from pathlib import Path\nimport sys\n"
                              "Path(sys.argv[1]).write_text('buffer editor test')\n")
            shell = root / 'shell.py'
            shell.write_text("import os\n"
                             "assert all(os.isatty(fd) for fd in (0, 1, 2))\n"
                             "print('SHELL_INPUT_READY', flush=True)\n"
                             "text = input()\n"
                             "print('SHELL_REPLY_' + text, flush=True)\n")
            env = clean_environment() | {'TERM': 'xterm-256color',
                'NO_PROXY': '127.0.0.1,localhost', 'EDITOR': f'{sys.executable} {editor}'}
            env.pop('NO_COLOR', None)
            master, slave = pty.openpty()
            original = termios.tcgetattr(slave)
            rows, columns = 24, 80
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
            process = subprocess.Popen([binary, '--config', str(config), '--home', str(root / 'home'),
                '--no-markdown'], cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave,
                start_new_session=True)
            os.close(slave)
            screen = {}
            styled_screen = {}
            captured = bytearray()

            def read_for(seconds=.25):
                data = bytearray()
                read_pty(master, data, seconds)
                captured.extend(data)
                text = data.decode()
                moves = list(MOVE.finditer(text))
                for index, move in enumerate(moves):
                    row, column = map(int, move.groups())
                    assert 1 <= row <= rows and 1 <= column <= columns, (row, column, rows, columns)
                    end = moves[index + 1].start() if index + 1 < len(moves) else len(text)
                    content = text[move.end():end]
                    # The renderer clears and replaces each changed row in full.
                    if column == 1 and '\x1b[2K' in content:
                        styled_screen[row] = content
                        screen[row] = CSI.sub('', content).replace('\x1b7', '').replace('\x1b8', '')
                return bytes(data)

            def wait_for(text):
                deadline = time.monotonic() + 12
                while text.encode() not in captured:
                    assert process.poll() is None, captured.decode(errors='replace')
                    assert time.monotonic() < deadline, (text, captured.decode(errors='replace'))
                    read_for(.05)
                read_for(.1)

            def send(text):
                captured.clear()
                os.write(master, text.encode())

            def output():
                return tuple(screen.get(row, '') for row in range(1, rows - 2))

            try:
                wait_for('pmai> ')
                assert b'\x1b[?1006h' in captured, captured
                send('/set ui.mode classic\r')
                wait_for('\x1b[?1049l')
                send('/clear\r')
                wait_for('\x1b[2J')
                send('/set ui.mode buffer\r')
                wait_for('\x1b[?1006h')
                assert json.loads(config.read_text())['ui']['mode'] == 'buffer'
                send('/set ui.scroll\r')
                wait_for('ui.scroll = 1')
                # Reasoning retained while hidden can later be revealed and
                # collapsed repeatedly without changing the answer.
                send('thinking-test\r')
                chunks.put({'reasoning_content': ''.join(f'THINK_ROW{i}\n' for i in range(8))})
                wait_for('Thinking…')
                chunks.put({'content': 'THINK_ANSWER\n'})
                chunks.put(None)
                wait_for('✓ took')
                assert 'THINK_ROW' not in '\n'.join(output()), screen
                for mode, count in (('full', 8), ('line', 1), ('three', 3),
                                    ('five', 5), ('status', 0), ('full', 8)):
                    send(f'/set ui.thinking {mode}\r')
                    wait_for(f'Set ui.thinking = {mode}.')
                    found = set()
                    answer_found = False
                    for _ in range(5):
                        visible = '\n'.join(output())
                        found.update(re.findall(r'THINK_ROW\d', visible))
                        answer_found |= 'THINK_ANSWER' in visible
                        previous = output()
                        send('\x1b[5~')
                        read_for(.1)
                        if output() == previous:
                            break
                    assert found == {f'THINK_ROW{i}' for i in range(8 - count, 8)}, (mode, found)
                    assert answer_found, (mode, screen)
                    send('\x0c')
                    read_for(.1)
                send('/set ui.thinking status\r')
                wait_for('Set ui.thinking = status.')
                send('markdown-test\r')
                chunks.put('**MARKDOWN_BOLD** and `MARKDOWN_CODE`\n')
                chunks.put(None)
                wait_for('✓ took')
                assert '**MARKDOWN_BOLD**' in '\n'.join(output()), screen
                for enabled in ('on', 'off', 'on', 'off'):
                    send(f'/set ui.markdown {enabled}\r')
                    wait_for(f'Set ui.markdown = {enabled}.')
                    visible = '\n'.join(output())
                    assert 'MARKDOWN_BOLD' in visible and 'MARKDOWN_CODE' in visible, screen
                    assert ('**MARKDOWN_BOLD**' in visible) == (enabled == 'off'), screen
                    assert ('`MARKDOWN_CODE`' in visible) == (enabled == 'off'), screen
                send('/theme use missing\r')
                wait_for("error: Unknown theme 'missing'.")
                for command, confirmation, prompt_color, error_color in (
                        ('/theme use slime', "Applied theme 'slime'.",
                         '38;2;136;255;136', '38;2;255;136;136'),
                        ('/theme color fgprompt blue', 'Set theme color fgprompt = blue.',
                         '34', '38;2;255;136;136'),
                        ('/theme use default', "Applied theme 'default'.", '33', '31')):
                    send(command + '\r')
                    wait_for(confirmation)
                    history = []
                    for _ in range(8):
                        history.extend((screen.get(row, ''), styled_screen.get(row, ''))
                                       for row in range(1, rows - 1))
                        previous = output()
                        send('\x1b[5~')
                        read_for(.1)
                        if output() == previous:
                            break
                    assert any('pmai> thinking-test' in plain and f'\x1b[{prompt_color}m' in raw
                               for plain, raw in history), (command, history)
                    assert any("error: Unknown theme 'missing'." in plain
                               and f'\x1b[{error_color}m' in raw for plain, raw in history), (command, history)
                    assert not re.search(rb'\x1b\[\?90\d+m', captured), captured
                    send('\x0c')
                    read_for(.1)
                send('/set ui.tools 0\r')
                wait_for('Set ui.tools = 0.')
                send('tool-test\r')
                chunks.put({'tool_calls': [{'index': 0, 'id': 'read-output', 'type': 'function',
                    'function': {'name': 'files_read', 'arguments': json.dumps({'path': 'tool-output.txt'})}}]})
                chunks.put(None)
                chunks.put('TOOL_ANSWER\n')
                chunks.put(None)
                wait_for('✓ took')
                assert 'TOOL_ROW' not in '\n'.join(output()), screen
                for display, count in (('all', 8), ('2', 2), ('relevant', 3), ('0', 0), ('all', 8)):
                    send(f'/set ui.tools {display}\r')
                    wait_for(f'Set ui.tools = {display}.')
                    found = set()
                    answer_found = False
                    for _ in range(8):
                        visible = '\n'.join(output())
                        found.update(re.findall(r'TOOL_ROW\d', visible))
                        answer_found |= 'TOOL_ANSWER' in visible
                        previous = output()
                        send('\x1b[5~')
                        read_for(.1)
                        if output() == previous:
                            break
                    assert found == {f'TOOL_ROW{i}' for i in range(count)}, (display, found, screen)
                    assert answer_found, (display, screen)
                    send('\x0c')
                    read_for(.1)
                assert json.loads(config.read_text())['ui']['tools'] == -1
                send('/set ui.toolResultLines 2\r')
                wait_for('Set ui.tools = 2.')
                saved_ui = json.loads(config.read_text())['ui']
                assert saved_ui['tools'] == 2 and 'toolResultLines' not in saved_ui, saved_ui
                # Handoff output must be in the restored transcript, not just
                # briefly visible on the shell's screen while the command runs.
                send('!uname\r')
                wait_for('\x1b[?1049h')
                assert platform.system() in '\n'.join(output()), screen
                send("!printf 'BUFFER_STDOUT\\n'; printf 'BUFFER_STDERR\\n' >&2; exit 7\r")
                wait_for('exit status 7')
                assert all(text in '\n'.join(output())
                           for text in ('BUFFER_STDOUT', 'BUFFER_STDERR')), screen
                send(f'!{sys.executable} {shell}\r')
                wait_for('SHELL_INPUT_READY')
                send('interactive\n')
                wait_for('\x1b[?1049h')
                assert 'SHELL_REPLY_interactive' in '\n'.join(output()), screen
                # A later redraw must retain the shell output too.
                send('\x0c')
                read_for()
                assert 'SHELL_REPLY_interactive' in '\n'.join(output()), screen
                send('buffer-test\r')
                chunks.put(''.join(f'ROW{i:02d} content for scrolling\n' for i in range(70)))
                wait_for('ROW69')
                send('\x1b[200~draft first\ndraft last\x1b[201~')
                wait_for('draft last')
                assert 'draft first' in screen[rows - 1] and 'draft last' in screen[rows], screen
                assert 'ROW69' in '\n'.join(output()), screen
                send('\x1b[5~')
                read_for()
                previous = output()
                assert 'ROW69' not in '\n'.join(previous), screen
                assert 'scroll' in screen[rows - 2], screen
                assert 'draft last' in screen[rows], screen

                # Live output must not displace history or the unfinished draft.
                captured.clear()
                chunks.put('NEW OUTPUT WHILE SCROLLED\n')
                read_for(.4)
                assert output() == previous, (previous, output())
                assert 'draft last' in screen[rows], screen

                send('\x1b[<64;10;5M')
                read_for()
                assert output()[1:] == previous[:-1], (previous, output())
                send('\x1b[<65;10;5M')
                read_for()
                assert output() == previous, (previous, output())
                # Click/release packets must be consumed without editing input.
                send('\x1b[<0;10;5M\x1b[<0;10;5m\x1b[M' + chr(32) + chr(42) + chr(37))
                read_for()
                assert 'draft last' in screen[rows], screen

                # Reflow while browsing, and then restore the original width.
                for new_rows, new_columns in ((16, 22), (24, 80)):
                    rows, columns = new_rows, new_columns
                    screen.clear()
                    fcntl.ioctl(master, termios.TIOCSWINSZ,
                                struct.pack('HHHH', rows, columns, 0, 0))
                    os.kill(process.pid, signal.SIGWINCH)
                    read_for()
                    assert 'ROW' in screen[1], screen
                    assert 'draft last' in screen[rows], screen
                assert output() == previous, (previous, output())

                # Kitty Page Down follows the same navigation path as CSI 6~.
                send('\x1b[57355u' * 10)
                wait_for('NEW OUTPUT WHILE SCROLLED')
                assert 'scroll' not in screen[rows - 2], screen
                send('\x1b[57354u')
                read_for()
                assert 'scroll' in screen[rows - 2], screen
                send('\x0c')
                wait_for('NEW OUTPUT WHILE SCROLLED')
                assert 'draft last' in screen[rows], screen

                # Clear the display during streaming, then keep receiving output.
                send('\x7f' * len('draft first\ndraft last') + '/clear\r')
                wait_for('\x1b[2J')
                assert not any(line.strip() for line in output()), screen
                send('\x0c')
                read_for()
                assert not any(line.strip() for line in output()), screen
                chunks.put('AFTER_CLEAR\n')
                wait_for('AFTER_CLEAR')

                chunks.put(None)
                wait_for('✓ took')
                # A new wheel step applies immediately and is saved. Invalid
                # values leave the last configured step intact.
                send('/set ui.scroll=3\r')
                wait_for('Set ui.scroll = 3.')
                for invalid in ('0', '-1', 'nope', '1.5'):
                    send(f'/set ui.scroll={invalid}\r')
                    wait_for('Usage: /set ui.scroll <positive integer>')
                    assert json.loads(config.read_text())['ui']['scroll'] == 3
                send('scroll-step-test\r')
                chunks.put(''.join(f'STEP_ROW{i:02d}\n' for i in range(70)))
                chunks.put(None)
                wait_for('STEP_ROW69')
                wait_for('✓ took')
                send('\x1b[5~')
                read_for()
                previous = output()
                assert 'STEP_ROW' in previous[0], screen
                for up, down in (
                        ('\x1b[<64;10;5M', '\x1b[<65;10;5M'),
                        ('\x1b[M' + chr(96) + chr(42) + chr(37),
                         '\x1b[M' + chr(97) + chr(42) + chr(37))):
                    send(up)
                    read_for()
                    assert output()[3:] == previous[:-3], (previous, output())
                    send(down)
                    read_for()
                    assert output() == previous, (previous, output())
                send('\x0c')
                read_for()
                send('\x03')
                wait_for('Nothing to cancel.')
                # External editors leave and re-enter the alternate screen.
                send('/edit user buffer-test\r')
                wait_for('\x1b[?1049l')
                wait_for('\x1b[?1049h')
                assert b'\x1b[?1000l' in captured and b'\x1b[?1000h' in captured, captured
                send('/set ui.mode classic\r')
                wait_for('\x1b[?1049l')
                assert json.loads(config.read_text())['ui']['mode'] == 'classic'
                send('/set ui.mode buffer\r')
                wait_for('\x1b[?1049h')
                send('/exit\r')
                deadline = time.monotonic() + 10
                while process.poll() is None:
                    read_for(.05)
                    assert time.monotonic() < deadline, 'exit timed out'
                assert process.returncode == 0
                assert b'\x1b[?1000l' in captured and b'\x1b[?1049l' in captured, captured
                assert termios.tcgetattr(master) == original, 'raw tty mode leaked on exit'
                print('PASS buffer: thinking, markdown, tools and theme settings, paging, configurable wheel steps, mouse packets, live history anchor, fixed multiline draft, '
                      'resize, follow, mode persistence, shell output and input, editor handoff '
                      'and terminal cleanup')
            finally:
                chunks.put(None)
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main(str(Path(sys.argv[1]).resolve()))
