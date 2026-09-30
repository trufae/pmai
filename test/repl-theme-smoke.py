#!/usr/bin/env python3
"""Check built-in themes, saved scripts, and startup overrides with the offline provider."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    binary = str(Path(sys.argv[1]).resolve())
    environment = {k: v for k, v in os.environ.items()
                   if not k.startswith(('PMAI_', 'MAI_', 'OPENAI_'))}
    with tempfile.TemporaryDirectory(prefix='pmai-theme-') as directory:
        root = Path(directory)
        home = root / 'home'
        themes = home / 'themes'
        config = root / 'config.json'
        config.write_text(json.dumps({
            'version': 1, 'defaultAgent': 'hello',
            'providers': [{'id': 'hello', 'kind': 'hello'}],
            'agents': [{'id': 'hello', 'provider': 'hello', 'model': ''}],
            'ui': {'title': 'keep', 'markdown': False, 'toolResultLines': 3},
        }))

        def run(*commands, theme=None, flags=()):
            env = dict(environment, PMAI_HOME=str(home))
            if theme is not None:
                env['PMAI_THEME'] = theme
            result = subprocess.run(
                [binary, '--config', str(config), *flags], cwd=root, env=env,
                input='\n'.join([*commands, '/exit', '']), capture_output=True,
                text=True, timeout=20)
            output = result.stdout + result.stderr
            assert result.returncode == 0, output
            return output

        def ui():
            return json.loads(config.read_text())['ui']

        output = run('/theme', '/help theme')
        assert 'default\nember\nlight\norange\npink\nsky\nslime\n' in output, output
        assert 'PMAI_THEME=NAME' in output, output
        assert not themes.exists(), 'listing must not install built-in theme files'

        run('/theme use default')
        original = ui()
        colors = ('fgtoolcall', 'fgerror', 'fgwarning', 'fgsuccess', 'fginfo', 'fgthinking',
                  'fgdiffadd', 'bgdiffadd', 'fgdiffdel', 'bgdiffdel', 'fgdiffheader',
                  'fgselection', 'bgselection')
        listing = run('/set ui.', '/help set')
        for key in colors:
            assert f'ui.{key} = {original[key]}' in listing, listing
            assert f'/set ui.{key} COLOR' in listing, listing
        for name in ('slime', 'light', 'ember', 'pink', 'orange', 'sky'):
            output = run(f'/theme use {name}')
            assert f"Applied theme '{name}'." in output, output
            assert ui() != original
            assert all(ui()[key] != original[key] for key in colors), ui()
            for key in ('title', 'markdown', 'toolResultLines'):
                assert ui()[key] == original[key], ui()
            run('/theme use default')
            assert ui() == original, 'default must restore every theme setting'

        run('/theme use light', '/theme save mine')
        light = ui()
        saved = (themes / 'mine').read_text()
        assert len(saved.splitlines()) == 20 and '/set ui.bold off' in saved, saved
        assert 'ui.title' not in saved
        for key in colors:
            assert f'/set ui.{key} {light[key]}' in saved, saved
        run('/theme use slime', '/theme use mine')
        assert ui() == light, 'saved themes must round-trip'
        assert 'mine' in run('/theme list').splitlines()

        run('/theme use default')
        before = config.read_bytes()
        output = run('/set ui.fgcolor', theme='mine')
        assert f"ui.fgcolor = {light['fgcolor']}" in output, output
        assert config.read_bytes() == before, 'startup override must not save itself'
        assert 'ui.bgline = rgb:eee' in run('/set ui.bgline', theme='light')
        assert 'ui.bold = on' in run('/set ui.bold', theme='slime')

        (themes / 'custom').write_text(
            '# Partial theme\n\n/set UI.FGCOLOR=#123456\n/set ui.bold YES\n')
        run('/theme use custom')
        assert ui()['fgcolor'] == '#123456' and ui()['bold'] is True
        assert ui()['bgline'] == original['bgline']
        (themes / 'slime').write_text('/set ui.fgcolor blue\n')
        assert 'ui.fgcolor = blue' in run('/set ui.fgcolor', theme='slime')

        for key in colors:
            run(f'/set ui.{key} #123456')
            assert ui()[key] == '#123456', ui()
            run(f'/set ui.{key} none')
            assert ui()[key] == '', ui()
        run('/theme save plain')
        run('/theme use sky', '/theme use plain')
        assert all(ui()[key] == '' for key in colors), ui()

        before = config.read_bytes()
        for invalid in ('/set ui.bgline bad-color', '/set ui.bold maybe',
                        '/set ui.broadcast on', '!touch forbidden', '/set ui.fgcolor',
                        '/set ui.fgerror bad-color', '/set ui.bgdiffadd bad-color'):
            (themes / 'broken').write_text('/set ui.fgcolor red\n' + invalid + '\n')
            output = run('/theme use broken', '/set ui.fgcolor')
            assert "Theme 'broken', line 2:" in output, output
            assert 'ui.fgcolor = #123456' in output, output
            assert config.read_bytes() == before, 'invalid themes must not apply partially'
        output = run('/set ui.fgcolor', theme='broken')
        assert 'warning:' in output and 'ui.fgcolor = #123456' in output, output
        for name in ('missing', '../escape', '/tmp/escape'):
            output = run(f'/theme use {name}')
            assert 'error:' in output and config.read_bytes() == before, output
        assert 'warning: Unknown theme' in run(theme='missing')
        assert 'error:' in run('/theme save ../escape')
        assert not (home / 'escape').exists()

        run('/set ui.fgcolor cyan', '/set ui.bold false', '/theme save mine')
        assert '/set ui.fgcolor cyan' in (themes / 'mine').read_text()
        assert '/set ui.bold off' in (themes / 'mine').read_text()
        alternate = root / 'alternate'
        run('/theme save relocated', flags=('--home', str(alternate)))
        assert (alternate / 'themes' / 'relocated').exists()
        assert not (themes / 'relocated').exists()
    print('theme smoke passed')


if __name__ == '__main__':
    main()
