#!/usr/bin/env python3
"""Check local-provider discovery, URL-free setup, selection, and persistence."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    binary = str(Path(sys.argv[1]).resolve())
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('PMAI_', 'MAI_', 'OPENAI_', 'HF_'))}
    with tempfile.TemporaryDirectory(prefix='pmai-local-providers-') as directory:
        root = Path(directory)
        config = root / 'config.json'
        config.write_text(json.dumps({
            'defaultAgent': 'main',
            'providers': [{'id': 'hello', 'kind': 'hello'}],
            'agents': [{'id': 'main', 'provider': 'hello', 'model': 'hello'}],
            'memory': {'enabled': False},
        }))

        def run(commands, args=(), env=None, allow_errors=False, config_path=config):
            config_args = ['--config', str(config_path)] if config_path is not None else []
            result = subprocess.run(
                [binary, *config_args, '--home', str(root / 'home'),
                 '--no-markdown', '--no-stream', *args],
                cwd=root, env=environment | {'HF_HOME': str(root / 'hf')} | (env or {}),
                input='\n'.join([*commands, '/exit', '']), text=True,
                capture_output=True, timeout=30)
            output = result.stdout + result.stderr
            assert result.returncode == 0, output
            if not allow_errors:
                assert 'error:' not in output, output
            return output

        output = run(['/providers', '/help provider'])
        assert '--kind apple' in output and '--kind mlx' in output, output
        if sys.platform == 'darwin':
            assert 'apple — Apple Intelligence' in output, output
            assert 'mlx — MLX Local' in output, output
            output = run(['/provider use apple', '/model-chat'])
            assert 'Chat: apple::on-device' in output, output
            output = run(['/provider', '/model-chat'], env={'OPENAI_BASE_URL': 'not-a-url'})
            assert 'Current provider: apple' in output, output
            assert 'Chat: apple::on-device' in output, output
            output = run(['/provider use mlx', '/model-chat', '/models mlx'], allow_errors=True)
            assert 'Chat: mlx::LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit' in output, output
            assert 'Unknown provider' not in output, output
            for provider, model in (('apple', 'on-device'),
                                    ('mlx', 'LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit')):
                output = run(
                    ['/provider', '/model-chat'], args=['--provider', provider],
                    config_path=None,
                    env={'HOME': str(root / f'fresh-{provider}'),
                         'OPENAI_BASE_URL': 'not-a-url',
                         'PMAI_API_KEY_FILE': str(root / 'missing-remote-key')})
                assert f'Chat: {provider}::{model}' in output, output

        run(['/provider add personal-apple --kind apple',
             '/provider add personal-mlx --kind mlx --model mlx-community/LFM2-350M-MLX',
             '/provider use personal-mlx'])
        saved = json.loads(config.read_text())
        providers = {provider['id']: provider for provider in saved['providers']}
        assert providers['personal-apple']['kind'] == 'apple', providers
        assert providers['personal-apple']['defaultModel'] == 'on-device', providers
        assert providers['personal-mlx']['kind'] == 'mlx', providers
        assert providers['personal-mlx']['defaultModel'] == 'mlx-community/LFM2-350M-MLX', providers
        assert all(not providers[name].get('baseURL') for name in ('personal-apple', 'personal-mlx'))
        output = run(['/provider', '/model-chat'], env={'OPENAI_BASE_URL': 'not-a-url'})
        assert 'Current provider: personal-mlx' in output, output
        assert 'Chat: personal-mlx::mlx-community/LFM2-350M-MLX' in output, output

        before = json.loads(config.read_text())['providers']
        output = run(['/provider add broken --kind mlx http://127.0.0.1:1/v1',
                      '/provider add missing', '/provider add malformed --kind'])
        assert 'Usage: /provider add' in output, output
        assert json.loads(config.read_text())['providers'] == before
        output = run(['/provider rename personal-mlx renamed-mlx', '/provider', '/model-chat'])
        assert 'Current provider: renamed-mlx' in output, output
        assert 'Chat: renamed-mlx::mlx-community/LFM2-350M-MLX' in output, output
        assert 'Current provider: renamed-mlx' in run(['/provider'], args=['--resume'])
        assert not (root / 'hf').exists(), 'discovery or setup downloaded model data'
    print('PASS local providers: discovery, URL-free setup, defaults, credentials isolation, rename, and resume')


if __name__ == '__main__':
    main()
