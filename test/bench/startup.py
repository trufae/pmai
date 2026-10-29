#!/usr/bin/env python3
"""Compare two CLI binaries from process launch to prompt and first local reply."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import platform
import pty
import select
import statistics
import struct
import subprocess
import sys
import tempfile
import termios
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from smoke import clean_environment


def measure(binary, root, env):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 180, 0, 0))
    started = time.perf_counter()
    process = subprocess.Popen(
        [str(binary), '--config', str(root / 'config.json'), '--home', str(root / 'home'),
         '--no-markdown'], cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave,
        start_new_session=True)
    os.close(slave)
    output = bytearray()

    def receive():
        try:
            output.extend(os.read(master, 65536))
        except OSError:
            assert process.poll() is not None, output.decode(errors='replace')

    def wait(marker):
        deadline = time.perf_counter() + 15
        while marker not in output:
            assert process.poll() is None, output.decode(errors='replace')
            remaining = deadline - time.perf_counter()
            assert remaining > 0, output.decode(errors='replace')
            if select.select([master], [], [], remaining)[0]:
                receive()
        output.clear()
        return (time.perf_counter() - started) * 1000

    try:
        prompt_ms = wait(b'pmai> ')
        os.write(master, b'/help startup-benchmark\r')
        reply_ms = wait(b"Unknown help topic 'startup-benchmark'")
        os.write(master, b'/exit\r')
        deadline = time.perf_counter() + 10
        while process.poll() is None:
            assert time.perf_counter() < deadline, output.decode(errors='replace')
            if select.select([master], [], [], .01)[0]:
                receive()
        assert process.returncode == 0, output.decode(errors='replace')
        return {'prompt_ms': prompt_ms, 'reply_ms': reply_ms}
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    parser.add_argument('--runs', type=int, default=15)
    parser.add_argument('--skills', type=int, nargs='+', default=[0, 300])
    parser.add_argument('--output', type=Path, help='Save all samples as JSON')
    args = parser.parse_args()
    if args.runs < 1 or min(args.skills) < 0:
        parser.error('runs must be positive and skill counts nonnegative')
    binaries = {'before': args.before.resolve(), 'after': args.after.resolve()}
    env = clean_environment() | {'TERM': 'xterm-256color', 'NO_COLOR': '1'}
    report = {'platform': platform.platform(), 'machine': platform.machine(),
              'runs': args.runs, 'warmups_per_binary': 2,
              'binaries': {key: str(value) for key, value in binaries.items()}, 'cases': []}
    print('mode     skills  prompt before -> after     first reply before -> after (median ms)')
    for mode in ('classic', 'buffer'):
        for count in args.skills:
            with tempfile.TemporaryDirectory(prefix='pmai-startup-bench-') as directory:
                root = Path(directory)
                (root / 'config.json').write_text(json.dumps({
                    'version': 1, 'defaultAgent': 'test', 'ui': {'mode': mode},
                    'providers': [{'id': 'test', 'kind': 'hello'}],
                    'agents': [{'id': 'test', 'provider': 'test', 'model': 'hello', 'toolNames': []}],
                    'voice': {'input': 'command', 'output': 'command'},
                }))
                for index in range(count):
                    skill = root / 'home/skills' / f'fixture-{index}'
                    skill.mkdir(parents=True)
                    (skill / 'SKILL.md').write_text(
                        f'---\nname: fixture-{index}\ndescription: A fixture skill\n---\nDo this work.\n')
                for _ in range(2):
                    for binary in binaries.values():
                        measure(binary, root, env)
                samples = {key: [] for key in binaries}
                for run in range(args.runs):
                    order = list(binaries) if run % 2 == 0 else list(reversed(binaries))
                    for key in order:
                        samples[key].append(measure(binaries[key], root, env))
                medians = {key: {metric: statistics.median(sample[metric] for sample in values)
                                 for metric in ('prompt_ms', 'reply_ms')}
                           for key, values in samples.items()}
                report['cases'].append({'mode': mode, 'skills': count,
                                        'medians': medians, 'samples': samples})
                before, after = medians['before'], medians['after']
                print(f"{mode:8} {count:6}  {before['prompt_ms']:7.1f} -> {after['prompt_ms']:7.1f}"
                      f"       {before['reply_ms']:7.1f} -> {after['reply_ms']:7.1f}", flush=True)
    if args.output:
        args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
