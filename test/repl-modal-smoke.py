#!/usr/bin/env python3
"""Check live modal transitions, isolated input, and draft restoration in a PTY."""
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

from smoke import JSONProvider, clean_environment, expect_pty, read_pty


requests = queue.Queue()
release = threading.Event()


class Provider(JSONProvider):
    def do_GET(self):
        self.respond({'data': [{'id': 'modal'}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.put(request)
        users = [m['content'] for m in request['messages'] if m['role'] == 'user']
        message = {'role': 'assistant', 'content': 'MODAL DONE'}
        if users == ['ask'] and not any(m['role'] == 'tool' for m in request['messages']):
            assert release.wait(20), 'Approval fixture was never released'
            message = {'role': 'assistant', 'content': '', 'tool_calls': [{
                'id': 'write', 'type': 'function', 'function': {
                    'name': 'files_write',
                    'arguments': json.dumps({'path': 'approved.txt', 'content': 'original'})}}]}
        self.respond({'choices': [{'message': message,
                                  'finish_reason': 'tool_calls' if 'tool_calls' in message else 'stop'}]})


def main():
    binary = str(Path(sys.argv[1]).resolve())
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for action in ('edit', 'deny', 'cancel', 'search', 'heredoc'):
            release.clear()
            with tempfile.TemporaryDirectory(prefix='pmai-modal-') as directory:
                root = Path(directory)
                config = root / 'config.json'
                config.write_text(json.dumps({
                    'defaultAgent': 'main',
                    'providers': [{'id': 'local', 'kind': 'openAICompatible',
                                   'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                    'toolSources': [{'id': 'standard', 'kind': 'standard-tools'}],
                    'agents': [{'id': 'main', 'provider': 'local', 'model': 'modal',
                                'toolNames': ['files_write'], 'autocompact': {'tokens': 0}}],
                    'approvals': {'mode': 'ask'}, 'memory': {'enabled': False},
                    'use': {'plan': False},
                    'ui': {'mode': 'buffer' if action == 'deny' else 'classic',
                           'fgselection': '#ffffff', 'bgselection': '#123456'},
                }))
                history = root / 'history.json'
                master, slave = pty.openpty()
                cooked = termios.tcgetattr(slave)
                # Keep this narrow: the decision must precede project/model details.
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 64, 0, 0))
                env = clean_environment()
                env.pop('NO_COLOR', None)
                env.update(TERM='xterm-256color', NO_PROXY='127.0.0.1,localhost')
                if action == 'deny':
                    env['NO_COLOR'] = '1'
                process = subprocess.Popen(
                    [binary, '--config', str(config), '--home', str(root / 'home'),
                     '--history', str(history), '--no-stream', '--no-markdown'],
                    cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave)
                os.close(slave)
                output = bytearray()

                def wait(text):
                    return expect_pty(master, process, output, text, 15)

                def send(text):
                    os.write(master, text.encode())

                def line(text):
                    output.clear()
                    send(text + '\r')

                def check_question():
                    # Resize forces the retained footer to repaint after any
                    # inspection output. Both output modes must keep the question.
                    output.clear()
                    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 26, 68, 0, 0))
                    os.kill(process.pid, signal.SIGWINCH)
                    painted = wait("Approve confirm tool 'files_write'?")
                    read_pty(master, output, .1)
                    painted += output.decode(errors='replace')
                    moves = list(re.finditer(r'\x1b\[(\d+);(\d+)H', painted))
                    footer = []
                    for index, move in enumerate(moves):
                        row = int(move.group(1))
                        end = moves[index + 1].start() if index + 1 < len(moves) else len(painted)
                        if 13 <= row < 25:
                            footer.append(painted[move.end():end])
                    pinned = ''.join(footer)
                    assert "Approve confirm tool 'files_write'?" in pinned, repr(painted)
                    assert 'approved.txt' in pinned, repr(painted)
                    style = r'\x1b\[7m' if action == 'deny' else r'\x1b\[38;2;255;255;255;48;2;18;52;86m'
                    assert re.search(style, pinned), repr(pinned)
                    # Return to the original geometry for draft/caret assertions.
                    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 64, 0, 0))
                    os.kill(process.pid, signal.SIGWINCH)
                    read_pty(master, output, .1)

                def next_request():
                    return requests.get(timeout=15)

                try:
                    wait('pmai> ')
                    line('ask')
                    assert next_request()['messages'][-1]['content'] == 'ask'
                    wait('pmai#')
                    if action == 'edit':
                        # Leaving chat chop must not cancel the provider call
                        # still waiting behind it; approval will arrive below.
                        line('/msg chop')
                        wait('chop [n/b/p/e/d/x/q]> ')
                        send('\x03')
                        wait('Chat chop closed.')
                        wait('pmai#')
                    if action == 'heredoc':
                        send('<<END\rfirst line\r')
                        wait('...> ')
                    # An unfinished message (including caret position) must survive the modal.
                    send('draftXZ\x1b[D')
                    wait('draftXZ')
                    if action == 'search':
                        send('\x12')
                        wait('reverse-i-search')
                    output.clear()
                    release.set()
                    shown = wait('APPROVAL REQUIRED')
                    if 'approve [y/a/s/n/e/c]> ' not in shown:
                        shown += wait('approve [y/a/s/n/e/c]> ')
                    assert re.search(r'\x1b\[1;7(?:;[^m]*)?m', shown), repr(shown)
                    # No keystroke was needed to repaint the prompt; the draft is hidden.
                    read_pty(master, output, .05)
                    current = shown + output.decode(errors='replace')
                    input_row = current.rsplit('\x1b[24;1H', 1)[-1].split('\x1b[?7h', 1)[0]
                    assert 'draftXZ' not in input_row, repr(input_row)
                    assert not (root / 'approved.txt').exists()
                    line('this is not a decision')
                    wait('Answer y/a/s/n/e/c')
                    wait('approve [y/a/s/n/e/c]> ')
                    assert requests.empty(), 'Invalid modal input reached the model'
                    # Inspection commands return to the same question.
                    line('/set tool.aproval')
                    wait('tool.aproval = ask')
                    wait('approve [y/a/s/n/e/c]> ')
                    check_question()
                    if action == 'edit':
                        # Tab offers modal answers, not chat history or prompt names.
                        send('e\t\r')
                        wait('EDIT ARGUMENTS')
                        wait('json> ')
                        line('[]')
                        wait('Enter a valid JSON object')
                        wait('json> ')
                        assert not (root / 'approved.txt').exists()
                        line('{"path":"approved.txt","content":"edited"}')
                        restored = wait('approved files_write with the edited arguments')
                    elif action in ('deny', 'search', 'heredoc'):
                        line('n')
                        restored = wait('denied files_write')
                    else:
                        send('\x03')
                        restored = wait('cancelled')
                    if action != 'cancel':
                        next_request()
                        restored += wait('MODAL DONE')
                    if 'draftXZ' not in restored:
                        wait('draftXZ')
                    assert (root / 'approved.txt').exists() == (action == 'edit')
                    if action == 'edit':
                        assert (root / 'approved.txt').read_text() == 'edited'
                    # Once resolved, a redraw must no longer paint the question panel.
                    output.clear()
                    send('\x0c')
                    read_pty(master, output, .15)
                    redrawn = output.decode(errors='replace')
                    assert '48;2;18;52;86m' not in redrawn, repr(redrawn)
                    # Cursor was before Z; this edits the restored draft without retyping it.
                    send('\x7fY\r')
                    if action == 'heredoc':
                        send('END\r')
                    request = next_request()
                    expected = 'first line\ndraftYZ' if action == 'heredoc' else 'draftYZ'
                    assert request['messages'][-1]['content'] == expected, request
                    wait('MODAL DONE')
                    line('/exit')
                    deadline = time.monotonic() + 10
                    while process.poll() is None:
                        assert time.monotonic() < deadline, output.decode(errors='replace')
                        read_pty(master, output, .1)
                    assert process.wait(timeout=5) == 0
                    assert termios.tcgetattr(master) == cooked
                    saved = json.loads(history.read_text())
                    assert 'ask' in saved, saved
                    if action != 'heredoc':
                        assert 'draftYZ' in saved, saved
                    assert 'this is not a decision' not in saved and '[]' not in saved, saved
                    assert not any(entry in saved for entry in ('n', 'e')), saved
                    assert requests.empty()
                    print(f'PASS modal {action}: live prompt, status, input isolation, restored draft')
                finally:
                    release.set()
                    if process.poll() is None:
                        process.kill()
                        process.wait()
                    os.close(master)
    finally:
        release.set()
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
