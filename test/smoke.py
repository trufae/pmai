"""Small helpers for isolated CLI sessions and loopback HTTP fixtures."""
import base64
import json
import os
import select
import subprocess
import time
import uuid
from http.server import BaseHTTPRequestHandler


def read_chat(path):
    """Read saved fixtures in legacy JSON or version 1 chunked storage."""
    saved = json.loads(path.read_text())
    if saved.get('format') != 'pmai-chunks':
        return saved
    assert saved['version'] == 1, saved['version']
    directory = path.parent / saved['partsDirectory']

    def expand(value):
        if isinstance(value, list):
            return [expand(item) for item in value]
        if isinstance(value, dict):
            if '_pmaiBlob' in value:
                return (directory / value['_pmaiBlob']).read_text()
            value = value.get('_pmaiObject', value)
            return {key: expand(item) for key, item in value.items()}
        return value

    def transcript(manifest):
        chat = json.loads(base64.b64decode(manifest['metadata']))
        chat['messages'] = []
        for chunk in manifest['chunks']:
            messages = json.loads((directory / chunk['filename']).read_text())
            assert len(messages) == chunk['count']
            chat['messages'].extend(expand(messages))
        chat['subagents'] = [transcript(child) for child in manifest['children']]
        return chat

    return transcript(saved)


def clean_environment():
    return {key: value for key, value in os.environ.items()
            if not key.startswith(('PMAI_', 'MAI_', 'OPENAI_'))
            and key.lower() not in ('http_proxy', 'https_proxy', 'all_proxy')}


def run_repl(command, commands=(), *, cwd, env, timeout=30, split=False, allow_errors=False):
    commands = list(commands)
    # Unknown help topics delimit responses without shell processes or model calls.
    topics = [f'smoke-{uuid.uuid4().hex}-{index}' for index in range(len(commands))] if split else []
    lines = [line for pair in zip(commands, topics) for line in
             (pair[0], '/help ' + pair[1])] if split else commands
    result = subprocess.run(command, cwd=cwd, env=env,
                            input='\n'.join([*lines, '/exit', '']),
                            capture_output=True, text=True, encoding='utf-8', timeout=timeout)
    output = result.stdout + result.stderr
    assert result.returncode == 0 and (allow_errors or 'error:' not in output), output
    if not split:
        return output
    responses = []
    for topic in topics:
        response, marker, output = output.partition(f"Unknown help topic '{topic}'")
        assert marker, (topic, output)
        responses.append(response)
    return responses


def read_pty(master, output, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not select.select([master], [], [], max(0, deadline - time.monotonic()))[0]:
            break
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        output.extend(chunk)


def expect_pty(master, process, output, text, timeout):
    deadline = time.monotonic() + timeout
    needle = text.encode()
    while needle not in output:
        assert process.poll() is None, (text, process.returncode, output.decode(errors='replace'))
        assert time.monotonic() < deadline, (text, output.decode(errors='replace'))
        read_pty(master, output, min(.05, max(0, deadline - time.monotonic())))
    end = output.index(needle) + len(needle)
    captured = bytes(output[:end]).decode(errors='replace')
    del output[:end]
    return captured


class JSONProvider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def respond(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
