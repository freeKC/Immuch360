#!/usr/bin/env python3
"""The weekly dry merge of upstream Immich into Immuch360 (plan 23 section 4, decision 12 of 10 November 2026).

Merges the release branch of the fork with upstream main and with the newest upstream release tag (vX.Y.Z, no rc),
in memory, the way the sync study of 10 November 2026 did by hand (store/m2/upstream-sync-2026-11-10/merge-dry-run.md),
and writes what a sync would meet, for each of the two:

  - the commits behind (and those that touch mobile/), our commits since the merge base, the files upstream changed;
  - the files in conflict, their hunks and the lines inside the markers (ours plus theirs, in the default conflict
    style, as the study counted them), by top level directory and by mobile/ subdirectory;
  - every conflicted file with its class and verdict, the semantic ones first (the heuristic below);
  - the files both sides changed that merged cleanly: no conflict, but they still have to compile and pass the tests;
  - the upstream mobile fixes since the merge base (titles "fix:" or "fix(scope):"), each marked when its patch is
    already in ours (picked: the patch id of its mobile/ part, git log --cherry-mark);
  - the desktop checklist of upstream_sync_report.py for the files upstream changed (it reads the checked out tree).

Nothing is written to the repository: git merge-tree --write-tree writes its blobs and trees into a temporary object
directory (GIT_OBJECT_DIRECTORY, with the objects of the repository as an alternate), deleted at the end, and no ref
is created or moved. The upstream refs are fetched beforehand (the workflow does it: upstream main to
refs/remotes/upstream/main and its v* tags to refs/upstream-tags/, apart from the fork's own v* tags, which a
strict vX.Y.Z match leaves out anyway: v3.4.0-45 is not a release tag of Immich).

The heuristic, for each conflicted file:
  1. By path, the files that are not source code are mechanical: translations (i18n/, readme_i18n/, l10n/, .arb),
     generated code (.g.dart, .freezed.dart, mobile/openapi/, drift_schemas/), lock files, documentation (.md, docs/),
     tests (test/, integration_test/, e2e/, *_test.dart, *.spec.ts), and configuration or data (any other extension:
     .json, .yaml, .plist, .gradle, .toml, .entitlements). They are a key union, a regeneration, or one side or both.
  2. A source file (.dart .kt .java .swift .m .h .c .cpp .rs .ts .js .svelte .py .go .sh .sql) is merged a second
     time with the base inside the markers (diff3), and each hunk is read:
       imports   every line of every side is an import, export, part, include, use, package or comment line, or blank
       one side  ours or theirs is empty: a removal against an edit, keep it or drop it
       union     every base line is kept on both sides, in order: both sides only added lines, keep both in order
       rewrite   both sides changed the same base lines
     The file is semantic when one of its hunks is a rewrite. A source file in conflict without markers (modify/delete,
     rename/delete, binary) is semantic too: the change of one side has to be carried over or dropped by hand.
  3. Unions in source files are listed apart: a union of code can still be a semantic merge in disguise.
  Checked against the verdicts made by hand for upstream main c73e7c264e on 10 November 2026: 14 of the 15 semantic
  files flagged, plus 2 the study called mechanical (database.dart, platform.provider.dart); the one missed,
  timeline.widget.dart (our zoom levels next to upstream's smooth scrubbing), is in the list of unions.

  upstream_dry_merge.py [--ours HEAD] [--main upstream/main] [--tags refs/upstream-tags/ | --tag REF]
                        [--report FILE] [--json FILE] [--summary FILE] [--repo DIR]

--report writes the Markdown report, --json the numbers, --summary appends the report ($GITHUB_STEP_SUMMARY in CI).
Exit 0 whatever the conflicts; 2 when git fails or a ref is missing; 1 on an error of the script itself (a traceback).
The parsing has doctests: python3 -B -m doctest .github/desktop/upstream_dry_merge.py
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
# No __pycache__ folder in the repository for the module below
sys.dont_write_bytecode = True
import upstream_sync_report  # noqa: E402  (same folder; the path is set just above)

RELEASE_TAG = re.compile(r'^v(\d+)\.(\d+)\.(\d+)$')
FIX_TITLE = re.compile(r'^(?:fix|hotfix|bugfix)(?:\([^)]*\))?!?:', re.IGNORECASE)

I18N = re.compile(r'^i18n/|^readme_i18n/|(^|/)l10n/|\.arb$')
GENERATED = re.compile(r'\.(?:g|freezed|gr|mocks)\.dart$|\.g\.(?:kt|swift)$|^mobile/openapi/|(^|/)drift_schemas/')
LOCK = re.compile(r'\.lock$|(^|/)(?:pnpm-lock\.yaml|package-lock\.json)$')
DOCS = re.compile(r'\.(?:md|mdx|txt|rst)$|^docs/')
TEST = re.compile(r'(^|/)(?:test|tests|integration_test|__tests__|e2e)/|_test\.(?:dart|go|py)$'
                  r'|\.(?:spec|test)\.[jt]sx?$|(^|/)test_[^/]*\.py$')
SOURCE = re.compile(r'\.(?:dart|kt|java|swift|m|mm|h|hpp|c|cc|cpp|rs|ts|tsx|js|mjs|cjs|svelte|py|go|sh|sql)$')
# A line that only brings names in, or says nothing: imports, exports of a file, parts, includes, Rust and Kotlin
# use and package lines, comments, blank lines. "#" opens a comment in Python and shell, not a Rust attribute "#[".
IMPORT_LINE = re.compile(
    r"""^\s*(?:$|//|/\*|\*|\#(?![\[!])|import\b|@import\b|part\b|library\b|package\s|use\s+[\w:]"""
    r"""|export\s+['"]|export\s+\*|export\s*\{[^}]*\}\s*from\b|from\s+[\w.]+\s+import\b)""")
