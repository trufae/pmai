#!/usr/bin/env python3
"""Build once and run explicit deterministic suites; never invoke live models."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
SMOKE = '''installer project-approval project-debug provider-routing repl-defaults
repl-export repl-local-providers repl-resume repl-resume-routing
repl-resume-state repl-skills repl-smart-context repl-tool-policy task-agents
update web-fetch'''.split()
TERMINAL = '''repl-agents repl-colors repl-compaction repl-interactive-run repl-models repl-path
repl-queue repl-recap repl-resize repl-suspend repl-theme repl-tool-context'''.split()
EXTERNAL = ['repl-reflow', 'tailcat']  # Ghostty and a separately built tailcat binary.
PLATFORM = ['web-fetch'] if os.name == 'nt' else [
    'update', 'web-fetch', 'project-approval', 'repl-defaults', 'repl-suspend', 'repl-models']
if sys.platform.startswith('linux'):
    PLATFORM.append('linux-network')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('profile', choices=['core', 'chat', 'unit', 'smoke', 'terminal', 'platform', 'full', 'external'])
    parser.add_argument('--binary', type=Path, default=ROOT / 'MaiCore/.build/debug/pmai')
    parser.add_argument('--skip-build', action='store_true', help='Reuse prepared tests and CLI binary')
    parser.add_argument('--jobs', type=int, default=1, help='Maximum concurrent smoke scripts (default: 1)')
    parser.add_argument('--tailcat', type=Path, help='Tailcat binary for the external profile')
    parser.add_argument('--ghostty', type=Path, help='Ghostty web engine checkout for the external profile')
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    if args.profile == 'external' and (not args.tailcat or not args.ghostty):
        parser.error('The external profile requires --tailcat and --ghostty')
    if args.profile in ('terminal', 'full', 'external') and os.name == 'nt':
        parser.error('PTY suites require a POSIX host; use the platform profile on Windows')
    # New deterministic scripts must have an explicit owner instead of silently missing CI.
    known = set(SMOKE + TERMINAL + EXTERNAL + ['acp-gateway', 'linux-network'])
    found = {p.name.removesuffix('-smoke.py') for p in (ROOT / 'test').glob('*-smoke.py')}
    if found != known:
        parser.error(f'Update suite ownership: unlisted={found-known}, missing={known-found}')
    env = os.environ.copy()
    env.pop('PMAI_TEST_PROFILE', None)
    swift = [env.get('SWIFT', 'swift'), 'test', '--package-path', str(ROOT / 'MaiCore'), '--disable-index-store']
    if args.profile in ('core', 'chat'):
        env['PMAI_TEST_PROFILE'] = args.profile
        swift += ['--scratch-path', str(ROOT / 'MaiCore/.build' / (args.profile + '-tests'))]
    if args.profile in ('core', 'chat', 'unit', 'full'):
        # SwiftPM removes the package lockfile when the focused graph has no
        # external dependencies. Keep the full graph's pins for the next build.
        lockfile = ROOT / 'MaiCore/Package.resolved'
        pins = lockfile.read_bytes() if lockfile.exists() else None
        try:
            subprocess.run(swift + (['--skip-build'] if args.skip_build else []), cwd=ROOT, env=env, check=True)
        finally:
            if args.profile in ('core', 'chat') and pins is not None and not lockfile.exists():
                lockfile.write_bytes(pins)
        if args.profile != 'full':
            return
        env['PMAI_TESTS_BUILT'] = '1'
    if not args.skip_build:
        subprocess.run([env.get('SWIFT', 'swift'), 'build', '--package-path', str(ROOT / 'MaiCore'),
                        '--disable-index-store', '--product', 'pmai'], cwd=ROOT, env=env, check=True)
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error(f'CLI binary missing: {binary}')
    suites = dict(smoke=SMOKE, terminal=TERMINAL, platform=PLATFORM, external=EXTERNAL,
                  full=SMOKE + TERMINAL + ['linux-network', 'acp-gateway'])

    def run(name):
        command = [sys.executable, str(ROOT / 'test' / (name + '-smoke.py'))]
        if name != 'installer':
            command.append(str(binary))
        if name in EXTERNAL:
            command.append(str((args.tailcat if name == 'tailcat' else args.ghostty).resolve()))
        started = time.monotonic()
        result = subprocess.run(command, cwd=ROOT, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print(f'{"PASS" if result.returncode == 0 else "FAIL"} {name}: {time.monotonic()-started:.2f}s', flush=True)
        if result.returncode:
            print(result.stdout, flush=True)
        return result.returncode == 0

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        passed = list(pool.map(run, suites[args.profile]))
    if args.profile == 'full':
        subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'test/bench',
                        '-p', 'test_proxy.py'], cwd=ROOT, check=True)
        print('External prerequisites: run the external profile for Ghostty and tailcat.', flush=True)
    sys.exit(not all(passed))


if __name__ == '__main__':
    main()
