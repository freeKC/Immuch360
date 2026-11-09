#!/usr/bin/env python3
"""Keeps the receiver of every JNI call of lib/src/jni/bindings.dart alive until the call returns.

The bindings that jnigen 0.15 generates pass the receiver of an instance call as `reference.pointer`, read on `this`.
`this` is a `JObject`, which is not `Finalizable`, and Dart keeps a `Finalizable` alive only while a local variable, a
parameter or the `this` of a `Finalizable` class holds it, never as a subexpression. Once the address has been read,
nothing keeps the receiver reachable: a garbage collection during the call (another isolate of the group allocating,
or the lazy lookup of the method ID on the first call) can run the finalizer of the receiver, which deletes its JNI
global reference while ART is about to use it. jnigen 0.17.0 fixed its generator (dart-lang/native#3346) by binding
the reference to a local first:

    Request$Builder url$1(jni$_.JString string) {
      final _$$selfRef = reference;
      final _$string = string.reference;
      return _url$1(_$$selfRef.pointer, _id_url$1 as jni$_.JMethodIDPtr, _$string.pointer)
          .object<Request$Builder>(const $Request$Builder$Type$());
    }

This script applies that form to a file of jnigen 0.15: in each member body that uses `reference.pointer` as a
receiver (an occurrence not preceded by a word character, `.` or `$`, so `_class.reference.pointer` of the static
members and `_$string.pointer` of the arguments are left alone), it inserts `final _$$selfRef = reference;` as the
first statement and passes `_$$selfRef.pointer` instead. Comments and string literals are skipped. It stops without
writing anything when a receiver use is not directly in the body of a class member, and it ends by checking that no
receiver use is left.

  hoist_receivers.py [FILE]           rewrite FILE (lib/src/jni/bindings.dart of this package by default)
  hoist_receivers.py --check [FILE]   only say whether FILE still has a receiver use; exit 1 when it has

Running it again on a rewritten file changes nothing.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

PACKAGE = pathlib.Path(__file__).resolve().parents[1]
DEFAULT = PACKAGE / 'lib' / 'src' / 'jni' / 'bindings.dart'
RECEIVER = re.compile(r'(?<![\w.$])reference\.pointer')
SELF_REF = 'final _$$selfRef = reference;'
MARK = '// Immuch360: the receiver of each call is kept in a local by tool/hoist_receivers.py, see IMMUCH360-NOTE.md.'


def mask(text: str) -> str:
    """[text] with its comments and string literals blanked out (same length, newlines kept)"""
    out = list(text)
    i = 0
    n = len(text)

    def blank(start: int, end: int) -> None:
        for k in range(start, end):
            if out[k] != '\n':
                out[k] = ' '

    while i < n:
        if text.startswith('//', i):
            end = text.find('\n', i)
            end = n if end < 0 else end
            blank(i, end)
            i = end
            continue
        if text.startswith('/*', i):
            end = text.find('*/', i)
            if end < 0:
                raise ValueError(f'unterminated comment at line {line_of(text, i)}')
            blank(i, end + 2)
            i = end + 2
            continue
        start = i
        raw = False
        if text[i] == 'r' and i + 1 < n and text[i + 1] in '\'"' and (i == 0 or not is_word(text[i - 1])):
            raw = True
            i += 1
        if text[i] in '\'"':
            quote = text[i:i + 3] if text[i:i + 3] in ("'''", '"""') else text[i]
            j = i + len(quote)
            while j < n and not text.startswith(quote, j):
                if not raw and text[j] == '\\':
                    j += 2
                    continue
                if not raw and text.startswith('${', j):
                    # An interpolation could hold code; bindings of jnigen have none, so refuse rather than guess
                    raise ValueError(f'string interpolation at line {line_of(text, j)}')
                j += 1
            if j >= n:
                raise ValueError(f'unterminated string at line {line_of(text, start)}')
            blank(start, j + len(quote))
            i = j + len(quote)
            continue
        i = start + 1
    return ''.join(out)


def is_word(ch: str) -> bool:
    return ch.isalnum() or ch in '_$'


def line_of(text: str, pos: int) -> int:
    return text.count('\n', 0, pos) + 1


def receiver_uses(code: str) -> list:
    """The positions of the receiver uses in masked [code]"""
    return [found.start() for found in RECEIVER.finditer(code)]


def member_bodies(code: str, uses: list) -> dict:
    """{position of the opening brace of a member body: (its closing brace, [receiver uses in it])}

    A member body is a block opened at depth 1 (inside a top level declaration). Every use must sit directly in such
    a body, not in a nested block or closure, or a ValueError names its line."""
    bodies = {}
    stack = []
    pending = iter(uses)
    current = next(pending, None)
    for i, ch in enumerate(code):
        while current is not None and current == i:
            if len(stack) != 2:
                raise ValueError(f'receiver use at depth {len(stack)}, line {line_of(code, i)}: not handled')
            bodies.setdefault(stack[1], [None, []])[1].append(i)
            current = next(pending, None)
        if ch == '{':
            stack.append(i)
        elif ch == '}':
            opened = stack.pop()
            if opened in bodies:
                bodies[opened][0] = i
    return {start: (end, found) for start, (end, found) in bodies.items()}


def hoist(text: str) -> tuple:
    """[text] with the receivers kept in a local, and the number of members changed"""
    code = mask(text)
    uses = receiver_uses(code)
    bodies = member_bodies(code, uses)
    pieces = []
    last = len(text)
    for start in sorted(bodies, reverse=True):
        end, found = bodies[start]
        if SELF_REF in text[start:end]:
            line = line_of(text, start)
            raise ValueError(f'member at line {line} already binds _$$selfRef and still has a receiver use')
        body = text[start + 1:end]
        for use in sorted(found, reverse=True):
            offset = use - (start + 1)
            body = body[:offset] + '_$$selfRef.pointer' + body[offset + len('reference.pointer'):]
        first_line = next((line for line in body.split('\n')[1:] if line.strip()), '')
        indent = first_line[:len(first_line) - len(first_line.lstrip())]
        pieces.append(text[end:last])
        pieces.append('{\n' + indent + SELF_REF + body)
        last = start
    pieces.append(text[:last])
    result = ''.join(reversed(pieces))
    if bodies and MARK not in result:
        first_end = result.find('\n') + 1
        result = result[:first_end] + '\n' + MARK + '\n' + result[first_end:]
    return result, len(bodies)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--check', action='store_true', help='only check, write nothing')
    parser.add_argument('file', nargs='?', type=pathlib.Path, default=DEFAULT)
    args = parser.parse_args()
    # Bytes in and out, so that the line endings stay as they are
    text = args.file.read_bytes().decode('utf-8')
    if args.check:
        left = receiver_uses(mask(text))
        for use in left:
            print(f'{args.file}:{line_of(text, use)}: receiver passed as reference.pointer')
        print(f'{len(left)} receiver uses left, {text.count(SELF_REF)} members bind _$$selfRef')
        return 1 if left else 0
    try:
        result, changed = hoist(text)
    except ValueError as error:
        print(f'{args.file}: {error}; nothing written', file=sys.stderr)
        return 1
    left = receiver_uses(mask(result))
    if left:
        print(f'{args.file}: {len(left)} receiver uses left after the rewrite; nothing written', file=sys.stderr)
        return 1
    if changed:
        args.file.write_bytes(result.encode('utf-8'))
    print(f'{changed} members changed, 0 receiver uses left, {result.count(SELF_REF)} members bind _$$selfRef')
    return 0


if __name__ == '__main__':
    sys.exit(main())