MARKERS = ('<<<<<<<', '|||||||', '=======', '>>>>>>>')


class GitError(Exception):
    pass


class Git:
    """Read-only git in [repo]; merge-tree objects go to [objects], a temporary object directory."""

    def __init__(self, repo: pathlib.Path, objects: str | None = None):
        self.repo = repo
        self.env = dict(os.environ)
        if objects:
            common = self.run('rev-parse', '--path-format=absolute', '--git-common-dir').strip()
            self.env['GIT_OBJECT_DIRECTORY'] = objects
            self.env['GIT_ALTERNATE_OBJECT_DIRECTORIES'] = os.path.join(common, 'objects')

    def run(self, *args: str, ok: tuple = (0,), style: str | None = None) -> str:
        config = ['-c', f'merge.conflictStyle={style}'] if style else []
        result = subprocess.run(['git', '-C', str(self.repo), '-c', 'core.quotePath=false', *config, *args],
                                capture_output=True, env=self.env)
        if result.returncode not in ok:
            raise GitError(f'git {" ".join(args)}: exit {result.returncode}: '
                           f'{result.stderr.decode("utf-8", "replace").strip()}')
        self.code = result.returncode
        return result.stdout.decode('utf-8', 'replace')

    def commit(self, ref: str) -> str:
        return self.run('rev-parse', '--verify', '--quiet', f'{ref}^{{commit}}', ok=(0, 1)).strip()

    def names(self, command: str, *args: str) -> list:
        return [name for name in self.run(command, '-z', *args).split('\0') if name]


def parse_merge_tree(output: str) -> tuple:
    """The tree, the conflicted paths with their stages, and the messages (paths, type) of git merge-tree
    --write-tree --messages -z.

    >>> fields = ['T', '100644 a 1\\tx.dart', '100644 b 2\\tx.dart', '100644 c 3\\tx.dart', '',
    ...           '1', 'x.dart', 'Auto-merging', 'Auto-merging x.dart\\n',
    ...           '1', 'x.dart', 'CONFLICT (contents)', 'CONFLICT (content): Merge conflict in x.dart\\n', '']
    >>> parse_merge_tree(chr(0).join(fields))
    ('T', {'x.dart': [1, 2, 3]}, [(['x.dart'], 'Auto-merging'), (['x.dart'], 'CONFLICT (contents)')])
    >>> parse_merge_tree(chr(0).join(['T', '', '']))
    ('T', {}, [])
    >>> parse_merge_tree(chr(0).join(['T', '100644 a 1\\ty']))
    Traceback (most recent call last):
    ...
    ValueError: git merge-tree output without the end of its conflicted files
    """
    fields = output.split('\0')
    tree = fields[0]
    try:
        end = fields.index('', 1)
    except ValueError:
        raise ValueError('git merge-tree output without the end of its conflicted files') from None
    conflicted = {}
    for entry in fields[1:end]:
        meta, path = entry.split('\t', 1)
        conflicted.setdefault(path, []).append(int(meta.split(' ')[2]))
    messages = []
    rest = fields[end + 1:]
    index = 0
    while index < len(rest) and rest[index]:
        count = int(rest[index])
        paths = rest[index + 1:index + 1 + count]
        messages.append((paths, rest[index + 1 + count]))
        index += count + 3
    return tree, conflicted, messages


