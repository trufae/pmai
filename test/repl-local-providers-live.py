#!/usr/bin/env python3
"""Exercise native inference using isolated pmai settings and a chosen local model."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary')
    parser.add_argument('--provider', required=True, choices=['apple', 'mlx'])
    parser.add_argument('--model')
    parser.add_argument('--cache', default='/tmp/pmai-local-provider-models')
    parser.add_argument('--stream', action='store_true', help='exercise streaming responses')
    parser.add_argument('--default-tools', action='store_true',
                        help='keep the default main instructions and tools to exercise their context cost')
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    model = args.model or ('on-device' if args.provider == 'apple' else 'mlx-community/LFM2-350M-MLX')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('PMAI_', 'MAI_', 'OPENAI_', 'HF_'))}
    environment['HF_HOME'] = str(Path(args.cache).resolve())
    with tempfile.TemporaryDirectory(prefix='pmai-local-live-') as directory:
        root = Path(directory)
        config = root / 'config.json'
        agent = {'id': 'main', 'provider': 'local', 'model': model,
                 'instructions': 'Answer briefly.', 'toolNames': [], 'toolGroupNames': [],
                 'retry': {'attempts': 0}, 'autocompact': {'tokens': 0}}
        if args.default_tools:
            defaults = json.loads(subprocess.check_output([binary, '--print-config'], env=environment))
            main = next(agent for agent in defaults['agents'] if agent['id'] == 'main')
            for key in ('instructions', 'toolNames', 'toolGroupNames', 'useToolProxy'):
                if key in main:
                    agent[key] = main[key]
        config.write_text(json.dumps({
            'defaultAgent': 'main',
            'providers': [{'id': 'local', 'kind': args.provider, 'defaultModel': model}],
            'agents': [agent],
            'memory': {'enabled': False}, 'use': {'agentsmd': 'off', 'plan': False},
        }))
        result = subprocess.run(
            [binary, '--config', str(config), '--home', str(root / 'home'),
             '--no-markdown', *([] if args.stream else ['--no-stream']),
             *([] if args.default_tools else ['--max-tool-calls', '0']),
             *(['Say hello briefly. No tools are needed.'] if args.default_tools else
               ['What is 2 plus 2? Answer with one digit.'])],
            cwd=root, env=environment, text=True, capture_output=True, timeout=300)
        print(result.stdout, end='')
        print(result.stderr, end='')
        assert result.returncode == 0, f'{args.provider} exited {result.returncode}'
        assert 'error:' not in result.stdout + result.stderr
        if args.default_tools:
            assert result.stdout.strip(), 'No greeting returned'
        else:
            assert '4' in result.stdout, result.stdout
        print(f'PASS native {args.provider} inference ({"streaming" if args.stream else "non-streaming"}): {model}')


if __name__ == '__main__':
    main()
