#!/usr/bin/env python3
"""Check indexes from either end in messages, saved chats, projects, and todos."""
import copy
import json
import re
from pathlib import Path
import subprocess
import sys
import tempfile

from smoke import clean_environment, read_chat, run_repl


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix='pmai-indexes-') as directory:
        root = Path(directory).resolve()
        current, middle, oldest = [root / name for name in ('current', 'middle', 'oldest')]
        for path in (current, middle, oldest):
            path.mkdir()
        home = root / 'home'
        config = root / 'config.json'
        config.write_text(json.dumps({
            'defaultAgent': 'hello', 'providers': [{'id': 'hello', 'kind': 'hello'}],
            'agents': [{'id': 'hello', 'provider': 'hello', 'model': 'hello'}],
            'memory': {'enabled': False}, 'use': {'plan': False},
        }))
        env = clean_environment()
        command = [binary, '--config', str(config), '--home', str(home),
                   '--no-markdown', '--no-stream']
        for path in (oldest, middle, current):
            run_repl(command, ['Seed'], cwd=path, env=env)
        saved = next((current / '.pmai/chats').glob('*.json'))
        template = read_chat(saved)
        saved.unlink()
        fixture = [
            {'id': identifier, 'role': role, 'content': [{'text': {'_0': text}}]}
            for identifier, role, text in [('first', 'user', 'First'),
                                           ('second', 'assistant', 'Second'),
                                           ('last', 'user', 'Last')]
        ]
        chats = []
        for index, title in enumerate(('Newest', 'Middle', 'Oldest', 'Archived')):
            chat = copy.deepcopy(template)
            prefix = ('aaaaaaaa', 'bbbbbbbb', 'cccccccc', 'dddddddd')[index]
            chat.update(id=f'{prefix}-0000-4000-8000-000000000001', title=title,
                        messages=fixture, isArchived=index == 3,
                        createdAt=f'200{5 if index == 3 else 4 - index}-01-01T00:00:00Z',
                        updatedAt=f'201{index}-01-01T00:00:00Z')
            chats.append(chat)
        saved = saved.parent / (chats[0]['id'].upper() + '.json')

        def reset():
            for chat in chats:
                (saved.parent / (chat['id'].upper() + '.json')).write_text(json.dumps(chat))

        def run(commands, args=('-r', 'Newest'), allow_errors=False, split=True):
            output = run_repl(command + list(args), commands, cwd=current, env=env,
                              split=split, allow_errors=allow_errors)
            return [part.split('pmai> ', 1)[-1] for part in output] if split else output

        def messages():
            return read_chat(saved)['messages']

        # The same ordering governs info, switching, launch-time resume, and archiving.
        for selector, title in [('-1', 'Archived'), ('-2', 'Newest'), ('-4', 'Oldest'),
                                ('1', 'Oldest'), ('4', 'Archived')]:
            reset()
            info, switched = run(['/chat info ' + selector, '/chat use ' + selector])
            assert f'Title:    {title}' in info, info
            expected = f"Already in '{title}'" if title == 'Newest' else f"Switched to '{title}'"
            assert expected in switched, switched
            reset()
            output = run(['/chat info'], args=('-r', selector))[0]
            assert f'Title:    {title}' in output, output
        for alias in ('--resume', '--continue'):
            reset()
            output = run(['/chat info'], args=(alias, '-1', '--no-markdown'))[0]
            assert 'Title:    Archived' in output, output
        reset()
        archived, info = run(['/chat archive 1', '/chat info Oldest'])
        assert "Archived 'Oldest'." in archived, archived
        assert 'Status:   archived' in info, info
        reset()
        restored, info = run(['/chat unarchive -1', '/chat info Archived'])
        assert "Restored 'Archived'" in restored, restored
        assert 'Status:   active' in info, info
        reset()
        deleted, listing, moved = run(['/chat del 1', '/chat list', '/chat close confirm'])
        assert "Deleted 'Oldest'." in deleted, deleted
        assert 'Oldest' not in listing and 'Middle' in listing, listing
        assert '/chat del' in moved, moved
        assert not (saved.parent / (chats[2]['id'].upper() + '.json')).exists()
        assert messages() == fixture
        reset()
        deleted = run(['/chat del Newest', '/chat info'])
        assert "Deleted 'Newest'; switched to" in deleted[0], deleted
        assert not saved.exists()
        reset()
        listing = run(['/chat list'])[0]
        assert listing.index('Oldest') < listing.index('Middle') < listing.index('Newest'), listing
        assert listing.index('2002') < listing.index('2003') < listing.index('2004'), listing
        assert re.findall(r'^\*?\s+(\d+)\s+[A-Fa-f0-9]{8}', listing, re.M) == ['1', '2', '3', '4'], listing
        pinned, listing, info = run(['/chat pin', '/chat list', '/chat info'])
        assert "📌 Pinned 'Newest'." in pinned, pinned
        assert listing.startswith('Pinned\n') and '📌 Newest' in listing, listing
        assert listing.count('Newest') == 1 and listing.index('Newest') < listing.index('Oldest'), listing
        assert 'Index:    3' in info and 'Status:   active, pinned, current' in info, info
        assert read_chat(saved)['isPinned'] is True
        # Pin state survives reload and unrelated saves; selectors retain creation order.
        info, switched, pinned, listing = run([
            '/chat info', '/chat use 1', '/chat pin bbbbbbbb', '/chat list active'])
        assert 'active, pinned, current' in info, info
        assert "Switched to 'Oldest'" in switched, switched
        assert "Pinned 'Middle'" in pinned, pinned
        assert listing.index('Middle') < listing.index('Newest') < listing.index('Oldest'), listing
        assert listing.count('Pinned\n') == 1 and 'Archived' not in listing, listing
        assert read_chat(saved)['isPinned'] is True
        unpinned, info, listing = run(['/chat unpin -2', '/chat info 3', '/chat list'])
        assert "Unpinned 'Newest'" in unpinned, unpinned
        assert 'Index:    3' in info and 'pinned' not in info, info
        assert '📌 Newest' not in listing and listing.index('Oldest') < listing.index('Newest'), listing
        reset()
        output = run(['/chat use 1', '/chat next', '/chat previous'])
        assert "Switched to 'Middle'" in output[1] and "Switched to 'Oldest'" in output[2], output
        # Bulk deletion uses the original indexes, removes duplicate selectors once,
        # and switches only after every target has been removed.
        reset()
        deleted, info = run(['/chat del 1 2 cccccccc -2', '/chat info'])
        assert deleted.count("Deleted 'Oldest'") == 1, deleted
        assert "Deleted 'Middle'" in deleted and "Deleted 'Newest'; switched to 'Archived'" in deleted, deleted
        assert 'Title:    Archived' in info, info
        assert len(list(saved.parent.glob('*.json'))) == 1
        reset()
        deleted, info = run(['/chat del 1 2 3 4', '/chat info'])
        assert 'started a new chat' in deleted and 'Title:    New chat' in info, (deleted, info)
        assert not list(saved.parent.glob('*.json'))
        reset()
        output = run(['/chat del 1 missing-chat'])[0]
        assert 'Usage: /chat del' in output and len(list(saved.parent.glob('*.json'))) == 4, output
        reset()
        output = run(['/chat rename Title with spaces', '/chat del Title with spaces'])
        assert "Deleted 'Title with spaces'" in output[1], output
        for selector in ('0', '-5', '5', '-9223372036854775808', '9223372036854775807'):
            reset()
            output = run(['/chat use ' + selector])[0]
            assert 'Usage: /chat use' in output, (selector, output)
            result = subprocess.run(command + ['-r', selector], cwd=current, env=env,
                                    input='/exit\n', capture_output=True, text=True, timeout=30)
            assert result.returncode != 0, (selector, result.stdout, result.stderr)

        reset()
        outputs = run(['/msg pin -1', '/msg unpin -1', '/msg pin -2'])
        for output, expected in zip(outputs, ('Pinned message 3', 'Unpinned message 3', 'Pinned message 2')):
            assert expected in output, output
        assert [message.get('isPinned', False) for message in messages()] == [False, True, False]
        for action, expected in [('/msg del -1', ['first', 'second']),
                                 ('/msg undo -2', ['first', 'last']),
                                 ('/msg trim -2', ['first', 'second'])]:
            reset()
            run([action])
            assert [message['id'] for message in messages()] == expected, (action, messages())
        reset()
        run(['/msg edit -2 Replacement'])
        assert messages()[1]['content'] == [{'text': {'_0': 'Replacement'}}]
        for selector in ('0', '-4', '-9223372036854775808'):
            reset()
            assert 'Usage: /msg pin' in run(['/msg pin ' + selector])[0]
            assert messages() == fixture

        # Startup opens the current project first, so the remaining projects keep
        # this fixed order. Every command sees its current displayed list order.
        index_path = home / 'projects.json'
        project_index = json.loads(index_path.read_text())

        def reset_projects():
            for project in project_index['projects']:
                year = {current: 2003, middle: 2002, oldest: 2001}[Path(project['workingDirectory']).resolve()]
                project['lastOpenedAt'] = f'{year}-01-01T00:00:00Z'
            index_path.write_text(json.dumps(project_index))

        for selector, name in [('-1', 'oldest'), ('-2', 'middle'), ('-3', 'current'), ('2', 'middle')]:
            reset_projects()
            info = run(['/projects info ' + selector])[0]
            assert f'Name:      {name}' in info, info
            reset_projects()
            opened = run(['/projects open ' + selector])[0]
            assert (f"Opened project '{name}'" if name != 'current' else "Already in 'current'") in opened, opened
        for selector in ('-4', '-9223372036854775808', '9223372036854775807'):
            reset_projects()
            output = run(['/projects info ' + selector], allow_errors=True, split=False)
            assert 'Usage: /projects info' in output, output
        reset_projects()
        run(['/projects rename -1 Renamed', '/projects tint -1 mint'])
        updated = json.loads(index_path.read_text())['projects']
        target = next(project for project in updated if Path(project['workingDirectory']).resolve() == oldest)
        assert target['name'] == 'Renamed' and target['tint'] == 'mint', target
        reset_projects()
        run(['/project del -1'])
        assert len(json.loads(index_path.read_text())['projects']) == 2
        assert oldest.is_dir() and (oldest / '.pmai/chats').is_dir()

        reset_projects()
        run(['/projects del -2'])
        assert len(json.loads(index_path.read_text())['projects']) == 2
        assert middle.is_dir()

        run(['/todo add First', '/todo add Second', '/todo add Last', '/todo done -1', '/todo del -2'])
        assert (current / '.pmai/todo.md').read_text() == '- [ ] First\n- [x] Last\n'
        print('Negative message, chat, resume, project, and todo indexes: passed')


if __name__ == '__main__':
    main()
