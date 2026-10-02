#!/usr/bin/env python3
"""Regression checks for the complete chat setup and durable subagent tree."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid


def main():
    binary = str(Path(sys.argv[1]).resolve())
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('PMAI_', 'MAI_', 'OPENAI_'))}
    with tempfile.TemporaryDirectory(prefix='pmai-resume-state-') as directory:
        root = Path(directory)
        config = root / 'config.json'
        config.write_text(json.dumps({
            'defaultAgent': 'main',
            'providers': [
                {'id': 'chat', 'kind': 'hello', 'baseURL': 'http://configured.example/v1',
                 'apiKey': 'never-in-the-chat', 'timeout': 73,
                 'headers': {'x-session': '{{session}}'}, 'options': {'custom': True}},
                {'id': 'tasks', 'kind': 'hello', 'baseURL': 'http://tasks.example/v1'},
            ],
            'agents': [
                {'id': 'main', 'provider': 'chat', 'model': 'chat-model',
                 'subagentNames': ['worker']},
                {'id': 'worker', 'provider': 'tasks', 'model': 'worker-model',
                 'instructions': 'Saved worker instructions.', 'subagentNames': ['nested']},
                {'id': 'nested', 'provider': 'tasks', 'model': 'nested-model'},
            ],
            'use': {'plan': False},
        }))

        def run(commands=(), args=(), env=None):
            result = subprocess.run(
                [binary, '--config', str(config), '--home', str(root / 'home'),
                 '--no-markdown', '--no-stream', *args],
                cwd=root, env=environment | (env or {}),
                input='\n'.join([*commands, '/exit', '']),
                capture_output=True, text=True, timeout=30)
            output = result.stdout + result.stderr
            assert result.returncode == 0 and 'error:' not in output, output
            return output

        def chat_file(title):
            return next(path for path in (root / '.pmai/chats').glob('*.json')
                        if json.loads(path.read_text())['title'] == title)

        run(['/chat rename durable', '/model-aproval worker'],
            ['--base-url', 'http://launch.example/v1',
             '--compact-agent', 'tasks::compact-model', '--tool-agent', 'nested'])
        saved_path = chat_file('durable')
        saved = json.loads(saved_path.read_text())
        snapshot = saved['runtimeConfiguration']
        providers = {p['id']: p for p in snapshot['providers']}
        assert providers['chat']['baseURL'] == 'http://launch.example/v1', providers
        assert providers['chat']['timeout'] == 73
        assert providers['chat']['options'] == {'custom': True}
        assert 'never-in-the-chat' not in saved_path.read_text()
        assert snapshot['taskAgents']['tool'] == 'nested'
        assert snapshot['taskAgents']['approval'] == 'worker'
        assert next(p for p in json.loads(config.read_text())['providers']
                    if p['id'] == 'chat')['baseURL'] == 'http://configured.example/v1'
        output = run(['/chat new inherited', '/baseurl'],
                     ['--base-url', 'http://inherited.example/v1'])
        assert "Base URL for 'chat': http://inherited.example/v1" in output, output
        output = run(['/baseurl'], ['-r', 'inherited'])
        assert "Base URL for 'chat': http://inherited.example/v1" in output, output

        # Remove every saved provider/agent from the installation. The saved
        # chat must supply its complete setup, including nested definitions.
        changed = json.loads(config.read_text())
        changed.update(defaultAgent='fresh', taskAgents={},
                       providers=[{'id': 'fresh', 'kind': 'hello'}],
                       agents=[{'id': 'fresh', 'provider': 'fresh', 'model': 'fresh-model'}])
        changed.pop('prompts', None)
        config.write_text(json.dumps(changed))
        run(['/model'])  # Normalize the newly edited global configuration once.
        config_bytes = config.read_bytes()
        output = run(['/model', '/baseurl', '/agent show worker', '/agent show nested'],
                     ['-r', 'durable'], {'PMAI_BASE_URL': 'http://wrong.example/v1'})
        for expected in ('Chat: chat::chat-model', 'tasks::compact-model',
                         'tool: nested', 'approval: worker', 'worker-model', 'nested-model',
                         'http://launch.example/v1', 'http://tasks.example/v1'):
            assert expected in output, (expected, output)
        assert config.read_bytes() == config_bytes, 'resume rewrote global defaults'

        # Chat switching must rebuild providers and task assignments in both directions.
        output = run(['/chat rename fresh-chat', '/chat use durable', '/baseurl', '/model',
                      '/chat use fresh-chat', '/baseurl', '/model'])
        assert "Base URL for 'chat': http://launch.example/v1" in output, output
        assert 'Chat: fresh::fresh-model' in output, output
        assert 'compact: current agent' in output, output
        assert config.read_bytes() == config_bytes

        # A per-launch endpoint override survives another restart.
        run(args=['-r', 'durable', '--base-url', 'http://overridden.example/v1',
                  '--compact-agent', '-', '--tool-agent', 'tasks::new-tools'])
        output = run(['/baseurl', '/model'], ['-r', 'durable'])
        assert "Base URL for 'chat': http://overridden.example/v1" in output, output
        assert 'compact: current agent' in output, output
        assert 'tasks::new-tools' in output, output
        assert config.read_bytes() == config_bytes

        # Restored named prompts must also form a valid editable configuration.
        run(['/model-aproval worker'], ['-r', 'durable'])
        edited = json.loads(config.read_text())
        assert edited['prompts']['system']['worker'] == 'Saved worker instructions.'
        config.write_bytes(config_bytes)

        # Seed more records than the supervisor's ordinary 32-process retention.
        # Children precede their parent in the file, and some were still running.
        run(args=['-r', 'durable', 'A saved conversation.'])
        saved = json.loads(saved_path.read_text())
        parent_id = str(uuid.uuid4()).upper()
        records = []
        for index in range(48):
            record = dict(runID=parent_id if index == 0 else str(uuid.uuid4()).upper(),
                          pid=index + 2, parent=1 if index == 0 else 2,
                          agentID=f'old-worker-{index}', displayName=f'old-worker-{index}',
                          task=f'saved task {index}', state='running' if index % 2 else 'completed',
                          depth=1 if index == 0 else 2,
                          startedAt='2000-01-01T00:00:00Z', updatedAt='2000-01-01T00:00:01Z',
                          modelTurns=2, toolCalls=1, messages=saved['messages'])
            if index:
                record['parentRunID'] = parent_id
            records.append(record)
        saved['subagents'] = list(reversed(records))
        saved_path.write_text(json.dumps(saved))

        # One-shot resume used to leave these records unrestored (still running).
        run(args=['-r', 'durable', 'Continue the saved conversation.'])
        restored = json.loads(saved_path.read_text())['subagents']
        assert len(restored) == 48
        assert all(r['state'] in ('completed', 'cancelled') for r in restored), restored
        by_id = {r['runID']: r for r in restored}
        assert all(r.get('parentRunID') == parent_id for r in restored if r['runID'] != parent_id)
        assert all(r['parent'] == by_id[parent_id]['pid'] for r in restored if r['runID'] != parent_id)
        output = run(['/agents tree', '/agents log 3', '/chat use fresh-chat',
                      '/chat use durable', '/agents tree'], ['-r', 'durable'])
        assert '48 agents from earlier runs' in output, output
        for index in range(48):
            assert f'old-worker-{index}' in output, output
        assert len(json.loads(saved_path.read_text())['subagents']) == 48

        # Clearing while focused elsewhere also clears the visited chat's saved records.
        run(['/chat use fresh-chat', '/agents clear'], ['-r', 'durable'])
        assert json.loads(saved_path.read_text())['subagents'] == []
        output = run(['/agents tree'], ['-r', 'durable'])
        assert 'old-worker-' not in output, output
        print('PASS complete resume: effective URLs, provider settings, task models, removed '
              'definitions, chat switching, one-shot restoration, 48-agent tree, and clearing')


if __name__ == '__main__':
    main()