def hunks(text: str) -> list:
    """The conflict hunks of a merged file: the lines of ours, of the base (diff3 style only) and of theirs.

    >>> text = ('a\\n<<<<<<< o\\nb\\n||||||| base\\nc\\n=======\\nd\\ne\\n>>>>>>> t\\nf\\n'
    ...         '<<<<<<< o\\n=======\\ng\\n>>>>>>> t')
    >>> hunks(text)
    [{'ours': ['b'], 'base': ['c'], 'theirs': ['d', 'e']}, {'ours': [], 'base': [], 'theirs': ['g']}]
    >>> hunks('no conflict\\n======= a heading underline\\n')
    []
    """
    found = []
    side = None
    current = {}
    for line in text.split('\n'):
        bare = line.rstrip('\r')
        marker = bare[:7] if bare[:7] in MARKERS and bare[7:8] in ('', ' ') else None
        if marker == '<<<<<<<':
            current = {'ours': [], 'base': [], 'theirs': []}
            side = 'ours'
        elif marker == '|||||||' and side == 'ours':
            side = 'base'
        elif marker == '=======' and side in ('ours', 'base'):
            side = 'theirs'
        elif marker == '>>>>>>>' and side == 'theirs':
            found.append(current)
            side = None
        elif side:
            current[side].append(line)
    return found


def kept_in_order(lines: list, other: list) -> bool:
    """Whether [lines] appear in [other] in the same order, others in between.

    >>> kept_in_order(['a', 'c'], ['a', 'b', 'c']), kept_in_order(['c', 'a'], ['a', 'b', 'c'])
    (True, False)
    """
    rest = iter(other)
    return all(any(line == candidate for candidate in rest) for line in lines)


def hunk_kind(hunk: dict) -> str:
    """imports, one side, union or rewrite (see the head of the file), from a diff3 hunk.

    >>> hunk_kind({'ours': ["import 'a.dart';", ''], 'base': [], 'theirs': ["import 'b.dart';"]})
    'imports'
    >>> hunk_kind({'ours': ['x = 1;'], 'base': ['x = 0;'], 'theirs': ['  ']})
    'one side'
    >>> hunk_kind({'ours': ['a();', 'b();'], 'base': ['a();'], 'theirs': ['    a();', 'c();']})
    'union'
    >>> hunk_kind({'ours': ['x = 1;'], 'base': ['x = 0;'], 'theirs': ['x = 2;']})
    'rewrite'
    >>> hunk_kind({'ours': ['#[cfg(test)]'], 'base': [], 'theirs': ['use std::io;']})
    'union'
    """
    ours, base, theirs = ([line.strip() for line in hunk[side] if line.strip()] for side in ('ours', 'base', 'theirs'))
    if all(IMPORT_LINE.match(line) for line in ours + base + theirs):
        return 'imports'
    if not ours or not theirs:
        return 'one side'
    if kept_in_order(base, ours) and kept_in_order(base, theirs):
        return 'union'
    return 'rewrite'


def path_class(path: str) -> str:
    """The class of a path for the heuristic: i18n, generated, lock, docs, test, source or config.

    >>> [path_class(p) for p in ('i18n/ja.json', 'mobile/lib/a.g.dart', 'mobile/pubspec.lock', 'README.md',
    ...  'mobile/test/a_test.dart', 'mobile/lib/main.dart', 'mobile/ios/Runner/Info.plist', 'docs/src/a.tsx')]
    ['i18n', 'generated', 'lock', 'docs', 'test', 'source', 'config', 'docs']
    """
    for name, pattern in (('i18n', I18N), ('generated', GENERATED), ('lock', LOCK), ('docs', DOCS), ('test', TEST)):
        if pattern.search(path):
            return name
    return 'source' if SOURCE.search(path) else 'config'


