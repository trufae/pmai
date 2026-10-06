#!/usr/bin/env python3
"""Check document export defaults and saved opt-ins with the offline provider."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid


def main():
    binary = str(Path(sys.argv[1]).resolve())
    environment = {k: v for k, v in os.environ.items()
                   if not k.startswith(('PMAI_', 'MAI_', 'OPENAI_'))}
    with tempfile.TemporaryDirectory(prefix='pmai-export-') as directory:
        root = Path(directory)
        config = root / 'config.json'
        config.write_text(json.dumps({
            'defaultAgent': 'hello',
            'providers': [{'id': 'hello', 'kind': 'hello'}],
            'agents': [{'id': 'hello', 'provider': 'hello', 'model': ''}],
        }))

        def run(commands=(), args=()):
            result = subprocess.run(
                [binary, '--config', str(config), '--home', str(root / 'home'),
                 '--no-markdown', *args], cwd=root, env=environment,
                input='\n'.join([*commands, '/exit', '']), capture_output=True,
                text=True, timeout=30)
            output = result.stdout + result.stderr
            assert result.returncode == 0, output
            assert 'error:' not in output, output
            return output

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
            message('assistant', 'text', 'Answer'),
        ]
        path.write_text(json.dumps(chat))
        output = run(['/set export.', '/help export', '/export md clean.md',
                      '/export json full.json', '/set ctx.strategy tools',
                      '/export debug debug.json', '/set export.tools on',
                      '/export md tools.md', '/set export.thinking on',
                      '/export md both.md'], args=['-r', chat['id']])
        assert 'export.tools = off' in output, output
        assert 'export.thinking = off' in output, output
        assert '/set export.thinking on' in output, output
        for filename, tools, thinking in [('clean.md', False, False),
                                           ('tools.md', True, False),
                                           ('both.md', True, True)]:
            text = (root / filename).read_text()
            assert 'Answer' in text, text
            assert ('Tool result' in text) == tools, text
            assert ('Private thought' in text) == thinking, text
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
    print('REPL document export smoke passed')


if __name__ == '__main__':
    main()
