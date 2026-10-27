#!/usr/bin/env python3
"""Check dependency download profiles without fetching or building packages."""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parent.parent


def manifest(package, **settings):
    env = os.environ.copy()
    for key in ('PMAI_FORWIROH_PLATFORM', 'PMAI_NO_MLX', 'PMAI_TEST_PROFILE'):
        env.pop(key, None)
    env.update(settings)
    return subprocess.run(
        [env.get('SWIFT', 'swift'), 'package', '--package-path', str(ROOT / package),
         '--disable-prefetching', 'dump-package'],
        env=env, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=60)


class DownloadProfiles(unittest.TestCase):
    def forwiroh_artifacts(self, **settings):
        result = manifest('Vendor/Forwiroh', **settings)
        self.assertEqual(result.returncode, 0, result.stderr)
        package = json.loads(result.stdout)
        binaries = {t['name'] for t in package['targets'] if t['type'] == 'binary'}
        wrapper = next(t for t in package['targets'] if t['name'] == 'Forwiroh')
        # The Swift wrapper must depend only on artifacts that will be fetched.
        self.assertEqual({d['target'][0] for d in wrapper['dependencies']}, binaries)
        return binaries

    def test_host_downloads_only_its_artifact(self):
        expected = {'darwin': {'ForwirohApple'}, 'linux': {'ForwirohNative'},
                    'android': {'ForwirohNative'}}.get(sys.platform, set())
        self.assertEqual(self.forwiroh_artifacts(), expected)

    def test_apple_destination(self):
        self.assertEqual(self.forwiroh_artifacts(PMAI_FORWIROH_PLATFORM='apple'),
                         {'ForwirohApple'})

    def test_cross_build_uses_native_artifact_on_any_host(self):
        self.assertEqual(self.forwiroh_artifacts(PMAI_FORWIROH_PLATFORM='native'),
                         {'ForwirohNative'})

    def test_unsupported_destination_downloads_no_artifacts(self):
        self.assertEqual(self.forwiroh_artifacts(PMAI_FORWIROH_PLATFORM='none'), set())

    def test_invalid_destination_does_not_fall_back_to_host(self):
        result = manifest('Vendor/Forwiroh', PMAI_FORWIROH_PLATFORM='typo')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PMAI_FORWIROH_PLATFORM must be apple, native, or none', result.stderr)

    def test_no_mlx_omits_the_entire_inference_graph(self):
        result = manifest('MaiCore', PMAI_NO_MLX='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        package = json.loads(result.stdout)
        local = next(t for t in package['targets'] if t['name'] == 'MaiLocalProviders')
        self.assertEqual(local['dependencies'], [{'byName': ['MaiCore', None]}])
        dependencies = {d['sourceControl'][0]['identity'] for d in package['dependencies']
                        if 'sourceControl' in d}
        self.assertEqual(dependencies, {'swift-crypto', 'swift-nio', 'xylem'})


if __name__ == '__main__':
    unittest.main()
