#!/usr/bin/env python3
"""Gate of Immuch360: the Android app claims no web link it cannot own, and its custom schemes pass Play's app checks.

Google Play's Deep links page reads the intent filters of the app. A filter on http or https names web domains: the
links of a domain open the app only once https://<domain>/.well-known/assetlinks.json names the package and the
signing key of the app, which only the owner of the domain can publish. The project owns no web domain, so such a
filter can never be verified, and Play reports its domain as not verified and its links as broken. That was the case
of my.immich.app, Immich's own domain, whose file names Immich's app (app.alextran.immich, Immich's signing keys),
never com.aprogsys.immuch360, the package of every Immuch360 build (app.alextran.immich is only the namespace of its
classes). autoVerify asks Android and Play to verify those domains: with no domain of its own, the project has
nothing to verify. A VIEW filter on another scheme (content, immich, immuch360, app.immich) is listed as a custom
scheme, and Play's app checks want it to carry the DEFAULT and BROWSABLE categories.

So this check reads every mobile/android/app/src/*/AndroidManifest.xml (main, the phone and quest flavours, debug,
profile) and fails on an intent filter that names an http or https scheme with a host that is not the project's
(OUR_HOSTS, empty: no web domain) or with no host at all (every web address); on one that sets autoVerify, unless
every host of the filter is the project's; and on one with the VIEW action and a scheme other than http or https that
lacks the DEFAULT or the BROWSABLE category. A filter or a component removed by tools:node="remove" (a flavour
manifest) is left out. The <queries> of a manifest are not intent filters: asking whether a browser is installed
claims no link.

  check_android_manifest.py                 the manifests of the source sets, exit 1 on a filter Play would flag
  check_android_manifest.py FILE...         those manifests instead, the merged ones of a build for one

--root points at another tree and --our-host adds a domain of the project (the tests use both). Exit 2 when there is
no manifest to read or one is not XML.
"""
from __future__ import annotations

import argparse
import pathlib
import sys
import xml.parsers.expat

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE_SETS = 'mobile/android/app/src/*/AndroidManifest.xml'
ANDROID = 'http://schemas.android.com/apk/res/android'
TOOLS = 'http://schemas.android.com/tools'
# The web domains of the project, whose assetlinks.json would name its packages and signing keys: none today. A host
# goes here only once that file is published on it.
OUR_HOSTS = frozenset()
WEB = frozenset({'http', 'https'})
VIEW = 'android.intent.action.VIEW'
CATEGORIES = ('android.intent.category.DEFAULT', 'android.intent.category.BROWSABLE')
COMPONENTS = frozenset({'activity', 'activity-alias', 'service', 'receiver', 'provider'})


class Node:
    def __init__(self, tag: str, attrs: dict, line: int):
        self.tag = tag
        self.attrs = attrs
        self.line = line
        self.children = []

    def android(self, name: str) -> str | None:
        return self.attrs.get(f'{ANDROID} {name}')

    def removed(self) -> bool:
        return self.attrs.get(f'{TOOLS} node') in ('remove', 'removeAll')


def parse(path: pathlib.Path) -> Node:
    """The element tree of a manifest with the line of each element; attributes keyed '<namespace> <name>'"""
    parser = xml.parsers.expat.ParserCreate(namespace_separator=' ')
    root = Node('', {}, 0)
    stack = [root]

    def start(tag, attrs):
        node = Node(tag, attrs, parser.CurrentLineNumber)
        stack[-1].children.append(node)
        stack.append(node)

    def end(_tag):
        stack.pop()

    parser.StartElementHandler = start
    parser.EndElementHandler = end
    parser.Parse(path.read_bytes(), True)
    return root


def intent_filters(node: Node):
    """Every intent filter under [node] with its component, those removed by tools:node left out"""
    for child in node.children:
        if child.removed():
            continue
        if child.tag == 'intent-filter' and node.tag in COMPONENTS:
            yield node, child
        else:
            yield from intent_filters(child)


