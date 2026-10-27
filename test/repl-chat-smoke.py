#!/usr/bin/env python3
"""Check quiet/verbose chat logs and message editor aliases without a model server."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time

from smoke import clean_environment, expect_pty, read_pty, run_repl


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix='pmai-chat-') as directory:
        root = Path(directory).resolve()
        config = root / 'config.json'
        config.write_text(json.dumps({
            'defaultAgent': 'hello', 'providers': [{'id': 'hello', 'kind': 'hello'}],
            'agents': [{'id': 'hello', 'provider': 'hello', 'model': 'hello'}],
            'memory': {'enabled': False}, 'use': {'plan': False},
        }))
        editor = root / 'editor.py'
        editor.write_text('''from pathlib import Path
import sys
path = Path(sys.argv[1])
Path('editor-input.txt').write_text(path.read_text())
path.write_text('Edited in editor: ' + path.read_text())
''')
        env = dict(clean_environment(), PWD=str(root),
                   EDITOR=shlex.join([sys.executable, str(editor)]))
        command = [binary, '--config', str(config), '--home', str(root / 'home'),
                   '--no-markdown', '--no-stream']
        run_repl(command, ['Seed'], cwd=root, env=env)
        saved = next((root / '.pmai/chats').glob('*.json'))
        chat = json.loads(saved.read_text())
        command += ['-r', chat['id']]

        def part(kind, value):
            return {kind: {'_0': value}}

        def message(identifier, role, *content):
            return {'id': identifier, 'role': role, 'content': list(content)}

        attachment = part('file', {'name': 'notes.txt', 'mimeType': 'text/plain',
                                   'text': 'Attached notes'})
        call = part('toolCall', {'id': 'call-1', 'name': 'fixture_tool',
                                 'arguments': {'secret': 'Tool arguments'}})
        result = part('toolResult', {
            'callID': 'call-1', 'isError': False, 'importance': 'normal',
            'content': [part('text', 'Tool output')],
            'structuredContent': {'secret': 'Structured output'},
        })
        fixture = [
            message('system', 'system', part('text', 'Saved instructions')),
            message('question', 'user', part('text', 'Question'), attachment),
            message('thinking', 'assistant', part('text', ''),
                    part('reasoning', 'Hidden thought')),
            message('calls', 'assistant', part('text', 'Working'),
                    part('reasoning', 'Mixed thought'), call),
            message('result', 'tool', result),
            message('legacy-tool', 'tool', part('text', 'Legacy tool output')),
            message('answer', 'assistant', part('text', '**Answer**: café'), result),
        ]

        def reset(messages=fixture):
            saved.write_text(json.dumps(chat | {'messages': messages}))

        def messages():
            return json.loads(saved.read_text())['messages']

        def run(commands, allow_errors=False):
            return run_repl(command, commands, cwd=root, env=env, split=True,
                            allow_errors=allow_errors)

        reset()
        output = run(['/clear'])[0]
        assert 'Conversation cleared.' not in output and '\x1b' not in output, output
        assert messages() == fixture, messages()

        reset()
        quiet, explicit, verbose, compact, invalid, extra = run([
            '/chat log', '/chat log quiet', '/chat log verbose', '/chat messages',
            '/chat log invalid', '/chat log verbose extra',
        ])
        hidden = ['Hidden thought', 'Mixed thought', 'fixture_tool', 'Tool arguments',
                  'Tool output', 'Structured output', 'Legacy tool output']
        for output in (quiet, explicit):
            for text in ['Question', 'Attached notes', 'Working', '**Answer**: café',
                         '## [4] Assistant', '## [7] Assistant', 'Total messages: 7']:
                assert text in output, (text, output)
            for text in hidden + ['## [3]', '## [5]', '## [6]']:
                assert text not in output, (text, output)
        for text in hidden + ['[structured content]', '## [3]', '## [5]', '## [6]']:
            assert text in verbose, (text, verbose)
        assert '[3] Assistant (id: thinking):' in compact and '[reasoning] Hidden thought' in compact, compact
        for output in (quiet, explicit, verbose, compact):
            for identifier in ('question', 'calls', 'answer'):
                assert f'(id: {identifier})' in output, output
        for output in (invalid, extra):
            assert 'Usage: /chat log [quiet|verbose|short]' in output, output
        assert messages() == fixture, messages()

        run(['/chat log > quiet.txt', '/chat log verbose > verbose.txt'])
        for text in hidden:
            assert text not in (root / 'quiet.txt').read_text(), text
            assert text in (root / 'verbose.txt').read_text(), text

        # Each spelling uses the same editor, preserves IDs and attachments, and persists.
        for action in ['/chat edit 2', '/chat edit -6', '/edit chat 2',
                       '/edit chat -6', '/edit chat question', '/edit 2']:
            reset()
            output = run([action])[0]
            assert 'Edited message 2 (id: question).' in output, output
            assert (root / 'editor-input.txt').read_text() == 'Question\nAttached notes'
            expected = json.loads(json.dumps(fixture))
            expected[1]['content'][0] = part('text', 'Edited in editor: Question\nAttached notes')
            assert messages() == expected, (action, messages())

        reset()
        (root / 'editor-input.txt').unlink()
        output = run(['/chat edit 2 Inline text with spaces'])[0]
        assert 'Edited message 2.' in output, output
        expected = json.loads(json.dumps(fixture))
        expected[1]['content'][0] = part('text', 'Inline text with spaces')
        assert messages() == expected, messages()
        assert not (root / 'editor-input.txt').exists()

        reset()
        for action in ['/chat edit', '/chat edit 0', '/chat edit 100',
                       '/edit chat', '/edit chat missing', '/edit chat 2 extra']:
            output = run([action])[0]
            assert 'Usage:' in output, (action, output)
            assert messages() == fixture, (action, messages())
            assert not (root / 'editor-input.txt').exists()

        # Pins belong to individual messages, including system, reasoning and tool rows.
        for last in (fixture[-1], fixture[1], fixture[4], fixture[2], fixture[0]):
            reset([message('earlier', 'user', part('text', 'Earlier message')), last])
            output, repeated = run(['/chat pin', '/chat pin'])
            for text in (output, repeated):
                assert f'📌 Pinned message 2 (id: {last["id"]}).' in text, text
            assert not messages()[0].get('isPinned', False), messages()
            assert messages()[1] == last | {'isPinned': True}, messages()

        # Manual compaction keeps pinned rows verbatim, including linked tools.
        for index, original in enumerate(fixture, 1):
            reset()
            run([f'/chat pin {index}'])
            expected = original | {'isPinned': True}
            for _ in range(2):
                output = run(['/chat compact'])[0]
                assert 'Conversation compacted into a summary.' in output, output
                compacted = messages()
                assert [m for m in compacted if m['id'] == original['id']] == [expected], compacted
                assert any(m['content'][0].get('text', {}).get('_0', '').startswith(
                    'Summary of earlier parts of this conversation') for m in compacted), compacted
            listing = run(['/chat pins'])[0]
            assert f'(id: {original["id"]})' in listing, listing
            assert expected in messages(), messages()

        reset()
        for index in range(1, len(fixture) + 1):
            output = run([f'/chat pin {index}'])[0]
            assert f'📌 Pinned message {index} ' in output, output
        pinned = messages()
        assert all(m['isPinned'] for m in pinned), pinned
        assert [{k: v for k, v in m.items() if k != 'isPinned'} for m in pinned] == fixture
        short, listing, repeated = run(['/chat log short', '/chat pins', '/chat pin 2'])
        for index, role in enumerate(('System', 'User', 'Assistant', 'Assistant', 'Tool', 'Tool', 'Assistant'), 1):
            assert f'[{index}] 📌 {role}' in short, (index, short)
            assert f'## [{index}] 📌 {role}' in listing, (index, listing)
        assert 'Total messages: 7' in short, short
        assert len(messages()) == len(fixture)
        full_pins, short_pins, pinlist = run(['/chat pins', '/chat pins short', '/chat pinlist'])
        assert pinlist == short_pins, (pinlist, short_pins)
        for index, role in enumerate(('System', 'User', 'Assistant', 'Assistant', 'Tool', 'Tool', 'Assistant'), 1):
            assert f'## [{index}] 📌 {role}' in full_pins, (index, full_pins)
            expected = f'[{index}] 📌 {role} (id: {fixture[index - 1]["id"]}):'
            assert expected in short_pins and expected in short, (index, short_pins, short)
        run(['/chat pinlist > all-pins.txt'])
        pin_rows = (root / 'all-pins.txt').read_text().splitlines()
        assert len(pin_rows) == len(fixture), pin_rows
        for row, original in zip(pin_rows, fixture):
            assert f'(id: {original["id"]}):' in row, row
        for text in hidden:
            assert text in full_pins, (text, full_pins)

        for action in ('/chat pin 0', '/chat unpin 0', '/chat pin missing', '/chat pin 2 extra',
                       '/chat pins invalid', '/chat pins short extra', '/chat pinlist extra'):
            output = run([action])[0]
            assert 'Usage:' in output, (action, output)
            assert messages() == pinned
        output = run(['/chat unpin question'])[0]
        assert 'Unpinned message 2 ' in output, output
        assert not messages()[1].get('isPinned', False)
        full_pins, short_pins, pinlist = run(['/chat pins', '/chat pins short', '/chat pinlist'])
        for output in (full_pins, short_pins, pinlist):
            assert '[2]' not in output and '[3]' in output, output
        output = run(['/chat pin -6'])[0]
        assert '📌 Pinned message 2 ' in output, output

        paragraphs = json.loads(json.dumps(fixture))
        paragraphs[1]['content'][0] = part('text', '\r\nFirst line\r\ncontinued\r\n \r\nSECOND PARAGRAPH')
        reset(paragraphs)
        output = run(['/chat pin 2', '/chat log short'])[1]
        assert '[2] 📌 User (id: question): First line continued' in output, output
        assert 'SECOND PARAGRAPH' not in output, output
        output = run(['/chat pins short'])[0]
        assert '[2] 📌 User (id: question): First line continued' in output, output
        assert 'SECOND PARAGRAPH' not in output and '[1]' not in output, output
        run(['/chat pins > pins.txt', '/chat pins short > pins-short.txt', '/chat pinlist > pinlist.txt'])
        assert 'SECOND PARAGRAPH' in (root / 'pins.txt').read_text()
        assert 'SECOND PARAGRAPH' not in (root / 'pins-short.txt').read_text()
        assert (root / 'pinlist.txt').read_text() == '[2] 📌 User (id: question): First line continued\n'
        run(['/chat log short > short.txt'])
        assert '[2] 📌 User (id: question): First line continued' in (root / 'short.txt').read_text()

        # Rewinding keeps the newest pin and drops everything newer; no pin is an error.
        reset()
        output = run_repl(command, ['/chat rewind'], cwd=root, env=env, allow_errors=True)
        assert 'error: No pinned message to rewind to' in output, output
        usage = run(['/chat rewind extra'])[0]
        assert 'Usage: /chat rewind' in usage, usage
        assert messages() == fixture, messages()
        run(['/chat pin 2'])
        output, repeated = run(['/chat rewind', '/chat rewind'])
        assert 'Rewound to pinned message 2; removed 5 newer messages.' in output, output
        assert '📌 User: Question' in output, output
        assert [m['id'] for m in messages()] == ['system', 'question'], messages()
        assert messages()[1]['isPinned'], messages()
        assert 'Already at pinned message 2; nothing to rewind.' in repeated, repeated
        reset()
        run(['/chat pin 4'])
        output = run(['/chat rewind'])[0]
        assert 'Rewound to pinned message 4; removed 4 newer messages.' in output, output
        assert 'unfinished tool transaction' in output, output
        assert [m['id'] for m in messages()] == ['system', 'question', 'thinking'], messages()

        output = run(['/chat clear'])[0]
        assert 'Conversation cleared.' in output, output
        assert all(m['role'] == 'system' for m in messages()), messages()
        assert not any(m.get('isPinned', False) for m in messages())
        for output in run(['/chat pins', '/chat pins short', '/chat pinlist']):
            assert 'No pinned messages.' in output, output

        reset([])
        output = run(['/chat pin'])[0]
        assert 'No messages to pin.' in output, output
        assert messages() == [], messages()
        for output in run(['/chat log', '/chat log verbose']):
            assert 'No conversation messages yet.' in output, output

        if os.name != 'nt':
            import fcntl
            import pty
            import struct
            import termios

            # Completion follows pin changes and chat switches on both surfaces,
            # including an older pin outside the 64-message history window.
            for mode in ('classic', 'buffer'):
                reset([message(f'row-{index:03}', 'user', part('text', f'Row {index}'))
                       | ({'isPinned': True} if index in (0, 70) else {})
                       for index in range(80)])
                settings = json.loads(config.read_text())
                config.write_text(json.dumps(settings | {'ui': {'mode': mode}}))
                master, slave = pty.openpty()
                fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
                terminal_env = env | {'TERM': 'xterm-256color'}
                terminal_env.pop('NO_COLOR', None)
                process = subprocess.Popen(command, cwd=root, env=terminal_env,
                                           stdin=slave, stdout=slave, stderr=slave)
                os.close(slave)
                output = bytearray()

                def wait(text):
                    return expect_pty(master, process, output, text, 15)

                def send(text):
                    os.write(master, text.encode())

                try:
                    wait('pmai> ')
                    send('/chat unpin \t')
                    wait('\x1b[97;44mrow-000\x1b[0m')
                    send('\t')
                    wait('\x1b[97;44mrow-070\x1b[0m')
                    send('\t\r')
                    wait('Unpinned message 1 (id: row-000).')
                    wait('pmai> ')
                    send('/chat unpin row-\t\r')
                    wait('Unpinned message 71 (id: row-070).')
                    wait('pmai> ')
                    send('/chat pin row-050\r')
                    wait('Pinned message 51 (id: row-050).')
                    wait('pmai> ')
                    send('/chat unpin \t\r')
                    wait('Unpinned message 51 (id: row-050).')
                    wait('pmai> ')
                    send('/fork Pin child\r')
                    wait('and switched to it.')
                    wait('> ')
                    send('/chat pin row-020\r')
                    wait('Pinned message 21 (id: row-020).')
                    wait('> ')
                    send('/chat pinlist\r')
                    wait('[21] 📌 User (id: row-020): Row 20')
                    wait('> ')
                    send('/chat unpin \t\r')
                    wait('Unpinned message 21 (id: row-020).')
                    wait('> ')
                    send('/subagents main\r')
                    wait('Messages go to this chat again.')
                    wait('> ')
                    send('/chat new Completion empty\r')
                    wait('pmai> ')
                    send('/chat unpin \t\r')
                    wait('Usage: /chat unpin INDEX|MESSAGE_ID')
                    wait('pmai> ')
                    send('/exit\r')
                    deadline = time.monotonic() + 15
                    while process.poll() is None:
                        assert time.monotonic() < deadline, output.decode(errors='replace')
                        read_pty(master, output, .05)
                    assert process.wait(timeout=5) == 0
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=5)
                    os.close(master)
        print('PASS chat logs: quiet/verbose/short, first paragraphs, pins on all roles across repeated compaction, stable indexes, redirection, '
              'pinlist, pinned ID completion, rewind to the newest pin and its errors; editor aliases, inline text, attachment preservation, persistence and validation')


if __name__ == '__main__':
    main()
