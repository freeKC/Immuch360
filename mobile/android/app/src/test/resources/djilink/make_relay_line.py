#!/usr/bin/env python3
"""The TV's path on the steady stream in the noon test of 26 October 2026, as a fixture of RelayRateControlTest.

Reads the relay section of the phone's export of that test (dji-link-20261026-124410.json, in
/mnt/d/DEV/immuch/dji-p2/capture-2026-10-26-test/ on FreeKC's PC): the per second timeline of the receiver that stayed
(the TCL TV's sixth connection, receiver 6 of p2/noon-test-check-2026-10-26.md), and keeps its seconds on the steady
stream (stream 1, its seconds 19 to 77). For each: the second since it joined, the kB the socket carried, whether the
queue was backlogged (the oldest unit at 100 ms or more, or a drop), and what the phone measured and did in it (the
oldest unit in ms, the units dropped, the rate allowed in kbit/s). In a backlogged second what was carried is what the
path took; in the others the path took at least what it carried, and the test takes the best second it carried in the
session (13.4 Mbit/s, its second 54) as what it could take.

  make_relay_line.py EXPORT.json > relay-line-20261026.csv
"""
import json
import sys


def main():
    export = json.load(open(sys.argv[1]))
    receiver = export['relay']['receivers'][-1]
    columns = receiver['timelineColumns'].split(',')
    print('# make_relay_line.py ' + sys.argv[1].rsplit('/', 1)[-1] + ', receiver ' + str(receiver['number']))
    print('second,kB,backlogged,oldestMs,dropped,bitrateKbps')
    for line in receiver['timeline']:
        row = dict(zip(columns, map(int, line.split(','))))
        if row['stream'] != 1:
            continue
        backlogged = row['oldestMs'] >= 100 or row['dropped'] > 0
        print(f"{row['second']},{row['kB']},{1 if backlogged else 0},{row['oldestMs']},{row['dropped']},"
              f"{row['bitrateKbps']}")


if __name__ == '__main__':
    main()
