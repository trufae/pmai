#!/usr/bin/env python3
"""Exercise mixed native/MCP/skill policy and learned exposure through the CLI."""
import json
import re
from smoke import JSONProvider, clean_environment, run_repl
from pathlib import Path
import sys
import tempfile
import threading
from http.server import ThreadingHTTPServer


requests = []
answers = []


class Provider(JSONProvider):
    def do_GET(self):
        self.respond({'data': [{'id': 'main'}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(request)
        message = answers.pop(0)
        self.respond({'choices': [{'message': message,
            'finish_reason': 'tool_calls' if message.get('tool_calls') else 'stop'}]})


def call(name, arguments):
    return {'role': 'assistant', 'content': '', 'tool_calls': [{
        'id': 'test-call', 'type': 'function',
        'function': {'name': name, 'arguments': json.dumps(arguments)}}]}


def message_text(message):
    content = message.get('content') or ''
    return content if isinstance(content, str) else ''.join(part.get('text', '') for part in content)


def main():
    binary = str(Path(sys.argv[1]).resolve())
    env = clean_environment()
    env.update(NO_PROXY='127.0.0.1,localhost', NO_COLOR='1')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-tool-policy-') as directory:
            root = Path(directory)
            for name in ('alpha', 'beta'):
                folder = root / '.pmai/skills' / name
                folder.mkdir(parents=True)
                (folder / 'SKILL.md').write_text(
                    f'---\nname: {name}\ndescription: Review {name}\n---\nRead the code.\n')
            mcp = root / 'mcp.py'
            mcp.write_text('''import json, sys
for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    method = request["method"]
    if method == "initialize":
        result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}},
                  "serverInfo": {"name": "fixture", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": [{"name": name, "description": "Test " + name,
                            "inputSchema": {"type": "object", "properties": {}}}
                           for name in ("search", "read")]}
    elif method == "resources/list":
        result = {"resources": []}
    elif method == "tools/call":
        result = {"content": [{"type": "text", "text": "MCP ran"}]}
    else:
        result = {}
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
''')
            config = root / 'config.json'
            config.write_text(json.dumps({
                'providers': [{'id': 'local', 'kind': 'openAICompatible',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                'toolSources': [{'id': 'standard', 'kind': 'standard-tools'}],
                'mcpServers': [{'id': 'fixture', 'command': sys.executable, 'args': [str(mcp)],
                                'toolNamePrefix': 'external', 'defaultApproval': 'automatic'}],
                'agents': [{'id': 'main', 'provider': 'local', 'model': 'main',
                            'instructions': 'Rules', 'toolGroupNames': ['files', 'github', 'skills'],
                            'autocompact': {'tokens': 0}}],
                'memory': {'enabled': False}, 'use': {'plan': False},
                'approvals': {'mode': 'yolo'},
            }))
            final = {'role': 'assistant', 'content': 'DONE'}

            def run(commands, responses):
                requests.clear()
                answers[:] = responses
                output = run_repl([binary, '--config', str(config), '--home', str(root / 'home'),
                    '--no-stream', '--no-markdown'], commands,
                    cwd=root, env=dict(env, PWD=str(root)), timeout=40)
                assert not answers, answers
                return output, list(requests)

            def agent_settings():
                agents = json.loads(config.read_text())['agents']
                for agent in agents:
                    # Swift Sets do not have a stable JSON array order.
                    for key in ('toolNames', 'toolGroupNames', 'subagentNames'):
                        agent[key] = sorted(agent.get(key, []))
                return agents

            # Startup expands tool groups and saves decoded defaults before any command.
            run([], [])
            assert json.loads(config.read_text()).get('defaultAgent') is None
            before = agent_settings()
            for command in ('/tools', '/tools list'):
                output, _ = run([command], [])
                assert re.search(r'^files\s+● enabled\s+', output, re.MULTILINE), output
                assert re.search(r'\bGroup\s+Status\s+Direct\s+Proxy\s+Hidden\s+Disabled\s+Calls\s+Description',
                                 output, re.MULTILINE), output
                assert ' direct,' not in output, output
                assert 'mcp/fixture ' in output, output
                assert 'files_read' not in output and 'external::search' not in output, output
                assert '/tools show GROUP' in output and '/tools full' in output, output
            output, _ = run(['/tools full'], [])
            assert 'files_read' in output and 'external::search' in output, output
            output, _ = run(['/set ui.tableborders', '/set ui.tableborders on', '/tools'], [])
            assert 'ui.tableborders = off' in output, output
            assert re.search(r'[│|] Group\s+[│|] Status', output), output
            assert json.loads(config.read_text())['ui']['tableborders'] is True
            output, _ = run(['/set ui.tableborders', '/set ui.tableborders invalid'], [])
            assert 'ui.tableborders = on' in output, output
            assert 'Usage: /set ui.tableborders <on|off>' in output, output
            output, _ = run(['/set ui.tableborders off', '/tools'], [])
            assert re.search(r'\bGroup\s+Status', output), output
            assert json.loads(config.read_text())['ui']['tableborders'] is False
            output, _ = run(['/set'], [])
            keys = re.findall(r'^([\w.]+) = ', output, re.MULTILINE)
            assert len(keys) > 30 and len(keys) == len(set(keys)), keys
            assert keys == sorted(keys, key=str.lower), keys

            output, calls = run(['/set tool.calling off', '/set tool.calling',
                                 'Chat without tool calling'], [final])
            assert 'tool.calling = off' in output, output
            assert not calls[0].get('tools'), calls[0]
            assert json.loads(config.read_text())['agents'][0]['toolCallingStrategy'] == 'off'
            output, calls = run(['Tool calling remains off after restart'], [
                call('files_write', {'path': str(root / 'unexpected'), 'content': 'bad'})])
            assert not calls[0].get('tools') and len(calls) == 1, calls
            assert not (root / 'unexpected').exists()
            output, calls = run(['/set tool.calling automatic', 'Tool calling restored'], [final])
            assert calls[0].get('tools'), calls[0]
            assert agent_settings() == before, 'off/on changed other agent settings'

            output, calls = run(['/tools off', '/tools', 'Chat without tools'], [final])
            assert 'All tools globally: off' in output, output
            assert re.search(r'^github\s+○ disabled\s+', output, re.MULTILINE), output
            assert not calls[0].get('tools'), calls[0]
            assert json.loads(config.read_text())['toolsEnabled'] is False
            assert agent_settings() == before, 'global off changed individual settings'
            output, calls = run(['Still off after restart'], [final])
            assert not calls[0].get('tools'), calls[0]
            output, calls = run(['/tools on', 'Tools restored'], [final])
            assert calls[0].get('tools'), calls[0]
            assert agent_settings() == before, 'global on changed individual settings'
            assert json.loads(config.read_text())['toolsEnabled'] is True

            output, calls = run([
                '/tools proxy github', '/tools direct github/pr', '/tools direct github/issue',
                '/tools disable github/ci_log', '/mcp direct fixture/search',
                '/skills disable beta', '/tools show github', 'Show capabilities',
            ], [final])
            assert 'github_pr [● direct] 0 calls' in output, output
            assert 'github_ci_log [○ disabled] 0 calls' in output, output
            offered = {t['function']['name'] for t in calls[0]['tools']}
            assert {'files_read', 'github_pr', 'github_issue', 'external_search',
                    'list_tools', 'call_tool'} <= offered, offered
            assert not {'github_ci_log', 'skills_beta', 'skills_alpha', 'external::read'} & offered
            catalog = next(t['function']['description'] for t in calls[0]['tools']
                           if t['function']['name'] == 'list_tools')
            assert 'external::read' in catalog and 'skills_alpha' in catalog, catalog
            assert 'github_ci_log' not in catalog and 'skills_beta' not in catalog, catalog

            for _ in range(3):
                output, calls = run(['Load alpha'], [
                    call('call_tool', {'name': 'skills_alpha', 'arguments': {}}), final])
            offered = {t['function']['name'] for t in calls[-1]['tools']}
            assert 'skills_alpha' in offered, offered
            usage = json.loads((root / 'home/tool-usage.json').read_text())
            assert usage['counts'] == {'skills_alpha': 3}, usage

            # New members inherit the group without restoring a disabled member.
            folder = root / '.pmai/skills/gamma'
            folder.mkdir()
            (folder / 'SKILL.md').write_text('---\nname: gamma\ndescription: Review gamma\n---\nReview.\n')
            output, calls = run(['/skills', '/tools show skills', 'After restart'], [final])
            assert 'skills_alpha [● direct] 3 calls' in output, output
            assert 'skills_beta [○ disabled] 0 calls' in output, output
            assert 'skills_gamma [● proxy] 0 calls' in output, output
            assert 'alpha (enabled) [project; 3 calls]\n  Review alpha' in output, output
            assert 'beta (disabled) [project; 0 calls]\n  Review beta' in output, output
            assert 'gamma (proxied) [project; 0 calls]\n  Review gamma' in output, output

            # Automatic choice is reversible and cannot undo a manual proxy pin.
            output, calls = run(['/skills proxy alpha', 'Pinned'], [final])
            assert 'skills_alpha' not in {t['function']['name'] for t in calls[0]['tools']}
            output, calls = run(['/skills inherit alpha', '/set tool.auto off', 'Auto off'], [final])
            assert 'skills_alpha' not in {t['function']['name'] for t in calls[0]['tools']}
            assert json.loads(config.read_text())['agents'][0]['toolPolicy']['automatic'] is False
            output, calls = run(['/set tool.auto on', 'Auto on'], [final])
            assert 'skills_alpha' in {t['function']['name'] for t in calls[0]['tools']}

            output, calls = run(['/tools disable mcp/fixture', '/mcp proxy fixture/search',
                                 '/mcp tools fixture', 'Restricted MCP'], [final])
            catalog = next(t['function']['description'] for t in calls[0]['tools']
                           if t['function']['name'] == 'list_tools')
            assert 'external::read' not in catalog and 'external::search' in catalog, catalog
            output, calls = run(['/tools disable mcp', '/tools inherit mcp/fixture',
                                 '/tools inherit external::search', '/tools enable mcp/fixture',
                                 '/mcp list', '/tools show agent_start', 'MCP enabled'], [final])
            catalog = next(t['function']['description'] for t in calls[0]['tools']
                           if t['function']['name'] == 'list_tools')
            assert 'external::read' in catalog and 'external::search' in catalog, catalog
            assert '0 calls' in output and 'agent_start [' in output, output
            saved = json.loads(config.read_text())['agents'][0]
            assert saved['useToolProxy'] is True
            assert saved['toolPolicy']['groups']['mcp/fixture'] == 'proxy', saved
            assert 'external::search' not in saved['toolPolicy']['tools'], saved

            # Hide removes tools from model discovery while keeping known-name calls available.
            output, calls = run(['/tools hide github/issue', '/skills hide alpha',
                                 '/mcp hide fixture', '/tools show github/issue', '/skills',
                                 'Hidden tools'], [final])
            assert 'github_issue [◐ hidden] 0 calls' in output, output
            assert 'alpha (hidden)' in output, output
            offered = {t['function']['name'] for t in calls[0]['tools']}
            assert not {'github_issue', 'skills_alpha', 'external_search', 'external_read'} & offered
            catalog = next(t['function']['description'] for t in calls[0]['tools']
                           if t['function']['name'] == 'list_tools')
            assert not any(name + ' (' in catalog for name in
                           ('github_issue', 'skills_alpha', 'external::search', 'external::read')), catalog
            saved = json.loads(config.read_text())['agents'][0]['toolPolicy']
            assert saved['tools']['github_issue'] == 'hidden', saved
            assert saved['tools']['skills_alpha'] == 'hidden', saved
            assert saved['groups']['mcp/fixture'] == 'hidden', saved
            output, calls = run(['Find hidden tools'], [
                call('list_tools', {'keywords': 'github_issue skills_alpha external'}), final])
            listings = [m['content'] for m in calls[-1]['messages'] if m['role'] == 'tool']
            assert listings and not any(name in '\n'.join(listings) for name in
                ('- github_issue:', '- skills_alpha:', '- external::search:', '- external::read:')), listings
            output, calls = run(['Call hidden skill'], [
                call('call_tool', {'name': 'skills_alpha', 'arguments': {}}), final])
            assert any('Read the code.' in m['content'] for m in calls[-1]['messages']
                       if m['role'] == 'system'), calls[-1]
            assert any('Skill instructions loaded by skills_alpha' in m['content']
                       for m in calls[-1]['messages'] if m['role'] == 'tool'), calls[-1]
            assert 'skills_alpha' not in {t['function']['name'] for t in calls[-1]['tools']}
            output, calls = run(['Call hidden MCP tool'], [call('external_search', {}), final])
            assert any('MCP ran' in m['content'] for m in calls[-1]['messages']
                       if m['role'] == 'tool'), calls[-1]
            output, calls = run(['/tools direct github/issue', '/skills inherit alpha',
                                 '/mcp proxy fixture', 'Restored'], [final])
            assert 'github_issue' in {t['function']['name'] for t in calls[0]['tools']}

            # Airplane mode is global and reversible; proxy/direct pins cannot bypass it.
            profile_before = agent_settings()
            output, calls = run(['/set airplane on', '/tools show github', 'Offline tools'], [final])
            assert 'airplane = on ✈' in output, output
            assert 'github_pr [○ disabled] 0 calls' in output, output
            offered = {t['function']['name'] for t in calls[0]['tools']}
            assert 'files_read' in offered, offered
            assert not any(name.startswith(('github_', 'weather', 'web_', 'mastodon')) for name in offered), offered
            catalog = next(t['function']['description'] for t in calls[0]['tools'] if t['function']['name'] == 'list_tools')
            assert not any(name in catalog for name in ('github_pr', 'weather', 'web_search', 'mastodon')), catalog
            assert 'external::read' in catalog, catalog
            assert json.loads(config.read_text())['airplane'] is True
            assert agent_settings() == profile_before, (profile_before, agent_settings())
            output, calls = run(['/set airplane', 'Offline after restart'], [final])
            assert 'airplane = on ✈' in output, output
            assert not any(t['function']['name'].startswith('github_') for t in calls[0]['tools']), calls[0]
            output, calls = run(['/set airplane toggle', 'Online again'], [final])
            assert 'airplane = off' in output, output
            assert 'github_pr' in {t['function']['name'] for t in calls[0]['tools']}, calls[0]
            assert json.loads(config.read_text())['airplane'] is False

            # Planning must inspect files and save its handoff without exposing
            # commands, writes, skills, delegation, or inherited MCP tools.
            fixture = root / 'planning.txt'
            fixture.write_text('Keep this project content.\n')
            output, calls = run(['Discuss the planning context', '/agent use plan',
                                 'Inspect the planning fixture'], [
                {'role': 'assistant', 'content': 'Initial goal: keep the file format.'},
                call('files_read', {'path': str(fixture)}), final])
            assert any('Keep this project content.' in message_text(m)
                       for m in calls[-1]['messages'] if m['role'] == 'tool'), calls[-1]
            assert any("Mai's planning agent" in message_text(m)
                       for m in calls[-1]['messages'] if m['role'] == 'system'), calls[-1]
            assert any('Initial goal: keep the file format.' in message_text(m)
                       for m in calls[-1]['messages'] if m['role'] == 'assistant'), calls[-1]
            planning = next(a for a in json.loads(config.read_text())['agents'] if a['id'] == 'plan')
            expected = {'files_list', 'files_find', 'files_grep', 'files_read',
                        'files_read_index', 'files_get_function', 'files_read_range',
                        'todo_list', 'todo_add'}
            assert set(planning['toolNames']) == expected, planning
            assert planning['toolPolicy']['localOnly'] is True
            assert planning['toolPolicy']['groups']['mcp'] == 'disabled'
            assert planning['provider'] == 'local' and planning['model'] == 'main'

            forbidden = [
                ('files_write', {'path': str(fixture), 'content': 'changed'}),
                ('run_shell', {'command': 'touch should-not-exist'}),
                ('agent_start', {'agent': 'main', 'task': 'Modify the fixture'}),
                ('external_search', {}), ('skills_alpha', {}),
                ('todo_done', {'task': '1'}),
            ]
            for name, arguments in forbidden:
                # Direct and proxy calls must both enforce the allowlist.
                for tool_call in [call(name, arguments),
                                  call('call_tool', {'name': name, 'arguments': arguments})]:
                    _, calls = run(['/agent use plan', f'Attempt {name}'], [tool_call, final])
                    results = [message_text(m) for m in calls[-1]['messages'] if m['role'] == 'tool']
                    assert results and any('Error:' in text for text in results), (name, results)
            assert fixture.read_text() == 'Keep this project content.\n'
            assert not (root / 'should-not-exist').exists()

            output, calls = run(['/agent use plan', 'Save the agreed plan',
                                 '/agent use main', '/tools enable todo', 'Implement the agreed plan'], [
                call('call_tool', {'name': 'todo_add', 'arguments': {'title':
                     'Use the existing parser; verify invalid input is rejected'}}),
                {'role': 'assistant', 'content': 'AGREED PLAN: preserve the existing file format.'},
                call('todo_list', {}), final])
            assert 'Conversation preserved for planning and implementation.' in output, output
            assert any('AGREED PLAN: preserve the existing file format.' in message_text(m)
                       for m in calls[-1]['messages'] if m['role'] == 'assistant'), calls[-1]
            assert any('Use the existing parser; verify invalid input is rejected' in message_text(m)
                       for m in calls[-1]['messages'] if m['role'] == 'tool'), calls[-1]
            assert any(message_text(m).startswith('Rules') for m in calls[-1]['messages']
                       if m['role'] == 'system'), calls[-1]
            assert not any("Mai's planning agent" in message_text(m) for m in calls[-1]['messages']
                           if m['role'] == 'system'), calls[-1]

            # User edits, disabling, and deletion survive startup installation.
            run(['/agent model plan custom-model', '/agent describe plan My planner',
                 '/agent disable plan'], [])
            customized = json.loads(config.read_text())
            customized['prompts']['system']['plan'] = 'Ask about constraints before planning.'
            config.write_text(json.dumps(customized))
            run([], [])
            planning = next(a for a in json.loads(config.read_text())['agents'] if a['id'] == 'plan')
            assert planning['model'] == 'custom-model' and planning['description'] == 'My planner'
            assert planning['enabled'] is False
            assert planning['instructions'] == 'Ask about constraints before planning.'
            run(['/agent del plan'], [])
            run([], [])
            assert not any(a['id'] == 'plan' for a in json.loads(config.read_text())['agents'])
    finally:
        server.shutdown()
        server.server_close()
    print('tool policy CLI smoke passed')


if __name__ == '__main__':
    main()
