#!/usr/bin/env python3
"""Reads the logcat of the Android lab (immuch360-android-lab.yml) and fails on a crash, an ANR or a death of the app.

The processes of the app are found by the "Start proc" lines of ActivityManager. A crash is, in a line of one of
them: a FATAL EXCEPTION, a CheckJNI abort ("JNI DETECTED ERROR IN APPLICATION"), a fatal signal, a line of the fatal
priority (F, an abort of the Flutter engine among them), or an error of package:jni (a DartException or an
UndeclaredThrowableException thrown back to Java, UseAfterReleaseError, DoubleReleaseError); and, in any process, the
">>> app <<<" header of a tombstone that debuggerd writes. An ANR is the "ANR in <app>" line of ActivityManager. A
death is a process of the app that died ("Process <app> (pid N) has died"), that the low memory killer ended, or that
ActivityManager killed for any other reason than the force stop of the test tool at the end of each test file.

The lab tests write "LAB_SCENARIO start <name>" and then "LAB_SCENARIO passed <name>" (or "failed") to logcat: each
crash, ANR or death goes to the scenario that was running, and a scenario named in --scenarios fails when it has one,
when it did not pass, or when it never started. The exit status of each test file comes from the file the lab script
writes (name=status lines): the files named in --required must have passed, the others are reported only. The script
also says whether ART turned CheckJNI on for the app (its "-Xcheck:jni" line), copies the lines of the tests
(OKHTTP_LAB, LAB_SCENARIO and the lines the lab tests log) and the lines of the native parts they check
(BackgroundWorker, BackgroundEngineLock, AppHealth, RemoteImages, NativeImageDecode) to highlights.txt. Exit status 1
on a crash, an ANR or a death, a required test or scenario that failed, or an app that never started. A summary goes
to GITHUB_STEP_SUMMARY when set.
"""

import argparse
import os
import re
import sys

# 11-09 10:00:00.123  1234  1250 I ActivityManager: Start proc 5432:com.example/u0a190 for ...
LINE = re.compile(r"^\S+\s+\S+\s+(\d+)\s+(\d+)\s+([VDIWEFA])\s+(.*?)\s*: (.*)$")
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
SCENARIO = re.compile(r"LAB_SCENARIO (start|passed|failed) (\S+)")
HIGHLIGHT_TAGS = ("BackgroundWorker", "BackgroundEngineLock", "AppHealth", "RemoteImages", "NativeImageDecode")
HIGHLIGHT_TEXT = ("OKHTTP_LAB", "LAB_SCENARIO", "LAB_HOST", "Native decode of", "Original of", "Thumbnail of",
                  "Upload:", "Background run ended", "Cancelled run", "Web socket:", "Paths the fake server",
                  "Redirect report", "Saved lab_")


def read_results(path):
    results = {}
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                name, _, status = line.strip().partition("=")
                if name:
                    results[name] = int(status) if status.lstrip("-").isdigit() else 1
    return results


def is_app(process, app):
    return process == app or process.startswith(app + ":")


def scan(lines, app):
    """The pids of the app, the problem lines (number, kind, line, scenario), the CheckJNI lines, the highlights and
    the scenarios in the order they started, each with its state"""
    pids = set()
    problems = []
    checkjni = []
    highlights = []
    scenarios = {}
    current = None
    stopped = set()
    tombstone = f">>> {app}"
    killing = re.compile(r"Killing (\d+):([^/\s]+)/\S+ \(adj -?\d+\): (.*)$")
    died = re.compile(r"Process (\S+) \(pid (\d+)\) has died")
    lmk = re.compile(r"Kill '([^']+)' \((\d+)\)")
    for number, raw in enumerate(lines, 1):
        line = raw.rstrip("\n")
        match = LINE.match(line)
        if not match:
            continue
        pid, level, tag, message = match.group(1), match.group(3), match.group(4), match.group(5)

        def problem(kind):
            problems.append((number, kind, line, current))

        start = START.search(message)
        if start and is_app(start.group(2), app):
            pids.add(start.group(1))
            # A new process of the app runs no scenario until its test says so
            current = None
        if tombstone in message:
            problem("tombstone")
            continue
        if tag == "ActivityManager" and f"ANR in {app}" in message:
            problem("ANR")
        kill = killing.search(message) if tag == "ActivityManager" else None
        if kill and is_app(kill.group(2), app):
            if kill.group(3).startswith(f"stop {app}"):
                stopped.add(kill.group(1))
            else:
                problem("killed")
        death = died.search(message) if tag == "ActivityManager" else None
        if death and is_app(death.group(1), app) and death.group(2) not in stopped:
            problem("died")
        killed = lmk.search(message) if tag == "lowmemorykiller" else None
        if killed and is_app(killed.group(1), app):
            problem("low memory kill")
        if pid not in pids:
            continue
        if any(pattern in message for pattern in CRASHES) or level == "F":
            problem("crash")
        if "Xcheck:jni" in message:
            checkjni.append(line)
        if tag in HIGHLIGHT_TAGS or any(text in message for text in HIGHLIGHT_TEXT):
            highlights.append(line)
        marker = SCENARIO.search(message)
        if marker:
            event, name = marker.groups()
            if event == "start":
                scenarios[name] = {"state": "started", "problems": 0}
                current = name
            elif name in scenarios:
                scenarios[name]["state"] = event
                current = None
    for _, _, _, scenario in problems:
        if scenario in scenarios:
            scenarios[scenario]["problems"] += 1
    return pids, problems, checkjni, highlights, scenarios


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("logcat")
    parser.add_argument("--app", required=True)
    parser.add_argument("--results")
    parser.add_argument("--required", action="append", default=[])
    parser.add_argument("--scenarios", default="", help="the scenarios that must pass, separated by commas")
    parser.add_argument("--out")
    args = parser.parse_args()

    with open(args.logcat, encoding="utf-8", errors="replace") as handle:
        lines = handle.readlines()
    pids, problems, checkjni, highlights, scenarios = scan(lines, args.app)
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
    for name in [n for n in args.scenarios.split(",") if n]:
        scenario = scenarios.get(name)
        if scenario is None:
            report.append(f"Scenario {name}: never started")
            failed.append(f"the scenario {name} never started")
            continue
        report.append(f"Scenario {name}: {scenario['state']}, {scenario['problems']} crash, ANR or death lines")
        if scenario["state"] != "passed" or scenario["problems"]:
            failed.append(f"the scenario {name} {'failed' if scenario['state'] != 'passed' else 'had a crash'}")
    report.extend(line.split(": ", 1)[-1] for line in highlights if "OKHTTP_LAB" in line)
    report.append(f"Crash, ANR and death lines of the app: {len(problems)}")
    if problems:
        failed.append("the app crashed, stopped answering or died")
        context = []
        for number, kind, _, scenario in problems[:20]:
            context.append(f"--- logcat line {number}: {kind}, scenario {scenario or 'none'}")
            context.extend(raw.rstrip("\n") for raw in lines[max(0, number - 3):number + 25])
        if args.out:
            with open(os.path.join(args.out, "crashes.txt"), "w", encoding="utf-8") as handle:
                handle.write("\n".join(context) + "\n")
        report.extend(f"{kind} ({scenario or 'no scenario'}): {line}" for _, kind, line, scenario in problems[:20])
    if args.out:
        with open(os.path.join(args.out, "highlights.txt"), "w", encoding="utf-8") as handle:
            handle.write("\n".join(highlights) + "\n")
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
