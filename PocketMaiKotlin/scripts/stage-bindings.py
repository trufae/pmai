#!/usr/bin/env python3
"""Stage JExtract output; never maintain a handwritten Java/JNI surface."""
from pathlib import Path
import shutil

root = Path(__file__).resolve().parent.parent
sources = list((root / '.build/plugins/outputs').glob(
    '*/MaiKotlinBridge/destination/JExtractSwiftPlugin/src/generated/java'))
if len(sources) != 1:
    raise SystemExit(f'Expected one JExtract output directory, got {sources}')
destination = root / 'bridge/build/generated/java'
if destination.exists():
    shutil.rmtree(destination)
shutil.copytree(sources[0], destination)
