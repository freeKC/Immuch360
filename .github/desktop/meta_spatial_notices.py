#!/usr/bin/env python3
"""The notices of the Meta Spatial SDK as plain text, for the licence page of the app.

Each AAR of the Meta Spatial SDK 0.14.0 (meta-spatial-sdk, -toolkit, -vr, and -splat of the quest flavour) carries the
same notices.html (SHA-256 3c77d854f4771ed619a89f17cf6eb6e5f5d85e2d37f36de471bd3f9f9e40cf95): the third party software
in its native libraries, grouped by licence. This writes it as text, every title, package, copyright and licence text
in its order, into mobile/assets/licenses/meta-spatial-sdk/NOTICES.txt, which lib/utils/meta_spatial_licenses.dart
shows next to the licence of the SDK (LICENSE, the text of the AARs as it is).

  meta_spatial_notices.py AAR_OR_HTML            writes NOTICES.txt from an AAR (or its notices.html)
  meta_spatial_notices.py AAR_OR_HTML --check    exit 1 when NOTICES.txt differs
"""
from __future__ import annotations

import argparse
import hashlib
import html.parser
import pathlib
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "mobile/assets/licenses/meta-spatial-sdk/NOTICES.txt"
NOTICES_SHA256 = "3c77d854f4771ed619a89f17cf6eb6e5f5d85e2d37f36de471bd3f9f9e40cf95"


class _Text(html.parser.HTMLParser):
    """The text of the notices: a blank line around titles and licence texts, one line per package"""

    BLOCKS = {"h1", "p", "li", "pre", "ul", "div"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.skip = 0
        self.pre = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("style", "head", "title"):
            self.skip += 1
        if tag == "pre":
            self.pre += 1
        if tag in ("h1", "pre"):
            self.parts.append("\n\n")
        elif tag in self.BLOCKS or tag == "br":
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in ("style", "head", "title"):
            self.skip -= 1
        if tag == "pre":
            self.pre -= 1
        if tag in ("h1", "pre"):
            self.parts.append("\n\n")
        elif tag in self.BLOCKS:
            self.parts.append("\n")

    def handle_data(self, data):
        if self.skip:
            return
        if self.pre:
            self.parts.append(data)
        else:
            text = " ".join(data.split())
            if text:
                if self.parts and not self.parts[-1].endswith(("\n", " ")) and not text.startswith((",", ".", ";")):
                    self.parts.append(" ")
                self.parts.append(text)


def notices_text(html_bytes: bytes) -> str:
    parser = _Text()
    parser.feed(html_bytes.decode("utf-8"))
    lines = [line.rstrip() for line in "".join(parser.parts).splitlines()]
    out: list[str] = []
    for line in lines:
        if line == "" and (not out or out[-1] == ""):
            continue
        out.append(line)
    return "\n".join(out).strip() + "\n"


def read_html(path: pathlib.Path) -> bytes:
    if path.suffix == ".aar":
        with zipfile.ZipFile(path) as aar:
            return aar.read("notices.html")
    return path.read_bytes()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("source", type=pathlib.Path, help="an AAR of the Meta Spatial SDK, or its notices.html")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    html_bytes = read_html(args.source)
    digest = hashlib.sha256(html_bytes).hexdigest()
    if digest != NOTICES_SHA256:
        print(f"notices.html of another version ({digest}): update NOTICES_SHA256 and the README of licenses/")
        return 1
    text = notices_text(html_bytes)
    if args.check:
        same = OUT.is_file() and OUT.read_text(encoding="utf-8") == text
        print("same" if same else f"differs: {OUT.relative_to(ROOT)}")
        return 0 if same else 1
    OUT.write_text(text, encoding="utf-8")
    print(f"{OUT.relative_to(ROOT)}: {len(text)} characters")
    return 0


if __name__ == "__main__":
    sys.exit(main())
