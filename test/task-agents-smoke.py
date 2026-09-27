#!/usr/bin/env python3
"""Exercise saved task assignments and CLI-only overrides without a model server."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    binary = str(Path(sys.argv[1]).resolve())
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('PMAI_', 'MAI_', 'OPENAI_'))}
    with tempfile.TemporaryDirectory(prefix='pmai-task-agents-') as directory:
        root = Path(directory)
        config = root / 'pmai.json'
        config.write_text(json.dumps({
            'defaultAgent': 'main',
            'providers': [{'id': 'hello', 'kind': 'hello'}],
            'agents': [{'id': 'main', 'provider': 'hello', 'model': 'original'}],
        }))

        def run(commands=(), args=()):
            result = subprocess.run(
                [binary, '--config', str(config), '--home', str(root / 'home'),
                 '--no-stream', '--no-markdown', *args],
                cwd=root, env=environment, input='\n'.join([*commands, '/exit', '']),
                capture_output=True, text=True, timeout=30)
            output = result.stdout + result.stderr
            assert result.returncode == 0, output
            assert 'error:' not in output, output
            return output

        run(['/provider add local http://127.0.0.1:11434/v1',
             '/agent add cheap', '/agent model cheap local::org/small:latest',
             '/agent effort cheap low', '/agent tools cheap -',
             '/model -compact cheap', '/model -tool cheap', '/agent default main'])
        saved = json.loads(config.read_text())
        assert saved['taskAgents'] == {'compact': 'cheap', 'tool': 'cheap'}, saved
        cheap = next(agent for agent in saved['agents'] if agent['id'] == 'cheap')
        assert cheap['model'] == 'org/small:latest' and cheap['provider'] == 'local'
        assert cheap['options']['reasoningEffort'] == 'low'
        assert 'compact: cheap' in run(['/model'])
        assert 'tool: cheap' in run(['/model'])
        original = config.read_bytes()
        run(['/model'], ['--compact-agent', '-', '--tool-agent', '-', '--effort', 'off'])
        assert config.read_bytes() == original, 'temporary overrides persisted'
        run(['/model'], ['--model', 'hello::saved', '--effort', 'medium',
                         '--compact-agent', '-', '--save-defaults'])
        saved = json.loads(config.read_text())
        assert saved['taskAgents'] == {'tool': 'cheap'}, saved['taskAgents']
        main_agent = next(agent for agent in saved['agents'] if agent['id'] == 'main')
        assert main_agent['model'] == 'saved'
        assert main_agent['options']['reasoningEffort'] == 'medium'
        run(['/model -tool', '/model -compact local::new:4b'])
        saved = json.loads(config.read_text())
        assert 'tool' not in saved['taskAgents']
        compact_id = saved['taskAgents']['compact']
        run([f'/agent remove {compact_id}'])
        assert json.loads(config.read_text())['taskAgents'] == {}
        run(['/model'], ['--provider', 'another', '--base-url', 'http://localhost:9000/v1',
                         '--model', 'other', '--save-defaults'])
        saved = json.loads(config.read_text())
        assert any(p['id'] == 'another' and p['baseURL'] == 'http://localhost:9000/v1'
                   for p in saved['providers'])
        assert 'Chat: another::other' in run(['/model'])
        print('PASS task agents: creation, model/effort, restart, reset, deletion, temporary and saved overrides')


if __name__ == '__main__':
    main()
