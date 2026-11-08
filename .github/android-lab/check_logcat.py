#!/usr/bin/env python3
"""Reads the logcat of the Android lab (immuch360-android-lab.yml) and fails on a crash of the app.

The processes of the app are found by the "Start proc" lines of ActivityManager. A crash is, in a line of one of
them: a FATAL EXCEPTION, a CheckJNI abort ("JNI DETECTED ERROR IN APPLICATION"), a fatal signal, or an error of
package:jni (a DartException or an UndeclaredThrowableException thrown back to Java, UseAfterReleaseError,
DoubleReleaseError); and, in any process, the ">>> app <<<" header of a tombstone that debuggerd writes. The exit
status of each test comes from the file the lab script writes (name=status lines): the tests named in --required must
have passed, the others are reported only. The script also says whether ART turned CheckJNI on for the app (its
"-Xcheck:jni" line), and copies the OKHTTP_LAB lines of the tests. Exit status 1 on a crash, a required test that
failed, or an app that never started. A summary goes to GITHUB_STEP_SUMMARY when set.
"""

import argparse
import os
import re
import sys

# 11-09 10:00:00.123  1234  1250 I ActivityManager: Start proc 5432:com.example/u0a190 for ...
LINE = re.compile(r"^\S+\s+\S+\s+(\d+)\s+(\d+)\s+[VDIWEFA]\s+(.*?)\s*: (.*)$")
START = re.compile(r"Start proc (\d+):([^/\s]+)/")
CRASHES = (
    "FATAL EXCEPTION",
    "JNI DETECTED ERROR IN APPLICATION",
    "Fatal signal",
    "DartException",
    "UndeclaredThrowableException",
    "UseAfterReleaseError",
    "DoubleReleaseError",
)


def read_results(path):
    results = {}
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                name, _, status = line.strip().partition("=")
                if name:
                    results[name] = int(status) if status.lstrip("-").isdigit() else 1
    return results


def scan(lines, app):
    """Returns the pids of the app, the crash lines, the CheckJNI lines and the OKHTTP_LAB lines."""
    pids = set()
    crashes = []
    checkjni = []
    lab = []
    tombstone = f">>> {app}"
    for number, raw in enumerate(lines, 1):
        line = raw.rstrip("\n")
        match = LINE.match(line)
        if not match:
            continue
        pid, message = match.group(1), match.group(4)
        start = START.search(message)
        if start and (start.group(2) == app or start.group(2).startswith(app + ":")):
            pids.add(start.group(1))
        if tombstone in message:
            crashes.append((number, line))
            continue
        if pid not in pids:
            continue
        if any(pattern in message for pattern in CRASHES):
            crashes.append((number, line))
        if "Xcheck:jni" in message:
            checkjni.append(line)
        if "OKHTTP_LAB" in message:
            lab.append(message[message.index("OKHTTP_LAB"):])
    return pids, crashes, checkjni, lab


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("logcat")
    parser.add_argument("--app", required=True)
    parser.add_argument("--results")
    parser.add_argument("--required", action="append", default=[])
    parser.add_argument("--out")
    args = parser.parse_args()

    with open(args.logcat, encoding="utf-8", errors="replace") as handle:
        lines = handle.readlines()
    pids, crashes, checkjni, lab = scan(lines, args.app)
    results = read_results(args.results)

    failed = []
    report = [f"Logcat: {len(lines)} lines, processes of {args.app}: {', '.join(sorted(pids)) or 'none'}"]
    if not pids:
        failed.append("the app never started")
    report.append("CheckJNI on for the app: " + ("yes, " + checkjni[0].split(": ", 1)[-1] if checkjni else "not seen"))
    for name, status in results.items():
        required = name in args.required
        report.append(f"Test {name}: {'passed' if status == 0 else f'failed (exit status {status})'}"
                      f"{'' if required else ', reported only'}")
        if required and status != 0:
            failed.append(f"the test {name} failed")
    for name in args.required:
        if name not in results:
            failed.append(f"the test {name} did not run")
    report.extend(lab)
    report.append(f"Crash lines of the app: {len(crashes)}")
    if crashes:
        failed.append("the app crashed")
        context = []
        for number, _ in crashes[:20]:
            context.append(f"--- logcat line {number}")
            context.extend(raw.rstrip("\n") for raw in lines[max(0, number - 3):number + 25])
        if args.out:
            with open(os.path.join(args.out, "crashes.txt"), "w", encoding="utf-8") as handle:
                handle.write("\n".join(context) + "\n")
        report.extend(line for _, line in crashes[:20])
    report.append("Verdict: " + ("failure, " + "; ".join(failed) if failed else "success"))

    print("\n".join(report))
    if not checkjni:
        print("::warning::No -Xcheck:jni line from the app: CheckJNI not confirmed")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("## Android lab\n\n```\n" + "\n".join(report) + "\n```\n")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
