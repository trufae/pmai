#!/usr/bin/env python3
"""Check standalone Vim installation and selection transforms against a local provider."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import ThreadingHTTPServer

from smoke import clean_environment, JSONProvider


class Provider(JSONProvider):
    def do_GET(self):
        self.respond({'data': [{'id': 'editor-model'}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.server.requests.append(request)
        if self.server.fail:
            self.respond({'error': {'message': 'fixture failure'}}, status=503)
        else:
            self.respond({'choices': [{'message': {'role': 'assistant', 'content': 'fixed one\nfixed two'},
                                      'finish_reason': 'stop'}]})


def vim_string(value):
    return "'" + str(value).replace("'", "''") + "'"


def main():
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix='pmai-vim-') as directory:
        root = Path(directory)
        home = root / "home with ' spaces"
        home.mkdir()
        # Run a detached executable from an unrelated directory: no SwiftPM resource bundle.
        detached = root / ('pmai.exe' if os.name == 'nt' else 'pmai')
        shutil.copy2(binary, detached)
        env = clean_environment() | {'HOME': str(home), 'USERPROFILE': str(home),
                                     'PMAI_CONFIG': str(root / 'missing-config.json')}
        runtime = home / ('vimfiles' if os.name == 'nt' else '.vim')
        package = runtime / 'pack/pmai/start/pmai'
        plugin = package / 'plugin/pmai.vim'
        prompts = package / 'prompts.txt'
        vimrc = home / '.vimrc'
        vimrc.write_text('" my existing configuration\n')

        def run(*args, status=0):
            had_project = (root / '.pmai').exists()
            result = subprocess.run([str(detached), *args], cwd=root, env=env,
                                    capture_output=True, text=True, timeout=30)
            output = result.stdout + result.stderr
            assert result.returncode == status, (result.returncode, output)
            assert (root / '.pmai').exists() == had_project, 'Installer initialized project state'
            return output

        assert '--vim ACTION' in run('--help', '--vim', 'install')
        assert not package.exists()
        run('--vim', status=2)
        run('--vim', 'invalid', status=2)
        run('--vim-dir', str(runtime), status=2)
        run('--vim', 'install')
        original = plugin.read_bytes()
        assert 'function! Pmai() range abort' in original.decode()
        assert 'fix typos' in prompts.read_text()
        prompts.write_text('custom prompt with a quote: \' and $HOME\n')
        for action in ('install', 'update'):
            plugin.write_text('outdated script\n')
            run('--vim', action)
            assert plugin.read_bytes() == original
            assert prompts.read_text() == 'custom prompt with a quote: \' and $HOME\n'
        assert vimrc.read_text() == '" my existing configuration\n'
        custom = home / 'custom runtime'
        run('--vim', 'install', '--vim-dir', '~/custom runtime')
        custom_plugin = custom / 'pack/pmai/start/pmai/plugin/pmai.vim'
        assert custom_plugin.read_bytes() == original
        run('--vim', 'uninstall', '--vim-dir', str(custom))
        assert not custom_plugin.exists()
        print('PASS detached install, help, validation, repeated install, update and custom directory')

        vim = shutil.which('vim')
        if vim:
            server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
            server.requests, server.fail = [], False
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                config = root / 'config.json'
                config.write_text(json.dumps({
                    'defaultAgent': 'editor',
                    'providers': [{'id': 'local', 'kind': 'openAICompatible',
                                   'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                    'agents': [{'id': 'editor', 'provider': 'local', 'model': 'editor-model',
                                'stream': False, 'retry': {'attempts': 0}}],
                    'memory': {'enabled': False}, 'use': {'plan': False},
                }))
                env.update(PMAI_CONFIG=str(config), NO_PROXY='127.0.0.1,localhost')

                def transform(command, answers, expected, extra=''):
                    script, result = root / 'check.vim', root / 'buffer.txt'
                    script.write_text('\n'.join([
                        'set nocompatible',
                        'execute "set packpath=" . fnameescape(' + vim_string(runtime) + ')',
                        'packloadall',
                        'call assert_equal(2, exists(":Pmai"))',
                        'let g:pmai_color = 0',
                        'let g:pmai_command = ' + vim_string(detached),
                        'call setline(1, ["before", "bad one", "bad two", "after"])',
                        extra,
                        'call feedkeys(' + json.dumps(answers) + ', "t")',
                        command,
                        'call writefile(getline(1, "$"), ' + vim_string(result) + ')',
                        'if !empty(v:errors) | cquit | endif',
                        'qa!',
                    ]) + '\n')
                    log = root / 'vim.log'
                    log.write_text('')
                    completed = subprocess.run([vim, '-Nu', 'NONE', '-n', '-es', '-V1' + str(log), '-S', str(script)],
                                               cwd=root, env=env, capture_output=True, text=True, timeout=30)
                    assert completed.returncode == 0, completed.stdout + completed.stderr + log.read_text()
                    assert result.read_text().splitlines() == expected, result.read_text()

                transform('2,3Pmai', '1\r2\r', ['before', 'fixed one', 'fixed two', 'after'])
                request = server.requests[-1]
                assert request['model'] == 'editor-model', request
                content = json.dumps(request['messages'], ensure_ascii=False)
                assert 'bad one\\nbad two' in content and 'bad one\\nbad two\\nafter' not in content, content
                assert 'custom prompt with a quote' in content and '$HOME' in content, content
                # Exercise the visual mapping itself, with a multi-line selection.
                transform('call feedkeys("2GVjm", "xti")', '1\r3\r',
                          ['before', 'bad one', 'bad two', 'fixed one', 'fixed two', 'after'])
                transform('%Pmai', 'i\r--help\r2\r', ['fixed one', 'fixed two'])
                assert 'Request: --help' in json.dumps(server.requests[-1]), server.requests[-1]
                before = len(server.requests)
                transform('2,3Pmai', '\r', ['before', 'bad one', 'bad two', 'after'])
                assert len(server.requests) == before, 'Cancel called the provider'
                server.fail = True
                transform('try | 2,3Pmai | catch | call assert_match("pmai failed", v:exception) | endtry',
                          '1\r', ['before', 'bad one', 'bad two', 'after'])
                print('PASS Vim package loading, ranges, visual mapping, saved defaults, clean replies and failure')
            finally:
                server.shutdown()
                server.server_close()
        else:
            print('SKIP Vim execution: vim is not on PATH')

        extra = package / 'plugin/custom.vim'
        extra.write_text('" user file\n')
        run('--vim', 'uninstall')
        run('--vim', 'uninstall')
        assert not plugin.exists() and prompts.exists() and extra.exists()
        assert vimrc.read_text() == '" my existing configuration\n'
        print('PASS idempotent uninstall preserves custom files, prompts and vimrc')


if __name__ == '__main__':
    main()
