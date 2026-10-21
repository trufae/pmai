#!/usr/bin/env python3
"""Check quiet/verbose chat logs and message editor aliases without a model server."""
import json
from pathlib import Path
import shlex
import sys
import tempfile

from smoke import clean_environment, run_repl


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

        def run(commands):
            return run_repl(command, commands, cwd=root, env=env, split=True)

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
        assert '[3] Assistant:' in compact and '[reasoning] Hidden thought' in compact, compact
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
        reset()
        for index in range(1, len(fixture) + 1):
            output = run([f'/chat pin {index}'])[0]
            assert f'📌 Pinned message {index} ' in output, output
        pinned = messages()
        assert all(m['isPinned'] for m in pinned), pinned
        assert [{k: v for k, v in m.items() if k != 'isPinned'} for m in pinned] == fixture
        short, listing, repeated = run(['/chat log short', '/chat pin', '/chat pin 2'])
        for index, role in enumerate(('System', 'User', 'Assistant', 'Assistant', 'Tool', 'Tool', 'Assistant'), 1):
            assert f'[{index}] 📌 {role}' in short, (index, short)
            assert f'## [{index}] 📌 {role}' in listing, (index, listing)
        assert 'Total messages: 7' in short, short
        assert len(messages()) == len(fixture)

        for action in ('/chat pin 0', '/chat unpin 0', '/chat pin missing', '/chat pin 2 extra'):
            output = run([action])[0]
            assert 'Usage:' in output, (action, output)
            assert messages() == pinned
        output = run(['/chat unpin question'])[0]
        assert 'Unpinned message 2 ' in output, output
        assert not messages()[1].get('isPinned', False)
        output = run(['/chat pin -6'])[0]
        assert '📌 Pinned message 2 ' in output, output

        paragraphs = json.loads(json.dumps(fixture))
        paragraphs[1]['content'][0] = part('text', '\r\nFirst line\r\ncontinued\r\n \r\nSECOND PARAGRAPH')
        reset(paragraphs)
        output = run(['/chat pin 2', '/chat log short'])[1]
        assert '[2] 📌 User: First line continued' in output, output
        assert 'SECOND PARAGRAPH' not in output, output
        run(['/chat log short > short.txt'])
        assert '[2] 📌 User: First line continued' in (root / 'short.txt').read_text()
        run(['/chat clear'])
        assert not any(m.get('isPinned', False) for m in messages())

        reset([])
        for output in run(['/chat log', '/chat log verbose']):
            assert 'No conversation messages yet.' in output, output
        print('PASS chat logs: quiet/verbose/short, first paragraphs, pins on all roles, stable indexes, redirection; '
              'editor aliases, inline text, attachment preservation, persistence and validation')


if __name__ == '__main__':
    main()
