#!/usr/bin/env python3
"""The verdict of the end to end splat scene of the linux job (lot L03 of the desktop parity plan, 21 November 2026).

splat_probe (mobile/test/desktop/ai/tools/splat_probe.dart) prints one JSON line per event while the engine of the app
makes a scene with the real COLMAP and Brush. This script reads that log and says what it proves:

  - the card: what the gate of the app said of the cards the probe of the build found (its refusal, when the software
    device of Vulkan was taken by --software-card), and the card Brush was given;
  - one scene written ("done"): its views placed (--views, two may be left out), gaussians in it, the size of the
    .spz the same on disk as the engine said, and the probe of the app reading its head as a splat (SplatHead), not
    a refusal.

  splat_e2e_check.py LOG --views N

Exit codes: 0 good, 1 a check failed, 2 bad arguments. Only the Python standard library is used.
"""
from __future__ import annotations

import argparse
import json
import os
import sys


def check(events: list, views: int) -> list:
    problems = []
    done = [event for event in events if event.get('event') == 'done']
    if len(done) != 1:
        last = events[-1] if events else 'no event'
        return [f'{len(done)} splat scenes written, 1 expected; the last event: {last}']
    scene = done[0]
    placed = scene.get('placed') or 0
    if scene.get('images') != views or placed < views - 2:
        problems.append(f"{placed} of {scene.get('images')} views placed, at least {views - 2} of {views} expected")
    elif placed < views:
        print(f'::warning::{placed} of {views} views placed')
    if not scene.get('gaussians') or scene['gaussians'] <= 0:
        problems.append(f"{scene.get('gaussians')} gaussians in the scene")
    path = scene.get('spz')
    if not path or not os.path.isfile(path):
        problems.append(f'no .spz at {path}')
    elif os.path.getsize(path) != scene.get('spzBytes'):
        problems.append(f"the .spz holds {os.path.getsize(path)} bytes, the engine wrote {scene.get('spzBytes')}")
    head = str(scene.get('spzHead', ''))
    if not head.startswith('SplatHead('):
        problems.append(f'the probe of the app read {head}')
    return problems


def summary(events: list) -> list:
    lines = []
    for event in events:
        if event.get('event') == 'gate':
            lines.append(f"the gate: {event.get('refusal')} for the cards {event.get('cards')}; taken by "
                         f"--software-card: {event.get('softwareCard')}")
        elif event.get('event') == 'card':
            lines.append(f"Brush on {event.get('name')} ({event.get('kind')})")
        elif event.get('event') == 'done':
            lines.append(f"splat scene: {event.get('gaussians')} gaussians, {event.get('spzBytes')} bytes, "
                         f"{event.get('placed')} of {event.get('images')} views placed, {event.get('spzHead')}, "
                         f"seconds {event.get('seconds')}")
        elif event.get('event') == 'failed':
            lines.append(f"failed: {event.get('code')}: {event.get('message')}")
    return lines


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('log')
    parser.add_argument('--views', type=int, required=True)
    args = parser.parse_args(argv)
    try:
        with open(args.log, encoding='utf-8', errors='replace') as log:
            events = [json.loads(line) for line in log if line.startswith('{"event"')]
    except (OSError, ValueError) as error:
        print(f'::error::{args.log}: {error}')
        return 2
    for line in summary(events):
        print(line)
    problems = check(events, args.views)
    for problem in problems:
        print(f'::error::{problem}')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
