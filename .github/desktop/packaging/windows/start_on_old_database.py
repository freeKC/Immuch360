#!/usr/bin/env python3
"""Starts the Windows build on a database an older build left behind, and checks that the app gets past it.

The profile of the release build (%APPDATA%/com.aprogsys/Immuch360 Desktop) gets an immich.sqlite made from the
fixture: the tables and indexes of schema 35 at user_version 34, as a build at schema 34 leaves a database that a
build at 35 had migrated. Desktop builds 6 to 8 failed every start on it ("duplicate column name: group_date").

The app starts with the self check (IMMUCH360_SELF_CHECK, lib/desktop/window/self_check.dart). It passes when the
database reaches user_version 35 with group_date once in each asset table and the app still runs --hold seconds
later; the report of the self check, when the runner lets the window come up, is kept next to the output of the app
in --out. Exit 1 otherwise, with the end of that output.

Refuses to run when the profile already holds a database: on a PC it would be the owner's.

  start_on_old_database.py --exe "dist/Immuch360 Desktop/immuch360.exe" --fixture <sql> --out <folder>
"""
from __future__ import annotations

import argparse
import os
import pathlib
import sqlite3
import subprocess
import sys
import time

TABLES = ('remote_asset_entity', 'local_asset_entity')


def profile_folder() -> pathlib.Path:
    appdata = os.environ.get('APPDATA')
    if not appdata:
        sys.exit('::error::APPDATA is not set: this check runs on Windows')
    return pathlib.Path(appdata) / 'com.aprogsys' / 'Immuch360 Desktop'


def read_state(database: pathlib.Path) -> tuple[int, list[int]] | str:
    """user_version and the number of group_date columns of each asset table, or the error of the read"""
    try:
        connection = sqlite3.connect(f'{database.as_uri()}?mode=ro', uri=True, timeout=5)
        try:
            version = connection.execute('PRAGMA user_version').fetchone()[0]
            counts = [
                sum(1 for row in connection.execute(f'PRAGMA table_info({table})') if row[1] == 'group_date')
                for table in TABLES
            ]
        finally:
            connection.close()
        return version, counts
    except sqlite3.Error as error:
        return str(error)


def tail(path: pathlib.Path, lines: int = 60) -> str:
    try:
        return '\n'.join(path.read_text(encoding='utf-8', errors='replace').splitlines()[-lines:])
    except OSError:
        return ''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--exe', required=True, type=pathlib.Path)
    parser.add_argument('--fixture', required=True, type=pathlib.Path)
    parser.add_argument('--out', required=True, type=pathlib.Path)
    parser.add_argument('--timeout', type=int, default=180, help='seconds for the database to reach 35')
    parser.add_argument('--hold', type=int, default=30, help='seconds the app must keep running afterwards')
    args = parser.parse_args()

    profile = profile_folder()
    database = profile / 'immich.sqlite'
    if database.exists():
        sys.exit(f'::error::{database} exists already: not a clean profile, nothing done')
    profile.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(database)
    connection.executescript(args.fixture.read_text(encoding='utf-8'))
    connection.execute('PRAGMA journal_mode = WAL')
    connection.close()
    before = read_state(database)
    print(f'before the start: {before}')
    if before != (34, [1, 1]):
        sys.exit('::error::the fixture did not give a database at user_version 34 with group_date')

    args.out.mkdir(parents=True, exist_ok=True)
    report = (args.out / 'report.json').resolve()
    log_path = args.out / 'app.log'
    env = dict(os.environ, IMMUCH360_SELF_CHECK=str(report))
    exe = args.exe.resolve()
    failure = None
    with open(log_path, 'wb') as log:
        app = subprocess.Popen([str(exe)], cwd=exe.parent, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            started = time.monotonic()
            state = before
            while True:
                if app.poll() is not None:
                    failure = f'the app ended by itself (exit {app.returncode}) with the database at {state}'
                    break
                state = read_state(database)
                if state == (35, [1, 1]):
                    print(f'database at 35 after {time.monotonic() - started:.0f} s')
                    break
                if time.monotonic() - started > args.timeout:
                    failure = f'the database is still at {state} after {args.timeout} s'
                    break
                time.sleep(1)
            if failure is None:
                held = time.monotonic()
                while time.monotonic() - held < args.hold:
                    if app.poll() is not None:
                        failure = f'the app ended by itself (exit {app.returncode}) after the migration'
                        break
                    time.sleep(1)
            if failure is None:
                print(f'the app still runs {args.hold} s later')
                print('self check report: ' + ('written' if report.exists() else 'not written (no window on the runner?)'))
        finally:
            if app.poll() is None:
                app.terminate()
                try:
                    app.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    app.kill()
                    app.wait(timeout=15)

    print(f'after: {read_state(database)}')
    print('--- end of the output of the app')
    print(tail(log_path))
    if failure is not None:
        print(f'::error::{failure}')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
