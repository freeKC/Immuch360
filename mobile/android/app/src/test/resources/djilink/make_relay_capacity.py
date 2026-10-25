#!/usr/bin/env python3
"""The capacity of the Wi-Fi toward the TV in the flights of 25 October 2026, as a fixture of RelayRateControlTest.

Reads the relay section of the phone's last export of that session (dji-link-20261025-154528.json, in
/mnt/d/DEV/immuch/dji-p2/capture-2026-10-25-flight/ on FreeKC's PC): the per second timeline of its two receivers (the
TV before and after its reconnection), placed on the drone's stream time as p2/relay-bandwidth-2026-10-25.md, 2.1 and
2.2 place them (receiver 1 joined at 9.5 s, receiver 2 at 250.6 s), and keeps the seconds at 60 pictures a second (the
two flights). For each: the stream time at its end, the kB the socket carried, and whether the queue was backlogged
(the oldest unit at 100 ms or more, or a drop). In a backlogged second what was carried is what the path took; in the
others the path took at least the drone's 17.9 Mbit/s.

  make_relay_capacity.py EXPORT.json > relay-capacity-20261025.csv
"""
import json
import sys

# The drone's picture rate by stream time (p2/relay-bandwidth-2026-10-25.md, 2.2): take off and landing restarts
SEGMENTS = [(0, 39.88, 30), (39.88, 152.23, 60), (152.23, 193.0, 30), (193.0, 216.66, 0), (216.66, 222.66, 30),
            (222.66, 360.2, 60), (360.2, 431.6, 30), (431.6, 1e9, 0)]
JOINED = [9.5, 250.6]


def mode(t0, t1):
    best, length = None, 0
    for a, b, rate in SEGMENTS:
        overlap = min(b, t1) - max(a, t0)
        if overlap > length:
            best, length = rate, overlap
    return best


def main():
    export = json.load(open(sys.argv[1]))
    receivers = export['relay']['receivers']
    print('# make_relay_capacity.py ' + sys.argv[1].rsplit('/', 1)[-1])
    print('streamS,kB,backlogged')
    for receiver, joined in zip(receivers, JOINED):
        columns = receiver['timelineColumns'].split(',')
        for line in receiver['timeline']:
            row = dict(zip(columns, map(int, line.split(','))))
            end = joined + row['second']
            if mode(end - 1, end) != 60:
                continue
            backlogged = row['oldestMs'] >= 100 or row['dropped'] > 0
            print(f"{end:.1f},{row['kB']},{1 if backlogged else 0}")


if __name__ == '__main__':
    main()