def verdict(path: str, kinds: list) -> str:
    """semantic or mechanical, from the class of [path] and the kinds of its diff3 hunks.

    >>> verdict('mobile/lib/a.dart', ['imports', 'rewrite']), verdict('mobile/lib/a.dart', ['union', 'one side'])
    ('semantic', 'mechanical')
    >>> verdict('mobile/lib/gone.dart', []), verdict('.github/ISSUE_TEMPLATE/bug_report.yaml', [])
    ('semantic', 'mechanical')
    >>> verdict('i18n/fr.json', ['rewrite']), verdict('mobile/test/a_test.dart', ['rewrite'])
    ('mechanical', 'mechanical')
    """
    if path_class(path) != 'source':
        return 'mechanical'
    return 'semantic' if not kinds or 'rewrite' in kinds else 'mechanical'


def top_dir(path: str) -> str:
    """The top level directory of a path, (root) for a file at the root.

    >>> top_dir('mobile/lib/main.dart'), top_dir('README.md')
    ('mobile', '(root)')
    """
    return path.split('/', 1)[0] if '/' in path else '(root)'


def mobile_dir(path: str) -> str:
    """The subdirectory of mobile/, two levels deep, as the study grouped them.

    >>> [mobile_dir(p) for p in ('mobile/lib/presentation/pages/a.dart', 'mobile/lib/main.dart', 'mobile/pubspec.yaml')]
    ['lib/presentation', 'lib', '(mobile root)']
    """
    return '/'.join(path.split('/')[1:-1][:2]) or '(mobile root)'


def count_lines(hunk_list: list) -> tuple:
    """Ours and theirs lines inside the markers.

    >>> count_lines([{'ours': ['a', 'b'], 'base': ['x'], 'theirs': ['c']}, {'ours': [], 'base': [], 'theirs': ['d']}])
    (2, 2)
    """
    return sum(len(h['ours']) for h in hunk_list), sum(len(h['theirs']) for h in hunk_list)


def newest_release_tag(git: Git, prefix: str) -> str:
    """The highest vX.Y.Z under [prefix] (no rc, no suffix)."""
    best = None
    for ref in git.run('for-each-ref', '--format=%(refname)', prefix).split():
        match = RELEASE_TAG.match(ref[len(prefix):] if ref.startswith(prefix) else ref)
        if match:
            version = tuple(int(part) for part in match.groups())
            if best is None or version > best[0]:
                best = (version, ref)
    if best is None:
        raise GitError(f'no release tag vX.Y.Z under {prefix} (fetch the upstream tags first)')
    return best[1]


def merge(git: Git, ours: str, theirs: str) -> tuple:
    """The conflicted paths with their hunks in the default style and in diff3, and the messages of the merge."""
    files = {}
    tree, conflicted, messages = parse_merge_tree(
        git.run('merge-tree', '--write-tree', '--messages', '-z', ours, theirs, ok=(0, 1), style='merge'))
    diff3_tree, _, _ = parse_merge_tree(
        git.run('merge-tree', '--write-tree', '--messages', '-z', ours, theirs, ok=(0, 1), style='diff3'))
    types = {}
    for paths, kind in messages:
        if kind.startswith('CONFLICT'):
            for path in paths:
                types.setdefault(path, []).append(kind.removeprefix('CONFLICT ').strip('()'))
    for path, stages in conflicted.items():
        def blob(at):
            try:
                return git.run('cat-file', 'blob', f'{at}:{path}')
            except GitError:
                return ''  # not in the merged tree (a deletion, a directory in the way)
        merged = hunks(blob(tree))
        with_base = hunks(blob(diff3_tree))
        ours_lines, theirs_lines = count_lines(merged)
        kinds = [hunk_kind(h) for h in with_base] if path_class(path) == 'source' else []
        files[path] = {
            'path': path, 'class': path_class(path), 'verdict': verdict(path, kinds), 'hunks': len(merged),
            'ours_lines': ours_lines, 'theirs_lines': theirs_lines, 'kinds': kinds, 'stages': stages,
            'conflicts': sorted(set(types.get(path, []))) or ['contents'],
        }
    auto = sorted({p for paths, kind in messages if kind == 'Auto-merging' for p in paths} - set(files))
    return files, auto


