#!/usr/bin/env python3
"""Reads a Maestro hierarchy (maestro hierarchy, JSON) and prints a point to tap, "x,y" in points, or nothing.

  find_point.py tile HIERARCHY   a point inside the first tile of a grid grouped by day: 40 points right of the left
                                 edge and 40 points below the first date header (a text with a year, below the top
                                 quarter of the screen), where the first thumbnail starts
  find_point.py face HIERARCHY   the middle of the rightmost small element of the app bar (the face button of a
                                 session without a server has no label): below the status bar, in the top seventh
"""
import json
import re
import sys

BOUNDS = re.compile(r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]')


def nodes(tree):
    out = []

    def walk(n):
        a = n.get('attributes', {})
        m = BOUNDS.match(a.get('bounds') or '')
        if m:
            x0, y0, x1, y1 = map(int, m.groups())
            text = ' '.join(filter(None, (a.get('text'), a.get('accessibilityText'), a.get('title'), a.get('hintText'))))
            out.append((x0, y0, x1, y1, text.strip()))
        for c in n.get('children', []):
            walk(c)
    walk(tree)
    return out


def main():
    mode, path = sys.argv[1], sys.argv[2]
    try:
        items = nodes(json.load(open(path)))
    except Exception:  # noqa: BLE001
        return 0
    if not items:
        return 0
    W = max(x1 for _, _, x1, _, _ in items)
    H = max(y1 for _, _, _, y1, _ in items)
    if mode == 'tile':
        heads = [(y0, y1) for x0, y0, x1, y1, t in items
                 if re.search(r'\b20\d\d\b', t) and y0 > H * 0.25 and (y1 - y0) < 80 and x0 < W * 0.3]
        if heads:
            y0, y1 = min(heads)
            print(f'40,{y1 + 40}')
    elif mode == 'face':
        status = [y1 for x0, y0, x1, y1, t in items if re.search(r'battery|batterie|%|Wi-Fi', t) and y1 < H * 0.06]
        top = max(status) if status else 0
        cands = [((x0 + x1) // 2, (y0 + y1) // 2) for x0, y0, x1, y1, t in items
                 if 20 <= x1 - x0 <= 70 and 20 <= y1 - y0 <= 70 and (x0 + x1) / 2 > W * 0.8
                 and top + 4 < (y0 + y1) / 2 < H * 0.14]
        if cands:
            x, y = max(cands)
            print(f'{x},{y}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
