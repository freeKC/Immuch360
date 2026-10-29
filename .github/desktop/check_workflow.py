#!/usr/bin/env python3
"""Gate of Immuch360 Desktop: the desktop workflow stays pinned and closed to secrets.

.github/workflows/immuch360-desktop.yml builds pull request code on three operating systems. It keeps:

  - runner labels pinned (windows-latest moved to Visual Studio 2026 and macos-latest to macOS 26 while the owner's PC
    builds with the Build Tools 2022; plan 20, 0.1 points 3 and 4);
  - every action pinned to a full commit, with its version in a comment;
  - the Flutter of the Windows job (the Flutter action, mise does not install Flutter on Windows hosts) equal to the one
    of mobile/mise.toml, which every other job uses;
  - an Xcode chosen by its version (XCODE_VERSION), never the newest one a pattern finds on the image, which may be a
    beta or a release candidate added by the weekly image update (design 6.6: pinned toolchains);
  - read-only permissions, no secret, no pull_request_target, and checkouts that do not keep the token, since the
    code it runs comes from pull requests (signing goes to the release workflow, which runs on tags only).

.github/workflows/immuch360-desktop-release.yml is such a workflow: it attaches the packages to the GitHub release of a
desktop pre-release tag, so its release job writes to the repository. With --release the same rules hold, except that
"contents: write" is its one write access (the top may also give no permission at all, "permissions: {}"), and it may
run on the push of desktop-v* tags and by hand (workflow_dispatch) only: no pull request, no branch.

It also signs the Windows files with Azure Artifact Signing (.github/desktop/windows_sign.py), which needs the three
credentials of the signing account, so --release lets in these secrets and no other: AZURE_TENANT_ID, AZURE_CLIENT_ID
and AZURE_CLIENT_SECRET, each as the variable of the same name in the env of a step of the sign-windows job that runs
a command (never a step that uses an action, which would get them too), in a job that does not write. The job that
writes holds no secret, the job that holds the secrets cannot write, and the build it signs ran without them.

stable-diffusion.cpp, the generator of the 360° panoramas (lot P2), is built by the jobs whose names start with
"sdcpp" (sdcpp-windows, sdcpp-linux): each runs on the image of the desktop build of its system (windows-2022 with
Visual Studio 2022, ubuntu-22.04 for its glibc), only when asked or when the lock changed (an "if:" that reads
inputs.sdcpp), and names no artifact Immuch360-Desktop-*, the files a release attaches. With --release, a workflow
with the with_sdcpp input passes it to the build and nothing else ("sdcpp: ${{ inputs.with_sdcpp == true }}"), and its
job that writes the contents never runs with it or with sign_test (an "if:" that negates both): building and signing
stable-diffusion.cpp never touches a release of the app.

.github/workflows/immuch360-webos.yml, which builds the LG webOS app, is held to the rules of the desktop workflow, and
.github/workflows/immuch360-webos-release.yml to those of a release workflow on its own tags: --tag-prefix webos-v.
The Samsung TV app is held to the same: .github/workflows/immuch360-tizen.yml (its package job signs with a throwaway
certificate made in the job, no secret) and .github/workflows/immuch360-tizen-release.yml with --tag-prefix tizen-v.

  check_workflow.py             exit 1 on any finding
  check_workflow.py --release   the release workflow
  check_workflow.py --workflow .github/workflows/immuch360-webos.yml
  check_workflow.py --release --workflow .github/workflows/immuch360-webos-release.yml --tag-prefix webos-v
  check_workflow.py --workflow .github/workflows/immuch360-tizen.yml
  check_workflow.py --release --workflow .github/workflows/immuch360-tizen-release.yml --tag-prefix tizen-v

--workflow and --mise point at other files (the tests use fixtures). The YAML is read line by line on purpose: no
third party module is needed on the runners.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PINNED_RUNNER = re.compile(r'^(ubuntu-\d\d\.\d\d|windows-20\d\d|windows-11-arm|macos-\d+)$')
USES = re.compile(r'^\s*(?:-\s*)?uses:\s*([^\s#]+)\s*(?:#\s*(\S+))?')
PINNED_ACTION = re.compile(r'^[\w.-]+/[\w./-]+@[0-9a-f]{40}$')
MISE_FLUTTER = re.compile(r'^\[tools\."aqua:flutter/flutter"\]\s*\n\s*version\s*=\s*"([^"]+)"', re.MULTILINE)
RELEASE_EVENTS = ('push', 'workflow_dispatch')
# The one job of a release workflow that may hold secrets, and those it may hold (see above)
SIGNING_JOB = 'sign-windows'
SIGNING_SECRETS = ('AZURE_TENANT_ID', 'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET')
SIGNING_LINE = re.compile(r'^(\s+)(' + '|'.join(SIGNING_SECRETS) + r'):\s*\$\{\{\s*secrets\.(\w+)\s*\}\}\s*$')
# The jobs that build stable-diffusion.cpp, by the start of their names, and the image each system builds on
SDCPP_JOB = 'sdcpp'
SDCPP_RUNNERS = {'sdcpp-windows': 'windows-2022', 'sdcpp-linux': 'ubuntu-22.04'}


def release_triggers(workflow: str, tag_prefix: str = 'desktop-v') -> list:
    """The release workflow runs on its tags (desktop-v*) and by hand only"""
    block = re.search(r'^on:[ \t]*\n((?:[ \t]+.*\n|[ \t]*\n)+)', workflow, re.MULTILINE)
    if not block:
        return ['the triggers ("on:") are not a block of events']
    found = []
    for event in re.findall(r'^  ([\w-]+):', block.group(1), re.MULTILINE):
        if event not in RELEASE_EVENTS:
            found.append(f'the release workflow runs on {event}: {tag_prefix}* tags and workflow_dispatch only')
    if re.search(r'^\s+(?:branches|branches-ignore|paths|paths-ignore|tags-ignore)\s*:', block.group(1), re.MULTILINE):
        found.append(f'the release workflow runs on branches or paths: {tag_prefix}* tags and workflow_dispatch only')
    tags = re.search(r'^\s+tags:[ \t]*(\[.*\])?[ \t]*\n((?:\s+-.*\n)*)', block.group(1), re.MULTILINE)
    patterns = []
    if tags:
        patterns = re.findall(r'[\w.*?/-]+', tags.group(1) or '') + re.findall(r'-\s*[\'"]?([^\'"\s]+)', tags.group(2))
    if re.search(r'^  push:', block.group(1), re.MULTILINE) and not patterns:
        found.append('the release workflow runs on push without a tag filter')
    for pattern in patterns:
        if not pattern.startswith(tag_prefix):
            found.append(f'the release workflow runs on the tags {pattern}: {tag_prefix}* only')
    return found


def jobs_of(lines: list) -> list:
    """The job each line belongs to (None before the jobs)"""
    owners, job, inside = [], None, False
    for line in lines:
        if re.match(r'^\S', line):
            inside = bool(re.match(r'^jobs:\s*$', line))
            job = None
        elif inside:
            name = re.match(r'^  ([\w-]+):\s*$', line)
            if name:
                job = name.group(1)
        owners.append(job)
    return owners


def signing_secret(lines: list, owners: list, index: int) -> bool:
    """Line index gives a signing credential to a step of the signing job that runs a command"""
    match = SIGNING_LINE.match(lines[index])
    if not match or owners[index] != SIGNING_JOB or match.group(2) != match.group(3):
        return False
    indent = len(match.group(1))
    # Up to the "env:" of the step, which holds only such variables, then up to the start of the step
    at = index - 1
    while at >= 0 and (not lines[at].strip() or len(lines[at]) - len(lines[at].lstrip()) >= indent):
        at -= 1
    if at < 0 or not re.match(r'^\s+env:\s*$', lines[at]):
        return False
    env_indent = len(lines[at]) - len(lines[at].lstrip())
    start = at
    while start >= 0 and not re.match(r'^\s*- ', lines[start]):
        if re.match(r'^\S|^    \S', lines[start]):
            return False
        start -= 1
    if start < 0 or owners[start] != SIGNING_JOB:
        return False
    step_indent = len(lines[start]) - len(lines[start].lstrip()) + 2
    if env_indent != step_indent:
        return False
    end = index + 1
    while end < len(lines) and (not lines[end].strip() or len(lines[end]) - len(lines[end].lstrip()) >= step_indent):
        end += 1
    step = [lines[start][:step_indent - 2] + '  ' + lines[start][step_indent:]] + lines[start + 1:end]
    return not any(re.match(r'^\s*uses:', line) for line in step)


def signing_job_writes(lines: list, owners: list) -> list:
    return [f'line {number}: the {SIGNING_JOB} job holds secrets and may not write ({line.strip()})'
            for number, (line, owner) in enumerate(zip(lines, owners), 1)
            if owner == SIGNING_JOB and re.match(r'^\s*(?:[\w-]+:\s*write|permissions:\s*write-all)\s*$', line)]


def job_lines(lines: list, owners: list) -> dict:
    """The lines of each job, by its name"""
    jobs = {}
    for line, owner in zip(lines, owners):
        if owner is not None:
            jobs.setdefault(owner, []).append(line)
    return jobs


def job_if(body: list) -> str:
    """The condition of a job (its "if:" at the level of the job), '' without one"""
    for line in body:
        match = re.match(r'^    if:\s*(.+?)\s*$', line)
        if match:
            return match.group(1)
    return ''


def sdcpp_jobs(lines: list, owners: list) -> list:
    """The jobs that build stable-diffusion.cpp: on their images, when asked only, never as a package of the app"""
    found = []
    for job, body in job_lines(lines, owners).items():
        if not job.startswith(SDCPP_JOB):
            continue
        runner = next((re.match(r'^    runs-on:\s*(\S+)', line).group(1).strip('\'"') for line in body
                       if re.match(r'^    runs-on:', line)), None)
        if job not in SDCPP_RUNNERS:
            found.append(f'the job {job} builds stable-diffusion.cpp on no known system: '
                         f'{", ".join(SDCPP_RUNNERS)} only')
        elif runner != SDCPP_RUNNERS[job]:
            found.append(f'the job {job} runs on {runner}: stable-diffusion.cpp builds on {SDCPP_RUNNERS[job]}, the '
                         'image of the desktop build')
        if 'inputs.sdcpp' not in job_if(body):
            found.append(f'the job {job} runs on every event: its "if:" must read inputs.sdcpp (or the lock changed)')
        for line in body:
            name = re.match(r'^\s+name:\s*[\'"]?(Immuch360-Desktop-\S*)', line)
            if name:
                found.append(f'the job {job} uploads {name.group(1)}: the name of a package of the app, which a release '
                             'attaches')
    return found


def release_sdcpp(workflow: str, lines: list, owners: list) -> list:
    """A release workflow that can build stable-diffusion.cpp never gives it to a release of the app"""
    if not re.search(r'^\s+with_sdcpp:\s*$', workflow, re.MULTILINE):
        return []
    found = []
    for job, body in job_lines(lines, owners).items():
        for line in body:
            given = re.match(r'^\s+sdcpp:\s*(.+?)\s*$', line)
            if given and given.group(1) != '${{ inputs.with_sdcpp == true }}':
                found.append(f'the job {job} passes sdcpp: {given.group(1)}; only '
                             '"${{ inputs.with_sdcpp == true }}" (never on a tag)')
        if any(re.match(r'^\s+contents:\s*write\s*$', line) for line in body):
            condition = job_if(body).replace(' ', '')
            for name in ('with_sdcpp', 'sign_test'):
                if f'!inputs.{name}' not in condition:
                    found.append(f'the job {job} writes the contents and may run with {name}: its "if:" must hold '
                                 f'!inputs.{name}')
    return found


def findings(workflow: str, mise: str, release: bool = False, tag_prefix: str = 'desktop-v') -> list:
    found = []
    lines = workflow.splitlines()
    owners = jobs_of(lines)
    for number, line in enumerate(lines, 1):
        runner = re.match(r'^\s*runs-on:\s*(.+?)\s*$', line)
        if runner and not PINNED_RUNNER.match(runner.group(1).strip('\'"')):
            found.append(f'line {number}: runner {runner.group(1)} is not a pinned label')
        uses = USES.match(line)
        if uses and not uses.group(1).startswith('./'):
            if not PINNED_ACTION.match(uses.group(1)):
                found.append(f'line {number}: {uses.group(1)} is not pinned to a full commit')
            elif not uses.group(2):
                found.append(f'line {number}: {uses.group(1)} has no version comment')
        if re.search(r'\$\{\{[^}]*\bsecrets\.', line) or re.match(r'^\s*secrets:\s*inherit', line):
            if release and signing_secret(lines, owners, number - 1):
                continue
            found.append(f'line {number}: a secret in the workflow that builds pull request code'
                         + (f' (a release workflow gives {", ".join(SIGNING_SECRETS)} to the run steps of its '
                            f'{SIGNING_JOB} job only)' if release else ''))
        if re.match(r'^\s*pull_request_target\s*:', line):
            found.append(f'line {number}: pull_request_target runs pull request code with the repository token')

    flutter = MISE_FLUTTER.search(mise)
    if not flutter:
        found.append('mobile/mise.toml: no aqua:flutter/flutter version')
    for number, line in enumerate(lines, 1):
        version = re.match(r'^\s*flutter-version:\s*[\'"]?([^\'"\s#]+)', line)
        if version and flutter and version.group(1) != flutter.group(1):
            found.append(f'line {number}: Flutter {version.group(1)}, mobile/mise.toml has {flutter.group(1)}')

    for number, line in enumerate(lines, 1):
        if re.search(r'Xcode_[^/\s"\']*[*?\[]', line):
            found.append(f'line {number}: an Xcode found by a pattern, not named by XCODE_VERSION')
    if any(re.search(r'\bxcode-select\s+(?:-s|--switch)\b', line) for line in lines) and not any(
        re.match(r'^\s*XCODE_VERSION:\s*[\'"]?\d+(?:\.\d+)+[\'"]?\s*(?:#.*)?$', line) for line in lines
    ):
        found.append('xcode-select without an XCODE_VERSION: the Xcode of the job is not pinned')

    checkouts = sum(1 for line in lines if re.match(r'^\s*(?:-\s*)?uses:\s*actions/checkout@', line))
    kept = sum(1 for line in lines if re.match(r'^\s*persist-credentials:\s*false\s*$', line))
    if checkouts != kept:
        found.append(f'{checkouts} checkouts and {kept} "persist-credentials: false": every checkout drops the token')

    permissions = re.search(r'^permissions:\s*\n((?:[ \t]+.*\n)+)', workflow, re.MULTILINE)
    none = release and re.search(r'^permissions:\s*\{\s*\}\s*$', workflow, re.MULTILINE)
    if not none and (not permissions or not re.search(r'^\s+contents:\s*read\s*$', permissions.group(1), re.MULTILINE)):
        found.append('the workflow does not set "permissions: contents: read" at the top'
                     + (' (or "permissions: {}")' if release else ''))
    for number, line in enumerate(lines, 1):
        if re.match(r'^\s*(?:[\w-]+:\s*write|permissions:\s*write-all)\s*$', line):
            if release and re.match(r'^\s*contents:\s*write\s*$', line):
                continue
            found.append(f'line {number}: a write access ({line.strip()})')
    found += sdcpp_jobs(lines, owners)
    if release:
        found += signing_job_writes(lines, owners)
        found += release_triggers(workflow, tag_prefix)
        found += release_sdcpp(workflow, lines, owners)
    return found


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--workflow', type=pathlib.Path)
    parser.add_argument('--mise', type=pathlib.Path, default=ROOT / 'mobile' / 'mise.toml')
    parser.add_argument('--release', action='store_true', help='the release workflow, which may write the contents')
    parser.add_argument('--tag-prefix', default='desktop-v', help='the tags a release workflow runs on (desktop-v)')
    args = parser.parse_args(argv)
    workflow = args.workflow or ROOT / '.github' / 'workflows' / (
        'immuch360-desktop-release.yml' if args.release else 'immuch360-desktop.yml')

    found = findings(workflow.read_text(encoding='utf-8'), args.mise.read_text(encoding='utf-8'), args.release, args.tag_prefix)
    for line in found:
        print(f'{workflow.name}: {line}')
    if found:
        return 1
    if args.release:
        text = workflow.read_text(encoding='utf-8')
        secrets = (f'no secret but the signing credentials in the run steps of {SIGNING_JOB}'
                   if re.search(r'\bsecrets\.', text) else 'no secret')
        print(f'{workflow.name}: runners and actions pinned, {secrets}, {args.tag_prefix}* tags and workflow_dispatch '
              'only, contents its only write access')
    else:
        print(f'{workflow.name}: runners, actions and Xcode pinned, Flutter as in mise.toml, read-only, no secret')
    return 0


if __name__ == '__main__':
    sys.exit(main())