def problems(component: Node, intent_filter: Node, ours: frozenset) -> list:
    actions = {c.android('name') for c in intent_filter.children if c.tag == 'action'}
    categories = {c.android('name') for c in intent_filter.children if c.tag == 'category'}
    data = [c for c in intent_filter.children if c.tag == 'data']
    # Android merges the attributes of every <data> of a filter: a scheme on one and a host on another go together
    schemes = {d.android('scheme').lower() for d in data if d.android('scheme')}
    hosts = {d.android('host').lower() for d in data if d.android('host')}
    found = []
    if schemes & WEB:
        foreign = sorted(hosts - ours)
        if foreign:
            found.append(f'web links to {", ".join(foreign)}, not a domain of the project: its assetlinks.json '
                         f'cannot name the packages of Immuch360, so Google Play reports the domain as not verified '
                         f'and its links as broken')
        elif not hosts:
            found.append('web links with no host: the filter would take every http or https address')
    verify = intent_filter.android('autoVerify')
    if verify is not None and verify.lower() != 'false' and not (hosts and hosts <= ours):
        found.append(f'autoVerify="{verify}": only a domain of the project can be verified, and it has none')
    custom = sorted(schemes - WEB)
    if custom and VIEW in actions:
        missing = [c.rsplit('.', 1)[1] for c in CATEGORIES if c not in categories]
        if missing:
            found.append(f'VIEW on {", ".join(s + "://" for s in custom)} without the {" and ".join(missing)} '
                         f'{"categories" if len(missing) > 1 else "category"}: Google Play\'s app checks of a custom '
                         f'scheme want VIEW, DEFAULT and BROWSABLE')
    return [f'{intent_filter.line}: {component.android("name") or component.tag}: {text}' for text in found]


def check(path: pathlib.Path, label: str, ours: frozenset) -> tuple:
    """The problems of one manifest, and a line saying what it holds"""
    found = []
    schemes, hosts = set(), set()
    count = 0
    for component, intent_filter in intent_filters(parse(path)):
        count += 1
        found += [f'{label}:{line}' for line in problems(component, intent_filter, ours)]
        for data in intent_filter.children:
            if data.tag == 'data':
                if data.android('scheme'):
                    schemes.add(data.android('scheme').lower())
                if data.android('host'):
                    hosts.add(data.android('host').lower())
    summary = (f'{label}: {count} intent filters, schemes {", ".join(sorted(schemes)) or "none"}, '
               f'hosts {", ".join(sorted(hosts)) or "none"}')
    return found, summary


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('manifests', nargs='*', type=pathlib.Path,
                        help='manifests to read instead of those of the source sets (a merged manifest)')
    parser.add_argument('--root', type=pathlib.Path, default=ROOT, help='repository root')
    parser.add_argument('--our-host', action='append', default=[], help='a web domain of the project')
    args = parser.parse_args(argv)

    ours = OUR_HOSTS | {host.lower() for host in args.our_host}
    paths = args.manifests or sorted(args.root.glob(SOURCE_SETS))
    if not paths:
        print(f'no manifest matches {SOURCE_SETS} under {args.root}')
        return 2
    bad = []
    for path in paths:
        try:
            label = path.resolve().relative_to(args.root.resolve()).as_posix()
        except ValueError:
            label = path.as_posix()
        try:
            found, summary = check(path, label, ours)
        except (OSError, xml.parsers.expat.ExpatError) as error:
            print(f'{label}: cannot be read as XML: {error}')
            return 2
        print(summary)
        bad += found
    for line in bad:
        print(line)
    if bad:
        print('An intent filter Google Play would flag: remove the web links of a domain the project does not own and '
              'their autoVerify, and give every VIEW filter of a custom scheme the DEFAULT and BROWSABLE categories')
        return 1
    print(f'{len(paths)} manifests: no web link to a domain the project does not own, no autoVerify, DEFAULT and '
          f'BROWSABLE on every VIEW filter of a custom scheme')
    return 0


if __name__ == '__main__':
    sys.exit(main())
