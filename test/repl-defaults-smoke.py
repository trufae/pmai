#!/usr/bin/env python3
"""Check persistent REPL defaults from a clean home without provider variables."""
import json
import re
from pathlib import Path
import subprocess
import sys
import tempfile
from smoke import clean_environment, run_repl


def main():
    binary = str(Path(sys.argv[1]).resolve())
    environment = clean_environment()
    with tempfile.TemporaryDirectory(prefix='pmai-defaults-') as directory:
        root = Path(directory)
        user_home = root / 'user'
        user_home.mkdir()
        project = root / 'project'
        project.mkdir()
        config = user_home / '.config/pmai/config.json'
        key_file = root / 'key'
        key_file.write_text('saved-key\n')

        def run(commands=(), args=(), env=None, cwd=project, home=user_home, split=False):
            return run_repl(
                [binary, '--no-stream', '--no-markdown', *args],
                commands, cwd=cwd, env=environment | {'HOME': str(home)} | (env or {}),
                split=split)

        # Empty installs remain empty across restarts; /about repeats the welcome.
        output = run(['/providers', '/provider', '/model', '/help'])
        assert 'Welcome to PocketMai!' in output, output
        assert r'\___________/' in output, output
        assert '/provider add myai https://api.example.com/v1 --api-key YOUR_API_KEY' in output
        assert 'No providers configured.' in output, output
        assert 'No provider selected.' in output, output
        assert 'Chat: no model selected' in output, output
        assert '/about' in output, output
        saved = json.loads(config.read_text())
        assert saved['providers'] == [] and saved['agents'] == [], saved
        original = config.read_bytes()
        welcome, about = run(['/providers', '/about'], split=True)
        assert 'Welcome to PocketMai!' in welcome and 'Welcome to PocketMai!' in about
        assert config.read_bytes() == original, 'welcome created providers or agents'
        output = run(['hello before setup'])
        assert 'No provider selected. Type /about' in output, output
        assert config.read_bytes() == original, 'an unconfigured prompt changed settings'
        result = subprocess.run(
            [binary, '--no-stream', '--no-markdown', 'hello before setup'],
            cwd=project, env=environment | {'HOME': str(user_home)},
            capture_output=True, text=True, timeout=30)
        assert result.returncode != 0 and 'type /about' in result.stderr, result.stderr
        assert config.read_bytes() == original, 'an unconfigured one-shot changed settings'

        # The welcome's API-key setup and a default model survive a restart.
        output = run(['/provider add myai https://api.example.com/v1 '
                      '--api-key setup-key --model setup-model', '/provider use myai'])
        assert 'setup-key' not in output, output
        provider = json.loads(config.read_text())['providers'][0]
        assert provider['id'] == 'myai' and provider['apiKey'] == 'setup-key', provider
        assert provider['defaultModel'] == 'setup-model', provider
        output = run(['/provider', '/model'])
        assert 'Current provider: myai' in output and 'Chat: myai::setup-model' in output, output
        assert 'Welcome to PocketMai!' not in output, output
        original = config.read_bytes()
        about, help_about = run(['/about', '/help about'], split=True)
        assert 'Welcome to PocketMai!' in about and 'Welcome to PocketMai!' in help_about
        assert config.read_bytes() == original, '/about changed settings'
        output = run([f'/provider add conflict https://api.example.com/v1 '
                      f'--api-key setup-key --api-key-file {key_file}'])
        assert 'Usage: /provider add' in output, output
        assert config.read_bytes() == original, 'conflicting credential flags changed settings'

        run(['/provider add hello http://127.0.0.1:11434/v1 --kind hello',
             f'/provider add local http://127.0.0.1:11434/v1 --api-key-file {key_file}',
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

        # Singular and plural aliases share all definition commands.
        run(['/agents effort secondary medium',
             '/agent describe secondary A smaller model for routine work.',
             '/agent disable main', '/agents enable main'])
        definitions = {a['id']: a for a in json.loads(config.read_text())['agents']}
        assert definitions['secondary']['options']['reasoningEffort'] == 'medium', definitions
        assert definitions['secondary']['description'] == 'A smaller model for routine work.'
        assert definitions['main'].get('enabled', True)
        for listing in run(('/agents', '/agent', '/agents list', '/agent list'), split=True):
            assert 'secondary —' in listing and 'main —' in listing, listing
            assert 'Jobs:' not in listing and 'Total:' not in listing, listing
        for help_text in run(('/help agents', '/help agent'), split=True):
            assert '/jobs manages the processes' in help_text, help_text
            assert '/help jobs explains process control' in help_text, help_text
        for help_text in run(('/help jobs', '/help job', '/help /jobs', '/help /job'), split=True):
            assert 'Job commands (/job is an alias)' in help_text, help_text
            assert '/jobs stop PID' in help_text and 'requests cancellation' in help_text
        usage = (
                ('/jobs unknown', 'Job commands'), ('/jobs log', 'Usage: /jobs log PID'),
                ('/job stop bad', 'Usage: /jobs stop PID'),
                ('/jobs continue', 'Usage: /jobs continue PID'),
                ('/jobs kill', 'Usage: /jobs kill PID'),
                ('/jobs tree extra', 'Usage: /jobs [tree]'),
                ('/jobs clear extra', 'Usage: /jobs clear'))
        for (command, expected), output in zip(usage, run([c for c, _ in usage], split=True)):
            assert expected in output, (command, expected, output)

        # The removed /skill alias must neither run a command nor invoke a prompt.
        for output in run(('/skill', '/skill prompt missing input.txt'), split=True):
            assert 'Unknown command. Type /help.' in output, output
        unknown, commands, help_text = run(('/help skill', '/help', '/help skills'), split=True)
        assert "Unknown help topic 'skill'" in unknown, unknown
        names = re.findall(r'(?m)^(/[a-z]+)\b', commands)
        assert len(names) > 20 and names == sorted(names), names
        assert '/stop' in names and '/retry' not in names, names
        assert '/skills prompt NAME [TEXT]' in help_text, help_text

        # Environment defaults can still bootstrap an installation once.
        bootstrap_home = root / 'bootstrap-user'
        bootstrap_home.mkdir()
        assert 'No providers configured.' in run(['/providers'], home=bootstrap_home)
        run(['/model'], env={'PMAI_PROVIDER': 'bootstrap',
                            'PMAI_MODEL': 'bootstrap::initial',
                            'PMAI_BASE_URL': 'http://127.0.0.1:9000/v1'},
            home=bootstrap_home)
        output = run(['/model', '/baseurl'], home=bootstrap_home)
        assert 'Chat: bootstrap::initial' in output, output
        assert "Base URL for 'bootstrap': http://127.0.0.1:9000/v1" in output, output
        bootstrap_config = bootstrap_home / '.config/pmai/config.json'
        assert [p['id'] for p in json.loads(bootstrap_config.read_text())['providers']] == ['bootstrap']

        # Opening the config editor on a fresh install also starts empty.
        editor_home = root / 'editor-user'
        editor_home.mkdir()
        result = subprocess.run(
            [binary, '-E'], cwd=project,
            env=environment | {'HOME': str(editor_home),
                               'EDITOR': 'cmd /c exit 0' if sys.platform == 'win32' else 'true'},
            capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stdout + result.stderr
        edited = json.loads((editor_home / '.config/pmai/config.json').read_text())
        assert edited['providers'] == [] and edited['agents'] == [], edited
        print('PASS persistent defaults: clean setup, model/provider/settings, environment '
              'precedence, new projects, temporary flags, active agent, and bootstrap')


if __name__ == '__main__':
    main()
