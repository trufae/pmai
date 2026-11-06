#!/usr/bin/env python3
"""Check document exports and PocketMai conversation import with the offline provider."""
import json
import shlex
from smoke import clean_environment, run_repl
from pathlib import Path
import sys
import tempfile
import uuid


def main():
    binary = str(Path(sys.argv[1]).resolve())
    environment = clean_environment()
    with tempfile.TemporaryDirectory(prefix='pmai-export-') as directory:
        root = Path(directory)
        config = root / 'config.json'
        config.write_text(json.dumps({
            'defaultAgent': 'hello',
            'providers': [{'id': 'hello', 'kind': 'hello'}],
            'agents': [{'id': 'hello', 'provider': 'hello', 'model': ''}],
        }))

        def run(commands=(), args=(), allow_errors=False):
            return run_repl([binary, '--config', str(config), '--home', str(root / 'home'),
                 '--no-markdown', *args], commands,
                cwd=root, env=environment, timeout=30, allow_errors=allow_errors)

        run(args=['Question'])
        path = next((root / '.pmai/chats').glob('*.json'))
        chat = json.loads(path.read_text())

        def message(role, kind, text):
            return {'id': str(uuid.uuid4()), 'role': role,
                    'content': [{kind: {'_0': text}}]}

        chat['messages'] = [
            message('user', 'text', 'Question'),
            message('assistant', 'reasoning', 'Private thought'),
            message('tool', 'text', 'Tool result'),
            message('assistant', 'text', '**Answer**: café 🙂'),
        ]
        path.write_text(json.dumps(chat))
        output = run(['/set export.', '/help export', '/export md clean.md',
                      '/export txt foo.txt', '/export txt', '/export txt copies/',
                      '/export json full.json', '/set ctx.strategy tools',
                      '/export debug debug.json', '/set export.tools on',
                      '/export md tools.md', '/export txt tools.txt', '/set export.thinking on',
                      '/export md both.md', '/export txt both.txt'], args=['-r', chat['id']])
        assert 'export.tools = off' in output, output
        assert 'export.thinking = off' in output, output
        assert '/set export.thinking on' in output, output
        assert '/export txt [PATH]' in output, output
        assert 'Exported Plain Text' in output, output
        for filename, tools, thinking in [('clean.md', False, False),
                                           ('foo.txt', False, False),
                                           ('tools.md', True, False),
                                           ('tools.txt', True, False),
                                           ('both.md', True, True),
                                           ('both.txt', True, True)]:
            text = (root / filename).read_text()
            assert 'Answer' in text, text
            assert ('Tool result' in text) == tools, text
            assert ('Private thought' in text) == thinking, text
        text = (root / 'foo.txt').read_text()
        assert 'You:\n\nQuestion' in text and 'Assistant:\n\nAnswer: café 🙂' in text, text
        assert '**' not in text, text
        default_text = next((root / 'copies').glob('*.txt'))
        assert default_text.read_text() == text
        assert (root / default_text.name).read_text() == text
        assert json.loads((root / 'full.json').read_text())['chat']['messages'] == chat['messages']
        settings = json.loads((root / 'debug.json').read_text())['debug']['settings']
        assert settings['ctx.strategy'] == 'tools', settings
        assert 'ctx.context' not in settings, settings
        assert json.loads(config.read_text())['documentExport'] == {
            'includeToolCalls': True, 'includeThinking': True}

        output = run(['/set export.', '/export md restored.md', '/set export.tools off',
                      '/export md thinking.md', '/set export.thinking off'], args=['-r', chat['id']])
        assert 'export.tools = on' in output and 'export.thinking = on' in output, output
        assert (root / 'restored.md').read_text() == (root / 'both.md').read_text()
        thinking = (root / 'thinking.md').read_text()
        assert 'Private thought' in thinking and 'Tool result' not in thinking, thinking

        # PocketMai's Share Conversation uses the existing JSON envelope with
        # a registered extension. /import must inspect its contents, not suffix.
        run(['/export archive portable.json'], args=['-r', chat['id']])
        portable = json.loads((root / 'portable.json').read_text())
        portable.pop('settings', None)
        portable.pop('skills', None)
        envelope = {
            'format': 'pocketmai.conversation', 'title': 'Shared chat',
            'model': '', 'provider': 'apple', 'pocketMaiVersion': 'test',
            'exportedAt': portable['exportedAt'], 'createdAt': chat['createdAt'],
            'conversation': {
                'id': chat['id'], 'title': 'Shared chat', 'provider': 'apple',
                'modelID': '', 'createdAt': chat['createdAt'], 'updatedAt': chat['updatedAt'],
                'messages': [{'id': str(uuid.uuid4()), 'role': 'user', 'text': 'Legacy question'}],
            },
            'portable': portable,
        }
        before_config = config.read_text()
        before_count = len(list((root / '.pmai/chats').glob('*.json')))
        for extension in ['pocketmai', 'pocketmai.json']:
            filename = f'Shared Chat.{extension}'
            (root / filename).write_text(json.dumps(envelope))
            output = run([f'/import {filename}', '/export json imported.json'])
            assert 'Imported 1 chat' in output, output
            imported = json.loads((root / 'imported.json').read_text())['chat']
            assert imported['messages'] == portable['chats'][0]['messages'], imported
            assert imported['id'] != chat['id'], imported
        assert config.read_text() == before_config
        assert len(list((root / '.pmai/chats').glob('*.json'))) == before_count + 2

        # Context reductions must survive restart without destroying exportable evidence.
        evidence = 'EXACT HISTORICAL EVIDENCE\n' * 40
        chat['messages'] = [
            message('user', 'text', 'Read old.txt'),
            message('assistant', 'toolCall', {'id': 'read-old', 'name': 'files_read',
                                             'arguments': {'path': 'old.txt'}}),
            message('tool', 'toolResult', {'callID': 'read-old', 'isError': False,
                                         'content': [{'text': {'_0': evidence}}]}),
            message('assistant', 'text', 'Read complete'),
        ]
        path.write_text(json.dumps(chat))
        resume = ['-r', chat['id']]
        run(['/set ctx.strategy size', 'New question', '/export json retained.json',
             '/export --context json context.json'], args=resume)
        retained = json.loads((root / 'retained.json').read_text())['chat']
        context = json.loads((root / 'context.json').read_text())['chat']
        assert evidence in retained['messages'][2]['content'][0]['toolResult']['_0']['content'][0]['text']['_0']
        assert 'EXACT HISTORICAL EVIDENCE' not in json.dumps(context)
        run(['/export json reopened.json', '/chat context reset',
             '/export --context json empty-context.json', '/chat context rebuild',
             '/export --context json rebuilt.json'], args=resume)
        assert json.loads((root / 'reopened.json').read_text())['chat']['messages'] == retained['messages']
        empty = json.loads((root / 'empty-context.json').read_text())['chat']['messages']
        assert all(m['role'] in ('system', 'developer') for m in empty)
        assert 'EXACT HISTORICAL EVIDENCE' in (root / 'rebuilt.json').read_text()

        editor = root / 'editor.py'
        editor.write_text('from pathlib import Path\nimport sys\np = Path(sys.argv[1])\n'
                          'p.write_text(p.read_text().replace("New question", "Edited question"))\n')
        environment['EDITOR'] = shlex.join([sys.executable, str(editor)])
        run(['/chat edit', '/export json edited-history.json',
             '/export --context json edited-context.json'], args=resume)
        assert 'Edited question' in (root / 'edited-context.json').read_text()
        edited = json.loads((root / 'edited-history.json').read_text())['chat']['messages']
        assert any(m['content'] == [{'text': {'_0': 'New question'}}] for m in edited)
        editor.write_text('from pathlib import Path\nimport sys\nPath(sys.argv[1]).write_text("broken document")\n')
        output = run(['/edit chat', '/export json after-invalid.json'], args=resume, allow_errors=True)
        assert 'No conversation changes were saved' in output, output
        assert json.loads((root / 'after-invalid.json').read_text())['chat']['messages'] == edited
    print('REPL document export smoke passed')


if __name__ == '__main__':
    main()
