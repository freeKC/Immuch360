#!/usr/bin/env python3
"""Prints the newest available iOS simulator runtime and the first device type of TYPES ("A|B", by name) it supports:
"<runtime identifier> <device type identifier>". Used by run_captures.sh (macOS bash 3.2 cannot hold this inline)."""
import json
import os
import subprocess

runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '-j']))['runtimes']
ios = [r for r in runtimes if r.get('platform') == 'iOS' and r.get('isAvailable')]
ios.sort(key=lambda r: [int(x) for x in r['version'].split('.')])
names = os.environ['TYPES'].split('|')
for rt in reversed(ios):
    supported = dict((d['name'], d['identifier']) for d in rt.get('supportedDeviceTypes', []))
    for name in names:
        if name in supported:
            print(rt['identifier'], supported[name])
            raise SystemExit(0)
raise SystemExit('no runtime supports ' + os.environ['TYPES'])