def target(git: Git, name: str, ref: str, ours: str) -> dict:
    commit = git.commit(ref)
    if not commit:
        raise GitError(f'{ref} is not a commit of the clone (fetch it first)')
    base = git.run('merge-base', ours, commit).strip()
    files, clean = merge(git, ours, commit)
    fixes = []
    for record in git.run('log', '--cherry-mark', '--right-only', '--no-merges', '-z',
                          '--format=%m%x1f%H%x1f%as%x1f%s', f'{ours}...{commit}', '--', 'mobile/').split('\0'):
        if not record.strip():
            continue
        mark, sha, date, subject = record.strip('\n').split('\x1f', 3)
        if FIX_TITLE.match(subject):
            fixes.append({'sha': sha, 'date': date, 'subject': subject, 'in_ours': mark == '='})
    changed = git.names('diff', '--name-only', '--no-renames', base, commit)
    return {
        'name': name, 'ref': ref.removeprefix('refs/upstream-tags/').removeprefix('refs/tags/'), 'commit': commit,
        'date': git.run('show', '-s', '--format=%as', commit).strip(),
        'subject': git.run('show', '-s', '--format=%s', commit).strip(),
        'merge_base': base, 'merge_base_date': git.run('show', '-s', '--format=%as', base).strip(),
        'behind': int(git.run('rev-list', '--count', f'{ours}..{commit}')),
        'behind_mobile': int(git.run('rev-list', '--count', '--no-merges', f'{ours}..{commit}', '--', 'mobile/')),
        'ahead': int(git.run('rev-list', '--count', f'{commit}..{ours}')),
        'changed_upstream': changed,
        'conflicts': [files[path] for path in sorted(files)],
        'clean_both_sides': clean,
        'fixes': fixes,
    }


def cell(text: str) -> str:
    """Text for a Markdown table cell.

    >>> cell('fix(web): a | b <tag>')
    'fix(web): a \\\\| b &lt;tag&gt;'
    """
    return text.replace('|', '\\|').replace('<', '&lt;').replace('>', '&gt;')


def totals(files: list) -> tuple:
    return len(files), sum(f['hunks'] for f in files), sum(f['ours_lines'] + f['theirs_lines'] for f in files)


def grouped(files: list, key) -> list:
    groups = {}
    for file in files:
        groups.setdefault(key(file['path']), []).append(file)
    rows = [(name, *totals(group)) for name, group in groups.items()]
    return sorted(rows, key=lambda row: (-row[1], -row[2], row[0]))


def table(header: tuple, rows: list) -> list:
    lines = ['| ' + ' | '.join(header) + ' |', '|' + '---|' * len(header)]
    return lines + ['| ' + ' | '.join(str(value) for value in row) + ' |' for row in rows]


def kinds_text(file: dict) -> str:
    if file['kinds']:
        return ', '.join(file['kinds'])
    return '' if file['hunks'] else ', '.join(file['conflicts'])


