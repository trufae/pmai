#!/usr/bin/env python3
"""Check chat settings, launch precedence, and isolation without a model server."""
import json
from smoke import clean_environment, run_repl
from pathlib import Path
import sys
import tempfile


def main():
    binary = str(Path(sys.argv[1]).resolve())
    environment = clean_environment()
    with tempfile.TemporaryDirectory(prefix='pmai-resume-') as directory:
        root = Path(directory)
        config = root / 'pmai.json'
        config.write_text(json.dumps({
            'defaultAgent': 'main',
            'providers': [
                {'id': 'hello', 'kind': 'hello',
                 'baseURL': 'http://saved.example/v1'},
                {'id': 'alternate', 'kind': 'hello'},
            ],
            'agents': [
                {'id': 'main', 'provider': 'hello', 'model': 'original'},
                {'id': 'other', 'provider': 'hello', 'model': 'agent-model',
                 'instructions': 'Agent instructions.'},
            ],
        }))

        def run(commands=(), args=(), env=None):
            return run_repl([binary, '--config', str(config), '--home', str(root / 'home'),
                 '--no-markdown', *args], commands,
                cwd=root, env=environment | (env or {}), timeout=30)

        def chat_file(title):
            return next(path for path in (root / '.pmai/chats').glob('*.json')
                        if json.loads(path.read_text())['title'] == title)

        def assert_restored(path, saved):
            restored = json.loads(path.read_text())
            for key in ('primaryAgent', 'messages', 'sessionID', 'pendingContent'):
                assert restored[key] == saved[key], (key, restored[key], saved[key])

        run(['/chat rename retained', '/model hello::chosen',
             '/set effort high Think carefully.', '/set limits.maxToolCalls 7',
             '/set limits.maxModelTurns 9', '/set limits.maxSubagents 2',
             '/set limits.maxSeconds 10m', '/set retry.attempts 4',
             '/set ctx.compact 64k', '/set ctx.recent 4k', '/set ctx.strategy size',
             '/set tool.calling xml', '/set tool.proxy all'],
            ['--system', 'Saved instructions.'])
        run(args=['-r', 'retained', 'First conversation.'])
        retained_path = chat_file('retained')
        retained = json.loads(retained_path.read_text())
        assert retained['primaryAgent']['model'] == 'chosen', retained
        assert retained['primaryAgent']['limits']['maxToolCalls'] == 7, retained
        assert retained['primaryAgent']['autocompact']['preserveRecentTokens'] == 4000, retained
        assert retained['primaryAgent']['context'] == 'size', retained

        run(['/chat rename latest', '/model alternate::different',
             '/set effort low', '/set limits.maxToolCalls 19',
             '/set limits.maxModelTurns 21', '/set limits.maxSubagents 3',
             '/set ctx.strategy cache', '/set tool.calling native', '/set tool.proxy off'],
            ['--system', 'Other instructions.', '--no-stream'])
        run(args=['-r', 'latest', 'Second conversation.'])
        latest_path = chat_file('latest')
        latest = json.loads(latest_path.read_text())
        # Avoid equal timestamps when the whole test runs within one clock tick.
        retained['updatedAt'] = '2000-01-01T00:00:00Z'
        latest['updatedAt'] = '2001-01-01T00:00:00Z'
        retained_path.write_text(json.dumps(retained))
        latest_path.write_text(json.dumps(latest))
        latest_bytes = latest_path.read_bytes()

        aliases = [
            {'PMAI_PROVIDER': 'alternate', 'PMAI_MODEL': 'env-model',
             'PMAI_BASE_URL': 'http://env.example/v1'},
            {'MAI_PROVIDER': 'alternate', 'MAI_MODEL': 'env-model',
             'MAI_BASE_URL': 'http://env.example/v1'},
            {'OPENAI_MODEL': 'env-model', 'OPENAI_BASE_URL': 'http://env.example/v1'},
        ]
        # Resuming by title, UUID prefix, or list index restores the same snapshot.
        for selector, env in zip(('retained', retained['id'][:8], '1'), aliases):
            output = run(['/model', '/set', '/baseurl'], ['-r', selector], env)
            assert 'Chat: hello::chosen' in output, output
            assert 'limits.maxToolCalls = 7' in output, output
            assert 'ctx.recent = 4000' in output, output
            assert 'ctx.strategy = size\n' in output, output
            assert 'ctx.context' not in output, output
            assert "Base URL for 'hello': http://saved.example/v1" in output, output
            assert 'runtime override' not in output, output
            assert_restored(retained_path, retained)
            assert latest_path.read_bytes() == latest_bytes, 'another chat was rewritten'

        # No selector chooses the most recently used chat with its settings.
        output = run(['/model'], ['-r'], aliases[0])
        assert 'Chat: hello::chosen' in output, output
        assert_restored(retained_path, retained)

        # A fresh launch uses saved defaults without changing saved chats.
        output = run(['/model', '/baseurl'], env=aliases[0])
        assert 'Chat: alternate::different' in output, output
        assert "Base URL for 'alternate': http://env.example/v1" in output, output
        assert_restored(retained_path, retained)
        assert latest_path.read_bytes() == latest_bytes

        # Switching away and back must not copy the shared agent defaults either.
        output = run(['/chat use retained', '/model', '/chat next', '/chat previous',
                      '/chat use latest', '/model'], env=aliases[0])
        assert 'Chat: hello::chosen' in output, output
        assert 'Chat: alternate::different' in output, output
        assert_restored(retained_path, retained)
        assert_restored(latest_path, latest)

        original_config = config.read_bytes()
        latest_bytes = latest_path.read_bytes()
        output = run(['/baseurl'], ['-r', 'retained', '--base-url', 'http://flag.example/v1'],
                     aliases[0])
        assert "Base URL for 'hello': http://flag.example/v1" in output, output
        run(args=['-r', 'retained', '--model', 'alternate::flag-model', '--effort', 'off',
                  '--max-tool-calls', '0', '--max-turns', '3', '--max-subagents', '0',
                  '--no-stream', '--system', 'Explicit instructions.'], env=aliases[0])
        overridden = json.loads(retained_path.read_text())
        agent = overridden['primaryAgent']
        assert (agent['provider'], agent['model']) == ('alternate', 'flag-model'), agent
        assert agent['options']['reasoningEffort'] == 'disabled', agent
        assert agent['limits']['maxToolCalls'] == 0, agent
        assert agent['limits']['maxModelTurns'] == 3, agent
        assert agent['limits']['maxSubagents'] == 0, agent
        assert agent['stream'] is False, agent
        assert agent['instructions'] == 'Explicit instructions.', agent
        assert 'Explicit instructions.' in json.dumps(overridden['messages']), overridden
        assert 'Saved instructions.' not in json.dumps(overridden['messages']), overridden
        assert latest_path.read_bytes() == latest_bytes
        assert config.read_bytes() == original_config, 'CLI overrides changed shared defaults'
        run(args=['-r', 'retained'], env=aliases[0])
        assert_restored(retained_path, overridden)

        # Explicit provider and agent choices still work, without environment model leakage.
        run(args=['-r', 'retained', '--provider', 'hello'], env=aliases[0])
        agent = json.loads(retained_path.read_text())['primaryAgent']
        assert (agent['provider'], agent['model']) == ('hello', 'flag-model'), agent
        run(args=['-r', 'retained', '--agent', 'other'], env=aliases[0])
        agent = json.loads(retained_path.read_text())['primaryAgent']
        assert (agent['id'], agent['provider'], agent['model']) == ('other', 'hello', 'agent-model')

        # One-shot resumes use the restored settings too.
        run(args=['-r', 'retained', 'A follow-up message.'], env=aliases[0])
        continued = json.loads(retained_path.read_text())
        assert continued['primaryAgent'] == agent, continued
        assert 'A follow-up message.' in json.dumps(continued['messages']), continued

        # With no saved chat, -r falls back to the usual new-chat defaults.
        output = run(['/model'], ['-r', '--state', str(root / 'empty')], aliases[0])
        assert 'Chat: alternate::different' in output, output

        # Saving defaults on resume persists the restored profile, not the startup defaults.
        run(args=['-r', 'retained', '--effort', 'high', '--save-defaults'], env=aliases[0])
        saved_config = json.loads(config.read_text())
        assert saved_config['defaultAgent'] == 'other', saved_config
        saved_agent = next(a for a in saved_config['agents'] if a['id'] == 'other')
        assert (saved_agent['provider'], saved_agent['model']) == ('hello', 'agent-model')
        assert saved_agent['options']['reasoningEffort'] == 'high', saved_agent
        print('PASS resume: saved settings, environment aliases, chat isolation, switching, '
              'explicit flags, endpoints, saved defaults, one-shot continuation, and empty-store fallback')


if __name__ == '__main__':
    main()
