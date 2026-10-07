#!/usr/bin/env python3
"""Exercise saved task assignments and CLI-only overrides without a model server."""
import json
from smoke import clean_environment, run_repl
from pathlib import Path
import sys
import tempfile


def main():
    binary = str(Path(sys.argv[1]).resolve())
    environment = clean_environment()
    with tempfile.TemporaryDirectory(prefix='pmai-task-agents-') as directory:
        root = Path(directory)
        config = root / 'pmai.json'
        config.write_text(json.dumps({
            'defaultAgent': 'main',
            'providers': [{'id': 'hello', 'kind': 'hello'}],
            'agents': [{'id': 'main', 'provider': 'hello', 'model': 'original'}],
        }))

        def run(commands=(), args=()):
            return run_repl([binary, '--config', str(config), '--home', str(root / 'home'),
                 '--no-stream', '--no-markdown', *args], commands,
                cwd=root, env=environment, timeout=30)

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

        run(['/model-compact cheap', '/model-tool cheap', '/model-aproval cheap'])
        cheap = next(agent for agent in json.loads(config.read_text())['agents']
                     if agent['id'] == 'cheap')
        output = run(['/model hello::org/unified:latest', '/model'])
        # Reload once so newly created task agents have their named prompts normalized.
        output += run(['/model'])
        saved = json.loads(config.read_text())
        agents = {agent['id']: agent for agent in saved['agents']}
        assert agents['main']['provider'] == 'hello'
        assert agents['main']['model'] == 'org/unified:latest'
        assert set(saved['taskAgents']) == {'compact', 'tool', 'approval'}
        for task, agent_id in saved['taskAgents'].items():
            agent = agents[agent_id]
            assert agent['provider'] == 'hello' and agent['model'] == 'org/unified:latest'
            assert f'{task}: {agent_id} — hello::org/unified:latest' in output, output
        assert agents['cheap'] == cheap, 'changing all models rewrote an unrelated saved agent'
        tasks = saved['taskAgents']
        task_agents = {agent_id: agents[agent_id] for agent_id in tasks.values()}

        output = run(['/model-chat local::chat-only', '/model'])
        saved = json.loads(config.read_text())
        agents = {agent['id']: agent for agent in saved['agents']}
        assert agents['main']['provider'] == 'local' and agents['main']['model'] == 'chat-only'
        assert saved['taskAgents'] == tasks
        assert {agent_id: agents[agent_id] for agent_id in tasks.values()} == task_agents
        assert 'Chat: local::chat-only' in output, output
        assert 'Chat: local::chat-only' in run(['/model-chat'])

        # Bare names use the current provider and remain model IDs even when an agent matches.
        run(['/model cheap', '/model-chat final-chat'])
        saved = json.loads(config.read_text())
        agents = {agent['id']: agent for agent in saved['agents']}
        assert agents['main']['model'] == 'final-chat'
        for agent_id in saved['taskAgents'].values():
            assert agents[agent_id]['provider'] == 'local' and agents[agent_id]['model'] == 'cheap'
        original = config.read_bytes()
        run(['/model', '/model-chat'])
        assert config.read_bytes() == original, 'showing models changed the configuration'
        print('PASS /model updates all tasks; /model-chat preserves their assignments across restarts')


if __name__ == '__main__':
    main()