def target_section(t: dict, root: pathlib.Path) -> list:
    files = t['conflicts']
    n, h, lines = totals(files)
    short = t['commit'][:10]
    out = [f'## Upstream {t["name"]}: `{t["ref"]}` at `{short}` ({t["date"]})', '']
    out += [f'Merge base `{t["merge_base"][:10]}` ({t["merge_base_date"]}). {t["behind"]} upstream commits behind, '
            f'{t["behind_mobile"]} of them in mobile/; {t["ahead"]} of ours since the merge base. '
            f'{len(t["changed_upstream"])} files changed upstream since the merge base, '
            f'{sum(1 for p in t["changed_upstream"] if p.startswith("mobile/"))} in mobile/.', '']
    if not files:
        out += ['**No conflict.** The merge applies cleanly; the gates, the compile and the tests still decide.', '']
    else:
        out += [f'**{n} files in conflict, {h} hunks, {lines} lines inside the markers.**', '']
        out += ['### Conflicts by top level directory', '']
        out += table(('Directory', 'Files', 'Hunks', 'Lines'), grouped(files, top_dir)) + ['']
        mobile = [f for f in files if f['path'].startswith('mobile/')]
        if mobile:
            out += ['### mobile/ conflicts by subdirectory', '']
            out += table(('Subdirectory', 'Files', 'Hunks', 'Lines'), grouped(mobile, mobile_dir)) + ['']
        semantic = [f for f in files if f['verdict'] == 'semantic']
        out += [f'### Semantic files ({len(semantic)})', '']
        out += table(('File', 'Hunks', 'Ours lines', 'Theirs lines', 'Hunk kinds (diff3)'),
                     [(f'`{f["path"]}`', f['hunks'], f['ours_lines'], f['theirs_lines'], kinds_text(f))
                      for f in semantic]) if semantic else ['None.']
        out.append('')
        unions = [f for f in files if f['verdict'] == 'mechanical' and 'union' in f['kinds']]
        if unions:
            out += [f'### Unions in source files ({len(unions)}): both sides added lines at the same place', '']
            out += [f'- `{f["path"]}`: {kinds_text(f)}' for f in unions] + ['']
        others = [f for f in files if f['class'] != 'i18n']
        out += [f'### Conflicted files ({n}; the {n - len(others)} translation files below the table)', '']
        out += table(('File', 'Verdict', 'Class', 'Hunks', 'Ours lines', 'Theirs lines', 'Hunk kinds or conflict'),
                     [(f'`{f["path"]}`', f['verdict'], f['class'], f['hunks'], f['ours_lines'], f['theirs_lines'],
                       kinds_text(f)) for f in others]) + ['']
        i18n = [f for f in files if f['class'] == 'i18n']
        if i18n:
            out += ['<details><summary>The translation files in conflict (a key union by i18n_merge.py)</summary>', '']
            out += table(('File', 'Hunks', 'Ours lines', 'Theirs lines'),
                         [(f'`{f["path"]}`', f['hunks'], f['ours_lines'], f['theirs_lines']) for f in i18n])
            out += ['', '</details>', '']
    clean = t['clean_both_sides']
    clean_mobile = [p for p in clean if p.startswith('mobile/')]
    out += [f'### Files both sides changed, merged without conflict ({len(clean)}, {len(clean_mobile)} in mobile/)', '',
            'No marker, but they have to compile and pass the tests like the rest.', '']
    if clean:
        out += ['<details><summary>The list</summary>', ''] + [f'- `{p}`' for p in clean] + ['', '</details>', '']
    picked = sum(1 for f in t['fixes'] if f['in_ours'])
    out += [f'### Upstream mobile fixes since the merge base ({len(t["fixes"])}, {picked} already in ours)', '']
    if t['fixes']:
        out += table(('Commit', 'Date', 'Title', 'In ours'),
                     [(f'`{f["sha"][:10]}`', f['date'], cell(f['subject']), 'yes' if f['in_ours'] else '')
                      for f in t['fixes']])
    else:
        out.append('None.')
    out.append('')
    checklist = upstream_sync_report.report(root, t['changed_upstream'])
    out += ['<details><summary>Desktop checklist for the files upstream changed (upstream_sync_report.py)</summary>',
            '']
    out += [('##' + line) if line.startswith('#') else line for line in checklist.splitlines()]
    out += ['', '</details>', '']
    return out


HOW_TO_READ = '''## How to read it

The conflict counts use the default conflict style, as the sync study of 10 November 2026 did. A hunk kind comes
from a second merge with the base inside the markers (diff3, which can cut a conflict into more hunks): imports
(only import, export, part or comment lines), one side (ours or theirs is empty: keep or drop), union (both sides
only added lines: keep both, in order), rewrite (both sides changed the same lines). A source file is semantic when
it has a rewrite hunk, or a conflict without markers (modify/delete, binary). Translations, generated code, lock
files, documentation, tests and configuration are mechanical by their path. "In ours" means the patch of the fix,
limited to mobile/, is already on our branch (a pick); a pick that needed a resolution shows as missing.
The method and the reading of the heuristic are in the head of .github/desktop/upstream_dry_merge.py.'''


