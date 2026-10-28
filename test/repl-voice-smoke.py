#!/usr/bin/env python3
"""Voice capture, concurrent text, streaming playback, and draft-safe controls without audio hardware."""
import fcntl
import json
import os
from pathlib import Path
import pty
import queue
import shlex
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from http.server import ThreadingHTTPServer
from smoke import JSONProvider, clean_environment, expect_pty, read_pty, run_repl

requests = queue.Queue()
finish_first = threading.Event()


class Provider(JSONProvider):
    def do_GET(self):
        self.respond({'data': [{'id': name} for name in
                              (('fixture-one', 'fixture-two') if self.path.endswith('/voices') else ('test',))]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        last_user = max(i for i, message in enumerate(body['messages']) if message['role'] == 'user')
        prompt = body['messages'][last_user]['content']
        has_tools = any(message['role'] == 'tool' for message in body['messages'][last_user + 1:])
        if not has_tools:
            requests.put((self.path, body))
        try:
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()

            def chunk(text):
                self.wfile.write(('data: ' + json.dumps({'choices': [{'index': 0, 'delta': {'content': text}}]}) + '\n\n').encode())
                self.wfile.flush()

            if prompt == 'voice-two' and not has_tools:
                delta = {'tool_calls': [{'index': 0, 'id': 'voice-list', 'type': 'function',
                         'function': {'name': 'voice_agents', 'arguments': '{}'}}]}
                self.wfile.write(('data: ' + json.dumps({'choices': [{'index': 0, 'delta': delta,
                    'finish_reason': 'tool_calls'}]}) + '\n\n').encode())
                self.wfile.flush()
            elif prompt == 'voice-one':
                chunk('First spoken sentence. ')
                finish_first.wait(20)
                chunk('Second spoken sentence.')
            else:
                chunk('Reply to ' + prompt + '.')
            self.wfile.write(b'data: [DONE]\n\n')
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    binary = str(Path(sys.argv[1]).resolve())
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = clean_environment()
    env.update(TERM='xterm-256color', NO_COLOR='1', NO_PROXY='127.0.0.1,localhost')
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-voice-') as directory:
            root = Path(directory)
            # A real-time raw PCM source: speech followed by silence, until cancelled.
            capture = root / 'capture.py'
            capture.write_text('import sys,time,struct\nfor i in range(1000):\n sys.stdout.buffer.write(struct.pack("<h",5000 if i<3 else 0)*1600);sys.stdout.buffer.flush();time.sleep(.1)\n')
            transcription = root / 'transcribe.py'
            transcription.write_text('import sys,wave,pathlib\nwith wave.open(sys.argv[1]) as w: assert w.getframerate()==16000 and w.getnframes()>0\nassert sys.argv[2]=="ca-ES"\np=pathlib.Path(sys.argv[3]);n=int(p.read_text())+1 if p.exists() else 1;p.write_text(str(n))\nprint("" if n==1 else "voice-one" if n==2 else "voice-two")\n')
            speech = root / 'speech.py'
            speech.write_text('import sys,pathlib\nwith pathlib.Path(sys.argv[1]).open("a") as f: f.write(sys.stdin.read()+"\\n");f.flush()\n')
            spoken = root / 'spoken.txt'
            config = root / 'config.json'
            config.write_text(json.dumps({
                'version': 1, 'defaultAgent': 'test', 'ui': {'mode': 'buffer', 'tools': -1},
                'approvals': {'mode': 'yolo'},
                'providers': [{'id': 'test', 'kind': 'openai', 'baseURL': f'http://127.0.0.1:{server.server_port}/v1'},
                              {'id': 'spoken', 'kind': 'openai', 'baseURL': f'http://127.0.0.1:{server.server_port}/spoken/v1'}],
                'agents': [{'id': 'test', 'provider': 'test', 'model': 'test', 'toolNames': [], 'toolGroupNames': [], 'retry': {'attempts': 0}},
                           {'id': 'voice-model', 'provider': 'spoken', 'model': 'voice-test',
                            'instructions': 'VOICE_TASK_RULES', 'toolNames': [], 'retry': {'attempts': 0}}],
                'taskAgents': {'voice': 'voice-model'},
                'voice': {'language': 'ca-ES', 'input': 'command', 'output': 'command', 'provider': 'test', 'silenceSeconds': .2,
                          'instructions': 'LEGACY_VOICE_INSTRUCTIONS',
                          'captureCommand': {'executable': sys.executable, 'arguments': [str(capture)]},
                          'transcriptionCommand': {'executable': sys.executable, 'arguments': [str(transcription), '{audio}', '{language}', str(root / 'count')]},
                          'speechCommand': {'executable': sys.executable, 'arguments': [str(speech), str(spoken)]}}
            }))
            editor = root / 'edit-voice.py'
            editor.write_text('from pathlib import Path\nimport sys\n'
                              'p=Path(sys.argv[1])\n'
                              'Path("voice-editor-input.txt").write_text(p.read_text())\n'
                              'p.write_text("CUSTOM_VOICE_INSTRUCTIONS")\n')
            env['EDITOR'] = shlex.join([sys.executable, str(editor)])
            listing = run_repl(
                [binary, '--config', str(config), '--home', str(root / 'home'), '--no-markdown'],
                ['/prompts', '/prompts show voice', '/prompts show voiceover', '/edit prompt voice',
                 '/prompts show voice', '/set voice.instructions Do not save this', '/set voice.'],
                cwd=root, env=env)
            assert 'LEGACY_VOICE_INSTRUCTIONS' in listing and 'CUSTOM_VOICE_INSTRUCTIONS' in listing, listing
            assert (root / 'voice-editor-input.txt').read_text() == 'LEGACY_VOICE_INSTRUCTIONS'
            assert 'spoken summary of one or two short sentences' in listing, listing
            assert 'Use /edit prompt voice' in listing and 'voice.instructions =' not in listing, listing
            saved = json.loads(config.read_text())
            assert saved['prompts']['system']['voice'] == 'CUSTOM_VOICE_INSTRUCTIONS', saved
            assert 'instructions' not in saved['voice'], saved
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 200, 0, 0))
            process = subprocess.Popen([binary, '--config', str(config), '--home', str(root / 'home'), '--no-markdown'],
                                       cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
            os.close(slave)
            output = bytearray()

            def wait(text):
                return expect_pty(master, process, output, text, 15)

            def send(text):
                os.write(master, text.replace('\n', '\r').encode())

            def request(prompt, voice=False):
                deadline = time.monotonic() + 15
                while requests.empty():
                    assert time.monotonic() < deadline, output.decode(errors='replace')
                    read_pty(master, output, .05)
                path, body = requests.get_nowait()
                assert path == ('/spoken' if voice else '') + '/v1/chat/completions', (path, body)
                assert body['messages'][-1]['content'] == prompt, body
                assert body['model'] == ('voice-test' if voice else 'test'), body
                return body

            def wait_spoken(text):
                deadline = time.monotonic() + 15
                while not spoken.exists() or text not in spoken.read_text():
                    assert time.monotonic() < deadline, output.decode(errors='replace')
                    read_pty(master, output, .05)

            try:
                wait('pmai>')
                send('/set voice.output openai\n')
                wait('Set voice.output')
                send('/voice voices\n')
                wait('fixture-two')
                send('/set voice.voice fixture-o\t')
                wait('/set voice.voice fixture-one')
                send('\n')
                wait('Set voice.voice')
                assert json.loads(config.read_text())['voice']['voice'] == 'fixture-one'
                send('/set voice.language ca\t')
                wait('/set voice.language ca-ES')
                send('\n')
                wait('Set voice.language')
                send('/set voice.output command\n')
                wait('Set voice.output')
                send('remember sapphire\n')
                request('remember sapphire')
                wait('took')
                send('/voice walkie-talkie\n')
                wait('walkie-talkie · listening')
                time.sleep(.35)
                assert requests.empty(), 'Walkie-talkie submitted automatically'
                send('draft stays here')
                os.write(master, b'\x07')  # Ctrl+G discards capture and keeps the typed draft.
                wait('walkie-talkie · paused')
                assert requests.empty(), 'Discard submitted voice'
                os.write(master, b'\x00')
                wait('walkie-talkie · listening')
                read_pty(master, output, .25)
                os.write(master, b'\x14')  # Ctrl+T finalizes transcription and sends.

                # Empty recognition keeps listening and preserves the typed draft.
                wait('walkie-talkie · transcribing')
                recovered = wait('walkie-talkie · listening')
                assert ' · error · ' not in recovered, recovered
                assert requests.empty(), 'Empty recognition started an agent turn'
                assert (root / 'count').read_text() == '1'
                read_pty(master, output, .25)
                os.write(master, b'\x14')

                first = request('voice-one', voice=True)
                assert sum(str(m['content']).count('CUSTOM_VOICE_INSTRUCTIONS') for m in first['messages']) == 1, first
                assert any(m['role'] == 'system' and 'VOICE_TASK_RULES' in str(m['content']) for m in first['messages']), first
                assert any(m['content'] == 'remember sapphire' for m in first['messages']), first
                assert any('Voice language: ca-ES' in str(m['content']) for m in first['messages']), first
                assert {'voice_agents', 'voice_message'} <= {t['function']['name'] for t in first['tools']}, first
                wait_spoken('First spoken sentence.')
                wait('First spoken sentence.')  # Visible in the text frame before the model finishes.
                assert not finish_first.is_set(), 'Speech waited for the full response'
                send('\n')
                request('draft stays here')
                wait('Reply to draft stays here.')
                send('/view voice\n')
                frame = wait('view: voice')
                assert 'First spoken sentence.' in frame and 'you: voice-one' in frame, frame
                finish_first.set()
                wait_spoken('Second spoken sentence.')
                wait('Second spoken sentence.')
                wait('walkie-talkie · paused')
                send('/prompt set voice UPDATED_VOICE_INSTRUCTIONS\n')
                wait("Saved system prompt 'voice'")
                os.write(master, b'\x00')
                wait('walkie-talkie · listening')
                read_pty(master, output, .25)
                os.write(master, b'\x1b[116;5u')  # Extended-keyboard Ctrl+T.
                second = request('voice-two', voice=True)
                assert any(m['role'] == 'system' and 'UPDATED_VOICE_INSTRUCTIONS' in str(m['content']) for m in second['messages']), second
                assert not any('CUSTOM_VOICE_INSTRUCTIONS' in str(m['content']) for m in second['messages']), second
                assert any(m['content'] == 'draft stays here' for m in second['messages']), second
                assert sum(m['content'] == 'voice-one' for m in second['messages']) == 1, second
                assert any(m['role'] == 'assistant' and 'First spoken sentence.' in str(m['content']) for m in second['messages']), second
                wait('voice_agents')
                wait('test.voice [')  # The tool result is visible in the voice frame too.
                wait_spoken('Reply to voice-two.')
                wait('walkie-talkie · paused')
                send('/view off\n')
                wait('pmai>')
                send('/voice off\n/voice realtime\n')
                wait('realtime · listening')
                request('voice-two', voice=True)  # Energy followed by silence commits without a key.
                wait('voice_agents')
                wait('test.voice [')
                wait('Reply to voice-two.')
                send('/voice off\n/set ui.mode classic\n/voice walkie-talkie\n')
                wait('walkie-talkie · listening')
                read_pty(master, output, .25)
                os.write(master, b'\x14')
                request('voice-two', voice=True)
                wait('voice_agents')
                wait('test.voice [')
                wait('Reply to voice-two.')
                send('/voice off\n/set voice.language en-US\n')
                wait('Set voice.language')
                send('/set voice.speechCommand {"executable":"cat","arguments":["a=b"]}\n')
                wait('Set voice.speechCommand')
                saved = json.loads(config.read_text())
                assert saved['voice']['language'] == 'en-US', saved
                assert saved['voice']['speechCommand']['arguments'] == ['a=b'], saved
                send('/prompt del voice\n/prompts show voice\n')
                wait("Restored built-in system prompt 'voice'.")
                wait('You are the voice agent in a conversation')
                wait('speech-to-text transcriptions')
                send('/exit\n')
                deadline = time.monotonic() + 10
                while process.poll() is None:
                    assert time.monotonic() < deadline, output.decode(errors='replace')
                    read_pty(master, output, .05)
                assert process.returncode == 0, process.returncode
            finally:
                finish_first.set()
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
                os.close(master)
    finally:
        server.shutdown()
        server.server_close()
    print('repl voice smoke: ok')


if __name__ == '__main__':
    main()
