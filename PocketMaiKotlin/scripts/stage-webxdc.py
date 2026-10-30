#!/usr/bin/env python3
"""Reuse MaiCore's public PocketMai JS API, adapting only its host transport."""
from pathlib import Path

root = Path(__file__).resolve().parent.parent
source = (root.parent / 'MaiCore/Sources/MaiCore/WebXDCPocketMaiBridge.swift').read_text()
marker = 'enum WebXDCPocketMaiBridge {'
script = source.split(marker, 1)[1].split('static let script = #"""', 1)[1].split('"""#', 1)[0]
script = script.replace("location.protocol !== 'xdc:'", "location.protocol !== 'https:'")
script = script.replace('window.webkit.messageHandlers.pocketmai.postMessage(message)',
                        'window.PocketMaiHost.postMessage(JSON.stringify({type: "pocketmai", ...message}))')
destination = root / 'app/build/generated/webxdc'
destination.mkdir(parents=True, exist_ok=True)
(destination / 'pocketmai.js').write_text(script)
