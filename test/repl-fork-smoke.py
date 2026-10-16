#!/usr/bin/env python3
"""Check chat forks, switching, and independent continuation without a model server."""
import json
from pathlib import Path
import sys
import tempfile
from smoke import clean_environment, run_repl


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix='pmai-fork-') as directory:
        root = Path(directory).resolve()
        config = root / 'config.json'
        config.write_text(json.dumps({
            'defaultAgent': 'main',
            'providers': [{'id': 'hello', 'kind': 'hello',
                           'baseURL': 'http://saved.example/v1'}],
            'agents': [{'id': 'main', 'provider': 'hello', 'model': 'saved-model',
                        'instructions': 'Saved instructions.'}],
            'use': {'plan': False},
        }))
        environment = dict(clean_environment(), PWD=str(root))

        def run(commands=(), args=(), split=False):
            return run_repl(
                [binary, '--config', str(config), '--home', str(root / 'home'),
                 '--no-markdown', '--no-stream', *args], commands,
                cwd=root, env=environment, split=split)

        def chat_file(title):
            return next(path for path in (root / '.pmai/chats').glob('*.json')
                        if json.loads(path.read_text())['title'] == title)

        def chat(title):
            return json.loads(chat_file(title).read_text())

        run(['/chat rename Original', 'Shared history.'])
        notes = root / 'notes.txt'
        notes.write_text('Pending notes for either branch.')
        run([f'/attach {notes}'], ['-r', 'Original'])
        original = chat('Original')
        assert original['pendingContent'], original

        def assert_original_unchanged():
            # Resuming updates the last-used time even without editing a chat.
            current = chat('Original')
            assert current == original | {'updatedAt': current['updatedAt']}, current

        output = run(['/chat fork', '/chat info'], ['-r', 'Original'])
        assert "Forked 'Original' into 'Original (fork)' and switched to it." in output, output
        fork = chat('Original (fork)')
        assert fork['id'] != original['id'] and fork['sessionID'] != original['sessionID']
        assert fork['createdAt'] == fork['updatedAt']
        for key in ('primaryAgent', 'messages', 'pendingContent', 'runtimeConfiguration'):
            assert fork[key] == original[key], (key, fork, original)
        assert_original_unchanged()

        # The command switches immediately: edits and messages belong to the copy.
        output = run(['/chat fork Alternative branch', '/chat edit 2 Changed only here.',
                      'Continue the fork.', '/chat use Original', '/chat log'],
                     ['-r', 'Original'], split=True)
        assert 'Changed only here.' not in output[-1], output[-1]
        assert 'Continue the fork.' not in output[-1], output[-1]
        branch = chat('Alternative branch')
        assert 'Continue the fork.' in json.dumps(branch['messages'])
        assert not branch['pendingContent'], branch
        assert_original_unchanged()
        branch_bytes = chat_file('Alternative branch').read_bytes()
        run(['Continue the original.'], ['-r', 'Original'])
        assert chat_file('Alternative branch').read_bytes() == branch_bytes
        assert 'Continue the original.' not in json.dumps(branch['messages'])

        # Archived originals stay archived; their forks can continue as active chats.
        run(['/chat archive'], ['-r', 'Original'])
        archived = chat('Original')
        run(['/chat fork From archive'], ['-r', 'Original'])
        assert chat('Original')['isArchived']
        assert not chat('From archive')['isArchived']
        assert chat('From archive')['messages'] == archived['messages']

        # An empty fork is explicitly kept and can be resumed.
        run(['/chat fork'])
        empty = chat('New chat (fork)')
        run(['/chat info'], ['-r', empty['id']])
        assert chat('New chat (fork)')['id'] == empty['id']
        assert '/chat fork [TITLE]' in run(['/help chat'])
        print('PASS forks: full snapshots, fresh identities, immediate switching, '
              'independent edits and continuation, archived and empty chats, and resume')


if __name__ == '__main__':
    main()
