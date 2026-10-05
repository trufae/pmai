#!/usr/bin/env python3
"""Test skills using a real model; isolate all writes and retain request logs.

python3 test/repl-skills-live.py MaiCore/.build/debug/pmai \
  --upstream http://192.168.1.60:8000/v1 --model ornith --results /tmp/skills
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
from http.server import ThreadingHTTPServer

sys.path.insert(0, str(Path(__file__).resolve().parent / 'bench'))
import proxy

BODY = '''Produce a checked stamp in the current workspace:
1. Read input.txt from the workspace using files_read.
2. Read references/format.txt from this skill's directory using files_read.
3. Write result.txt in the workspace using files_write. Its exact contents must be
   the value of the prefix key from format.txt, then a colon, then the trimmed input.txt contents,
   then a colon, then the value of the suffix key from format.txt, then one newline.
4. Read result.txt back using files_read and check its contents before answering.
5. Answer with exactly STAMP SAVED (no other text).
Use the tools to perform the steps; describing the steps does not complete them.
Do not ask for more information: all required information is in these files.
'''


def run_case(args, root, port, mode, invocation, protocol):
    root.mkdir(parents=True)
    skill = root / '.pmai/skills/checked-stamp'
    (skill / 'references').mkdir(parents=True)
    body = BODY
    if args.long_skill:
        body += '\nReference notes:\n' + '\n'.join(
            f'{i}. Stamp verification must preserve the exact source values and separators.'
            for i in range(1, 101))
    (skill / 'SKILL.md').write_text(
        '---\nname: checked-stamp\ndescription: Produce a checked stamp from input.txt. '
        'Call this skill to load the required format and verification steps.\n---\n' + body)
    (skill / 'references/format.txt').write_text('{"prefix":"VIOLET-29","suffix":"END-73"}\n')
    (root / 'input.txt').write_text('payload-418\n')
    config = root / 'config.json'
    config.write_text(json.dumps({
        'defaultAgent': 'main',
        'providers': [{'id': 'local', 'kind': 'openAICompatible',
                       'baseURL': f'http://127.0.0.1:{port}/v1'}],
        'toolSources': [{'id': 'standard', 'kind': 'standard-tools'}],
        'agents': [{'id': 'main', 'provider': 'local', 'model': args.model,
                    'instructions': 'Complete the user task using available tools. '
                    'When a skill matches the task, call its tool to get its instructions '
                    'and follow them. Respect the required final answer format.',
                    'toolNames': ['files_read', 'files_write'], 'toolGroupNames': ['skills'],
                    'context': mode, 'toolCallingStrategy': protocol,
                    'retry': {'attempts': 0},
                    'autocompact': {'tokens': args.compact_tokens, 'preservingRecentTokens': 0},
                    'limits': {'maxModelTurns': 12, 'maxToolCalls': 16, 'maxSeconds': 180},
                    'options': {'temperature': 0, 'maxOutputTokens': 2500}}],
        'memory': {'enabled': False}, 'use': {'plan': False, 'agentsmd': False},
    }))
    prompts = {
        'auto': 'Produce a checked stamp from input.txt.',
        'tool': 'Call skills_checked-stamp and follow its instructions to produce a checked stamp from input.txt.',
        'dollar': '$checked-stamp Produce a checked stamp from input.txt.',
        'prompt': '/skills prompt checked-stamp Produce a checked stamp from input.txt.',
    }
    env = {k: v for k, v in os.environ.items() if not k.startswith(('PMAI_', 'MAI_', 'OPENAI_'))
           and k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy')}
    env.update(NO_PROXY='127.0.0.1,localhost', PWD=str(root))
    proxy.LOG = str(root / 'proxy.jsonl')
    completed = subprocess.run(
        [str(Path(args.binary).resolve()), '--config', str(config), '--home', str(root / 'home'),
         '--no-stream', '--no-markdown'], cwd=root, env=env,
        input=prompts[invocation] + '\n/exit\n', text=True, capture_output=True, timeout=200)
    (root / 'stdout.txt').write_text(completed.stdout)
    (root / 'stderr.txt').write_text(completed.stderr)
    records = [json.loads(line) for line in (root / 'proxy.jsonl').read_text().splitlines()]
    requests = [r for r in records if r.get('request')]
    primary = [r for r in requests if r['request'].get('tools') or
               any('skills_checked-stamp' in str(m.get('content'))
                   for m in r['request']['messages'] if m['role'] == 'system')]
    chat_file = next((root / '.pmai/chats').glob('*.json'))
    chat = json.loads(chat_file.read_text())
    calls = [p['toolCall']['_0'] for m in chat['messages'] for p in m['content'] if 'toolCall' in p]
    answered = any(p.get('text', {}).get('_0', '').strip() == 'STAMP SAVED'
                   for m in chat['messages'] if m['role'] == 'assistant' for p in m['content'])
    written = (root / 'result.txt').read_text() if (root / 'result.txt').exists() else None
    def has_whole_skill(record):
        return any(body.strip() in str(m.get('content', '')) for m in record['request']['messages'])
    summary = {'mode': mode, 'invocation': invocation, 'protocol': protocol,
               'loaded': invocation in ('dollar', 'prompt') or any(c['name'] == 'skills_checked-stamp' for c in calls),
               'written': written == 'VIOLET-29:payload-418:END-73\n', 'answered': answered,
               'verified': any(c['name'] == 'files_read' and c['arguments'].get('path') == 'result.txt' for c in calls),
               'whole_skill_requests': sum(has_whole_skill(r) for r in primary),
               'primary_requests': len(primary), 'model_requests': len(requests),
               'tools': [c['name'] for c in calls],
               'http_errors': [r['error'] for r in records if r.get('error')],
               'returncode': completed.returncode}
    summary['passed'] = all(summary[k] for k in ('loaded', 'written', 'answered', 'verified')) and not summary['http_errors']
    (root / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary), flush=True)
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary')
    parser.add_argument('--upstream', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--results', required=True, type=Path)
    parser.add_argument('--modes', nargs='+', default=['cache', 'size', 'smart', 'tools'])
    parser.add_argument('--invocations', nargs='+', default=['auto', 'tool', 'dollar', 'prompt'])
    parser.add_argument('--protocols', nargs='+', default=['native'])
    parser.add_argument('--long-skill', action='store_true')
    parser.add_argument('--compact-tokens', type=int, default=0)
    args = parser.parse_args()
    proxy.UPSTREAM = args.upstream.rstrip('/')
    server = ThreadingHTTPServer(('127.0.0.1', 0), proxy.Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    summaries = []
    try:
        for mode in args.modes:
            for protocol in args.protocols:
                for invocation in args.invocations:
                    summaries.append(run_case(args, args.results.resolve() / f'{mode}-{protocol}-{invocation}',
                                              server.server_port, mode, invocation, protocol))
                    if summaries[-1]['http_errors']:
                        (args.results / 'summary.json').write_text(json.dumps(summaries, indent=2) + '\n')
                        sys.exit('Live verification stopped because the provider failed; see the saved logs.')
        (args.results / 'summary.json').write_text(json.dumps(summaries, indent=2) + '\n')
    finally:
        server.shutdown()
        server.server_close()
    sys.exit(0 if all(s['passed'] for s in summaries) else 1)
