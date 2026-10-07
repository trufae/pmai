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
        theme_colors = ('bgline', 'fgcolor', 'bgcolor', 'fgprompt', 'bgprompt', 'fgtoolresult', *colors)
        before = config.read_bytes()
        listing = run('/theme color', '/help theme')
        assert config.read_bytes() == before, 'listing must not change the configuration'
        for key in theme_colors:
            assert f'{key} = {original[key] or "none"}' in listing, listing
            assert f'/theme color {key} COLOR' in listing, listing
        assert 'bold = off' in listing, listing
        settings = run('/set', '/set ui.', '/help set', '/set unknown-setting')
        for key in (*theme_colors, 'bold'):
            assert f'ui.{key}' not in settings, settings
        assert 'ui.markdown' in settings and 'ui.editor' in settings, settings
        redirected = run('/set ui.fgerror cyan', '/set ui.bold on')
        assert 'Use /theme color fgerror [VALUE].' in redirected, redirected
        assert 'Use /theme color bold [VALUE].' in redirected, redirected
        assert config.read_bytes() == before, 'old color commands must only give guidance'
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
        assert len(saved.splitlines()) == 20 and '/theme color bold off' in saved, saved
        assert 'ui.title' not in saved
        for key in colors:
            assert f'/theme color {key} {light[key]}' in saved, saved
        run('/theme use slime', '/theme use mine')
        assert ui() == light, 'saved themes must round-trip'
        assert 'mine' in run('/theme list').splitlines()

        run('/theme use default')
        before = config.read_bytes()
        output = run('/theme color fgcolor', theme='mine')
        assert f"fgcolor = {light['fgcolor']}" in output, output
        assert config.read_bytes() == before, 'startup override must not save itself'
        assert 'bgline = rgb:eee' in run('/theme color bgline', theme='light')
        assert 'bold = on' in run('/theme color bold', theme='slime')

        (themes / 'custom').write_text(
            '# Partial theme\n\n/theme color FGCOLOR=#123456\n/theme color bold YES\n')
        run('/theme use custom')
        assert ui()['fgcolor'] == '#123456' and ui()['bold'] is True
        assert ui()['bgline'] == original['bgline']
        # Existing saved themes remain readable, including case and equals syntax.
        (themes / 'slime').write_text('/set UI.FGCOLOR=blue\n/set ui.bold YES\n')
        assert 'fgcolor = blue' in run('/theme color fgcolor', theme='slime')
        assert 'bold = on' in run('/theme color bold', theme='slime')

        for key in theme_colors:
            run(f'/theme color {key.upper()}=#123456')
            assert ui()[key] == '#123456', ui()
            run(f'/theme color {key} none')
            assert ui()[key] == '', ui()
        run('/theme save plain')
        run('/theme use sky', '/theme use plain')
        assert all(ui()[key] == '' for key in theme_colors), ui()

        before = config.read_bytes()
        for invalid in ('/theme color fgerror bad-color', '/theme color bold maybe',
                        '/theme color unknown red', '/theme color fgerror cyan extra'):
            output = run(invalid)
            assert 'error:' in output or 'Unknown theme color' in output or 'Usage:' in output, output
            assert config.read_bytes() == before, 'invalid settings must not change the configuration'

        run('/theme color fgcolor #123456')

        before = config.read_bytes()
        for invalid in ('/theme color bgline bad-color', '/theme color bold maybe',
                        '/theme color broadcast on', '/set ui.broadcast on', '!touch forbidden',
                        '/theme color fgcolor', '/theme use default',
                        '/set ui.fgerror bad-color', '/set fgerror cyan',
                        '/theme color fgerror bad-color', '/theme color bgdiffadd bad-color'):
            (themes / 'broken').write_text('/theme color fgcolor red\n' + invalid + '\n')
            output = run('/theme use broken', '/theme color fgcolor')
            assert "Theme 'broken', line 2:" in output, output
            assert 'fgcolor = #123456' in output, output
            assert config.read_bytes() == before, 'invalid themes must not apply partially'
        output = run('/theme color fgcolor', theme='broken')
        assert 'warning:' in output and 'fgcolor = #123456' in output, output
        for name in ('missing', '../escape', '/tmp/escape'):
            output = run(f'/theme use {name}')
            assert 'error:' in output and config.read_bytes() == before, output
        assert 'warning: Unknown theme' in run(theme='missing')
        assert 'error:' in run('/theme save ../escape')
        assert not (home / 'escape').exists()

        run('/theme color fgcolor cyan', '/theme color bold false', '/theme save mine')
        assert '/theme color fgcolor cyan' in (themes / 'mine').read_text()
        assert '/theme color bold off' in (themes / 'mine').read_text()
        alternate = root / 'alternate'
        run('/theme save relocated', flags=('--home', str(alternate)))
        assert (alternate / 'themes' / 'relocated').exists()
        assert not (themes / 'relocated').exists()
    print('theme smoke passed')


if __name__ == '__main__':
    main()
