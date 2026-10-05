#!/usr/bin/env python3
"""Check persistent REPL defaults from a clean home without provider variables."""
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
    with tempfile.TemporaryDirectory(prefix='pmai-defaults-') as directory:
        root = Path(directory)
        user_home = root / 'user'
        user_home.mkdir()
        project = root / 'project'
        project.mkdir()
        config = user_home / '.config/pmai/config.json'
        key_file = root / 'key'
        key_file.write_text('saved-key\n')

        def run(commands=(), args=(), env=None, cwd=project, home=user_home):
            result = subprocess.run(
                [binary, '--no-stream', '--no-markdown', *args],
                cwd=cwd, env=environment | {'HOME': str(home)} | (env or {}),
                input='\n'.join([*commands, '/exit', '']),
                capture_output=True, text=True, timeout=30)
            output = result.stdout + result.stderr
            assert result.returncode == 0 and 'error:' not in output, output
            return output

        run([f'/provider add local http://127.0.0.1:11434/v1 --api-key-file {key_file}',
             '/provider use local', '/model org/saved:latest', '/set effort low',
             '/set tool.calling xml'])
        saved = json.loads(config.read_text())
        provider = next(p for p in saved['providers'] if p['id'] == 'local')
        assert provider['apiKeyFile'] == str(key_file), provider
        run(['/model'])  # Normalize the newly created task agents' named prompts.
        original = config.read_bytes()
        for env in ({}, {'PMAI_PROVIDER': 'hello', 'PMAI_MODEL': 'stale'},
                    {'MAI_PROVIDER': 'hello', 'MAI_MODEL': 'hello::stale'},
                    {'OPENAI_MODEL': 'missing::stale'}):
            output = run(['/model', '/provider', '/baseurl', '/set'], env=env)
            assert 'Chat: local::org/saved:latest' in output, output
            assert 'Current provider: local' in output, output
            assert "Base URL for 'local': http://127.0.0.1:11434/v1" in output, output
            assert 'effort = low' in output, output
            assert 'tool.calling = xml' in output, output
            assert config.read_bytes() == original, 'reading defaults rewrote them'

        # The default user config applies when opening a different project too.
        other_project = root / 'other-project'
        other_project.mkdir()
        assert 'Chat: local::org/saved:latest' in run(['/model'], cwd=other_project)

        # Explicit launch flags remain temporary for an existing configuration.
        output = run(['/model'], args=['--model', 'hello::temporary'])
        assert 'Chat: hello::temporary' in output, output
        assert config.read_bytes() == original, 'temporary flags changed defaults'
        assert 'Chat: local::org/saved:latest' in run(['/model'])

        # Selecting a model on another agent makes that saved choice the next default.
        run(['/agent add secondary', '/agent use secondary', '/model hello::secondary-model'])
        assert json.loads(config.read_text())['defaultAgent'] == 'secondary'
        assert 'Chat: hello::secondary-model' in run(['/model'])
        run(['/agent default main', '/agent use secondary', '/model-chat hello::chat-model'])
        assert json.loads(config.read_text())['defaultAgent'] == 'secondary'
        assert 'Chat: hello::chat-model' in run(['/model-chat'])

        # Provider selection on another agent has the same persistence rule.
        run(['/agent default main', '/agent use secondary', '/provider use local'])
        assert json.loads(config.read_text())['defaultAgent'] == 'secondary'
        output = run(['/model', '/provider'])
        assert 'Chat: local::chat-model' in output, output
        assert 'Current provider: local' in output, output

        # Environment defaults can still bootstrap an installation once.
        bootstrap_home = root / 'bootstrap-user'
        bootstrap_home.mkdir()
        run(['/model'], env={'PMAI_PROVIDER': 'bootstrap',
                            'PMAI_MODEL': 'bootstrap::initial',
                            'PMAI_BASE_URL': 'http://127.0.0.1:9000/v1'},
            home=bootstrap_home)
        output = run(['/model', '/baseurl'], home=bootstrap_home)
        assert 'Chat: bootstrap::initial' in output, output
        assert "Base URL for 'bootstrap': http://127.0.0.1:9000/v1" in output, output
        print('PASS persistent defaults: clean setup, model/provider/settings, environment '
              'precedence, new projects, temporary flags, active agent, and bootstrap')


if __name__ == '__main__':
    main()