def render(ours: dict, targets: list, root: pathlib.Path, when: str) -> str:
    out = [f'# Upstream dry merge of {when}', '',
           f'Ours: `{ours["ref"]}` at `{ours["commit"][:10]}` ({ours["date"]}, "{cell(ours["subject"])}"). '
           'Upstream: immich-app/immich. Nothing was pushed or committed; the merges ran in memory.', '']
    head = ['Measure'] + [f'{t["name"]} `{t["ref"]}`' for t in targets]
    rows = [
        ('Upstream commit', *(f'`{t["commit"][:10]}` ({t["date"]})' for t in targets)),
        ('Merge base', *(f'`{t["merge_base"][:10]}` ({t["merge_base_date"]})' for t in targets)),
        ('Commits behind (in mobile/)', *(f'{t["behind"]} ({t["behind_mobile"]})' for t in targets)),
        ('Our commits since the merge base', *(t['ahead'] for t in targets)),
        ('Files upstream changed (in mobile/)',
         *(f'{len(t["changed_upstream"])} ({sum(1 for p in t["changed_upstream"] if p.startswith("mobile/"))})'
           for t in targets)),
        ('Files in conflict', *(len(t['conflicts']) for t in targets)),
        ('Conflict hunks', *(totals(t['conflicts'])[1] for t in targets)),
        ('Lines inside the markers', *(totals(t['conflicts'])[2] for t in targets)),
        ('Translation files in conflict', *(sum(1 for f in t['conflicts'] if f['class'] == 'i18n') for t in targets)),
        ('Semantic files (hunks)',
         *(f'{len(s)} ({sum(f["hunks"] for f in s)})'
           for s in ([f for f in t['conflicts'] if f['verdict'] == 'semantic'] for t in targets))),
        ('Unions in source files',
         *(sum(1 for f in t['conflicts'] if f['verdict'] == 'mechanical' and 'union' in f['kinds']) for t in targets)),
        ('Both sides changed, merged cleanly (in mobile/)',
         *(f'{len(t["clean_both_sides"])} ({sum(1 for p in t["clean_both_sides"] if p.startswith("mobile/"))})'
           for t in targets)),
        ('Upstream mobile fixes (already in ours)',
         *(f'{len(t["fixes"])} ({sum(1 for f in t["fixes"] if f["in_ours"])})' for t in targets)),
    ]
    out += table(head, rows) + ['']
    for t in targets:
        out += target_section(t, root)
    out += [HOW_TO_READ, '']
    return '\n'.join(out)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--repo', type=pathlib.Path, default=ROOT, help='the clone (and the tree the checklist reads)')
    parser.add_argument('--ours', default='HEAD', help='our branch (origin/immuch360 in CI)')
    parser.add_argument('--main', default='upstream/main', help='upstream main as the clone knows it')
    parser.add_argument('--tags', default='refs/upstream-tags/', help='where the upstream tags were fetched to')
    parser.add_argument('--tag', help='a release tag to merge instead of the newest one under --tags')
    parser.add_argument('--report', type=pathlib.Path, help='write the Markdown report there')
    parser.add_argument('--json', type=pathlib.Path, help='write the numbers there')
    parser.add_argument('--summary', type=pathlib.Path, help='append the report there ($GITHUB_STEP_SUMMARY)')
    args = parser.parse_args(argv)

    when = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
    try:
        with tempfile.TemporaryDirectory(prefix='dry-merge-objects-') as objects:
            git = Git(args.repo, objects)
            ours_commit = git.commit(args.ours)
            if not ours_commit:
                raise GitError(f'{args.ours} is not a commit of the clone')
            tag = args.tag or newest_release_tag(git, args.tags)
            ours = {'ref': args.ours, 'commit': ours_commit,
                    'date': git.run('show', '-s', '--format=%as', ours_commit).strip(),
                    'subject': git.run('show', '-s', '--format=%s', ours_commit).strip()}
            targets = [target(git, 'main', args.main, ours_commit), target(git, 'release', tag, ours_commit)]
            text = render(ours, targets, args.repo, when)
    except GitError as error:
        print(f'git failed: {error}', file=sys.stderr)
        return 2

    for t in targets:
        n, h, lines = totals(t['conflicts'])
        semantic = sum(1 for f in t['conflicts'] if f['verdict'] == 'semantic')
        print(f'{t["name"]} {t["ref"]} {t["commit"][:10]}: {t["behind"]} commits behind, {n} files in conflict, '
              f'{h} hunks, {lines} lines, {semantic} semantic, {len(t["fixes"])} mobile fixes')
    if args.report:
        args.report.write_text(text, encoding='utf-8')
    if args.json:
        args.json.write_text(json.dumps({'generated': when, 'ours': ours, 'targets': targets}, indent=1) + '\n',
                             encoding='utf-8')
    if args.summary:
        with open(args.summary, 'a', encoding='utf-8') as summary:
            summary.write(text + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
