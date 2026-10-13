#!/usr/bin/env python3
"""The packages of Immuch360 Desktop: the Windows installer, the Linux .deb and .rpm, the macOS document types.

The file types the packages offer "Open with" for are listed once, in .github/desktop/file-associations.json: photos
and videos, each extension with a one line description. This script turns that list into what each system reads.

  desktop_installers.py check
      the list is well formed, every extension has its Linux and macOS type below, and mobile/macos/Runner/Info.plist
      declares the list (CFBundleDocumentTypes, UTImportedTypeDeclarations); exit 1 on any finding
  desktop_installers.py macos --write
      sets those two keys of Info.plist from the list
  desktop_installers.py inno --out FILE
      the [Registry] lines of the Windows installer, which packaging/windows/immuch360.iss includes: one ProgID per
      extension (Immuch360.<extension>, named by its description) listed in the OpenWithProgids of the extension, the
      program under Applications\\immuch360.exe with its SupportedTypes, and its Capabilities, which list it in the
      Default apps settings. The default program of an extension (the default value of its key) is never written:
      Windows offers the app in "Open with" and in the settings, and only the user makes it the default.
  desktop_installers.py windows --bundle DIR --label LABEL --file-version A.B.C.D --out DIR [--iscc FILE]
      those lines, then Inno Setup 6 on the folder that windows_bundle.py made for the ZIP, so that the installer and
      the ZIP carry the same files: <out>/Immuch360-Desktop-<label>-windows-x64-setup.exe
  desktop_installers.py linux --bundle DIR --label LABEL --out DIR [--nfpm FILE] [--patchelf FILE] [--stage-only]
      the bundle of `flutter build linux` under /opt/immuch360 with the launcher /usr/bin/immuch360, the desktop entry
      (its MimeType= made from the list), the icons and the MIME types of the raw camera files, staged in <out>/stage,
      then the .deb and the .rpm made from it by nFPM: <out>/Immuch360-Desktop-<label>-linux-amd64.deb and
      <out>/Immuch360-Desktop-<label>-linux-x86_64.rpm. The bundle loses libdartjni.so (Android only, it needs a Java
      runtime), and patchelf replaces the build folder in the RUNPATH of its libraries by $ORIGIN
  desktop_installers.py versions --label LABEL
      the version of the Linux packages for a label of desktop_version.py

LABEL is the label of desktop_version.py: 3.3.0-rc.0-desktop.5 on a desktop pre-release tag, 3.3.0-rc.0-23 on a
fork release tag, 3.3.0-rc.0-23-d7103a7 otherwise. --associations and --plist point at other files (the tests use
fixtures). Only the Python standard library is used, as on every runner.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
ASSOCIATIONS = HERE / 'file-associations.json'
PLIST = ROOT / 'mobile' / 'macos' / 'Runner' / 'Info.plist'
ISS = HERE / 'packaging' / 'windows' / 'immuch360.iss'
LINUX_TEMPLATES = HERE / 'packaging' / 'linux'
ICONS = ROOT / 'mobile' / 'macos' / 'Runner' / 'Assets.xcassets' / 'AppIcon.appiconset'

APP_NAME = 'Immuch360 Desktop'
APP_ID = 'com.aprogsys.immuch360'
EXE = 'immuch360.exe'
PROG_ID = 'Immuch360.{}'
CAPABILITIES = r'Software\Immuch360\Immuch360 Desktop\Capabilities'
DESCRIPTION = 'Photos and videos, 360° included, from Immich, your folders and your network shares'
# The one line of the Linux packages (under 80 characters for Debian)
SUMMARY = 'Photos and videos, 360° included, with or without an Immich server'
HOMEPAGE = 'https://github.com/freeKC/Immuch360'

EXTENSION = re.compile(r'^[0-9a-z]{1,10}$')
# Strict on purpose: the label ends up in file names, package versions and the command line of the compilers
LABEL = re.compile(r'^(\d+\.\d+\.\d+)(?:-([0-9A-Za-z.]+))?-(\d{1,5}|desktop\.\d{1,5})(?:-([0-9a-z]{4,40}))?$')
FILE_VERSION = re.compile(r'^\d+\.\d+\.\d+\.\d+$')
# The text rules of the repository: a dash is never punctuation
DASH = re.compile(' \x2d |[\u2013\u2014]')

# What Linux calls the types of the list: the types of shared-mime-info (freedesktop.org.xml), and for the raw files of
# 360° cameras, which it does not know, types this package declares (/usr/share/mime/packages/<app id>.xml), each a
# kind of the container it is: extension to (type, parent type)
LINUX_MIME = {
    'jpg': ['image/jpeg'],
    'jpeg': ['image/jpeg'],
    'png': ['image/png'],
    'heic': ['image/heif', 'image/heic'],
    'heif': ['image/heif', 'image/heic'],
    'avif': ['image/avif'],
    'webp': ['image/webp'],
    'tif': ['image/tiff'],
    'tiff': ['image/tiff'],
    'dng': ['image/x-adobe-dng'],
    'mp4': ['video/mp4'],
    'mov': ['video/quicktime'],
    'm4v': ['video/mp4', 'video/x-m4v'],
    'mkv': ['video/x-matroska'],
    'webm': ['video/webm'],
}
LINUX_OWN_MIME = {
    'insp': ('image/x-insta360-insp', 'image/jpeg'),
    'insv': ('video/x-insta360-insv', 'video/mp4'),
    '360': ('video/x-gopro-360', 'video/mp4'),
    'osv': ('video/x-dji-osv', 'video/mp4'),
}
# What macOS calls them: the uniform type identifiers of the system, and those the app imports (declares for itself,
# without owning them): the raw camera files, and three types older macOS versions may not declare (the system's own
# declaration wins where there is one)
MACOS_UTI = {
    'jpg': 'public.jpeg',
    'jpeg': 'public.jpeg',
    'png': 'public.png',
    'heic': 'public.heic',
    'heif': 'public.heif',
    'webp': 'org.webmproject.webp',
    'tif': 'public.tiff',
    'tiff': 'public.tiff',
    'dng': 'com.adobe.raw-image',
    'mp4': 'public.mpeg-4',
    'mov': 'com.apple.quicktime-movie',
    'm4v': 'com.apple.m4v-video',
}
MACOS_IMPORTED = {
    'avif': ('public.avif', ['public.image']),
    'mkv': ('org.matroska.mkv', ['public.movie']),
    'webm': ('org.webmproject.webm', ['public.movie']),
    'insp': ('com.aprogsys.immuch360.insp', ['public.jpeg']),
    'insv': ('com.aprogsys.immuch360.insv', ['public.mpeg-4']),
    '360': ('com.aprogsys.immuch360.gopro-360', ['public.mpeg-4']),
    'osv': ('com.aprogsys.immuch360.osv', ['public.mpeg-4']),
}

# The libraries the Linux bundle needs from the system. Its ELF files link GTK 3 and GLib (the Flutter engine and every
# plugin), libsecret (flutter_secure_storage_linux), WebKitGTK 4.1 with libsoup 3 (desktop_webview_window, the window
# of a server's OAuth sign in), libepoxy (the engine), and glibc 2.34 and libstdc++ of GCC 11 at least (the build runs
# on Ubuntu 22.04); libmpv is not linked but opened by media_kit when a video plays (libmpv.so, .so.2 or .so.1).
# Debian and Ubuntu renamed some libraries for 64 bit time (libgtk-3-0t64 on Ubuntu 24.04 and Debian 13): either name
# satisfies the package. libsmb2.so, which dart_smb2 downloads already built, needs glibc 2.38; it is opened when an SMB
# share is browsed, so on an older glibc the app runs without SMB shares. Checked by packaging/linux/check_package.sh in
# containers: every library each ELF file of /opt/immuch360 needs is found once the package is installed.
DEB_DEPENDS = [
    'libc6 (>= 2.34)',
    'libstdc++6 (>= 11)',
    'libgtk-3-0t64 | libgtk-3-0',
    'libglib2.0-0t64 | libglib2.0-0',
    'libsecret-1-0',
    'libwebkit2gtk-4.1-0',
    'libsoup-3.0-0',
    'libepoxy0',
    'libmpv2 | libmpv1',
]
RPM_DEPENDS = [
    'glibc >= 2.34',
    'libstdc++',
    'gtk3',
    'glib2',
    'libsecret',
    'webkit2gtk4.1',
    'libsoup3',
    'libepoxy',
    'mpv-libs',
]
# Built by the jni package whenever a JDK is found, for Android only: it needs the libjvm.so of a Java runtime, as
# dartjni.dll does on Windows (windows_bundle.py leaves that one out too)
LINUX_LEFT_OUT = ('libdartjni.so',)
ICON_SIZES = (16, 32, 64, 128, 256, 512)


class Problem(Exception):
    pass


def load(path: pathlib.Path = ASSOCIATIONS) -> dict:
    """The list as {extension: (kind, description)}, kind 'photo' or 'video', in the order of the file."""
    data = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(data, dict) or set(data) != {'photos', 'videos'}:
        raise Problem(f'{path.name}: two maps, "photos" and "videos", extension to description')
    types = {}
    for key, kind in (('photos', 'photo'), ('videos', 'video')):
        if not isinstance(data[key], dict) or not data[key]:
            raise Problem(f'{path.name}: "{key}" is not a map of extensions')
        for extension, description in data[key].items():
            if not EXTENSION.match(extension):
                raise Problem(f'{path.name}: {extension!r} is not an extension in lower case, without its dot')
            if extension in types:
                raise Problem(f'{path.name}: {extension} is listed twice')
            if not isinstance(description, str) or not description.strip() or '\n' in description:
                raise Problem(f'{path.name}: {extension} needs a one line description')
            types[extension] = (kind, description)
    return types


def findings(types: dict) -> list:
    """What the list lacks for the packages, beyond its form (load() checks that)."""
    found = []
    for extension, (_, description) in types.items():
        if DASH.search(description):
            found.append(f'{extension}: a dash used as punctuation in "{description}"')
        if extension not in LINUX_MIME and extension not in LINUX_OWN_MIME:
            found.append(f'{extension}: no Linux MIME type in desktop_installers.py (LINUX_MIME or LINUX_OWN_MIME)')
        if extension not in MACOS_UTI and extension not in MACOS_IMPORTED:
            found.append(f'{extension}: no macOS type in desktop_installers.py (MACOS_UTI or MACOS_IMPORTED)')
    return found


def parse_label(label: str) -> dict:
    match = LABEL.match(label)
    if not match:
        raise Problem(f'label {label!r} is not one of desktop_version.py (3.3.0-rc.0-desktop.5, 3.3.0-rc.0-23, '
                      '3.3.0-rc.0-23-d7103a7)')
    version, prerelease, build, commit = match.groups()
    return {'version': version, 'prerelease': prerelease or '', 'build': build, 'commit': commit or ''}


def linux_version(label: str) -> dict:
    """The version of the .deb and the .rpm: 3.3.0~rc.0-desktop.5, 3.3.0~rc.0-23, 3.3.0~rc.0-23.d7103a7.

    The pre-release part follows a tilde, which both systems sort before the release itself (3.3.0~rc.0 comes before
    3.3.0), and what follows the version is the package release: the desktop build, the fork build, or the fork build
    and the commit of a build between two releases.
    """
    parts = parse_label(label)
    release = parts['build'] + (f".{parts['commit']}" if parts['commit'] else '')
    upstream = parts['version'] + (f"~{parts['prerelease']}" if parts['prerelease'] else '')
    return {
        'version': parts['version'],
        'prerelease': parts['prerelease'],
        'release': release,
        'deb': f'{upstream}-{release}',
        'rpm': f'{upstream}-{release}',
    }


# --- macOS -------------------------------------------------------------------------------------------------------


def macos_declarations(types: dict) -> tuple:
    """CFBundleDocumentTypes (one per type identifier, ranked Alternate: offered, never the default) and
    UTImportedTypeDeclarations."""
    documents, imported, seen = [], {}, set()
    for extension, (kind, description) in types.items():
        if extension in MACOS_IMPORTED:
            identifier, conforms = MACOS_IMPORTED[extension]
            declaration = imported.setdefault(identifier, {
                'UTTypeConformsTo': conforms,
                'UTTypeDescription': description,
                'UTTypeIdentifier': identifier,
                'UTTypeTagSpecification': {'public.filename-extension': []},
            })
            declaration['UTTypeTagSpecification']['public.filename-extension'].append(extension)
            if extension in LINUX_OWN_MIME:
                declaration['UTTypeTagSpecification']['public.mime-type'] = [LINUX_OWN_MIME[extension][0]]
        else:
            identifier = MACOS_UTI[extension]
        if identifier in seen:
            continue
        seen.add(identifier)
        documents.append({
            'CFBundleTypeName': description,
            'CFBundleTypeRole': 'Viewer',
            'LSHandlerRank': 'Alternate',
            'LSItemContentTypes': [identifier],
        })
    return documents, list(imported.values())


def macos_findings(types: dict, plist_path: pathlib.Path) -> list:
    plist = plistlib.loads(plist_path.read_bytes())
    documents, imported = macos_declarations(types)
    found = []
    if plist.get('CFBundleDocumentTypes') != documents:
        found.append(f'{plist_path.name}: CFBundleDocumentTypes differs from {ASSOCIATIONS.name}')
    if plist.get('UTImportedTypeDeclarations') != imported:
        found.append(f'{plist_path.name}: UTImportedTypeDeclarations differs from {ASSOCIATIONS.name}')
    if found:
        found.append('run: python3 .github/desktop/desktop_installers.py macos --write')
    return found


def macos_write(types: dict, plist_path: pathlib.Path) -> None:
    plist = plistlib.loads(plist_path.read_bytes())
    plist['CFBundleDocumentTypes'], plist['UTImportedTypeDeclarations'] = macos_declarations(types)
    plist_path.write_bytes(plistlib.dumps(plist))


# --- Windows -----------------------------------------------------------------------------------------------------


def inno_string(text: str) -> str:
    """A quoted parameter of an Inno Setup entry: quotes doubled, a brace that is not a constant doubled."""
    return '"' + text.replace('"', '""') + '"'


def inno_text(text: str) -> str:
    """Free text (a description) in an Inno Setup parameter, braces kept as they are."""
    return inno_string(text.replace('{', '{{'))


def inno_registry(types: dict) -> str:
    command = '"{app}\\' + EXE + '" "%1"'
    icon = '"{app}\\' + EXE + '",0'
    lines = [
        '; Made by .github/desktop/desktop_installers.py from .github/desktop/file-associations.json: do not edit.',
        '; HKA is HKLM for an installation for all users, HKCU for one user. No entry writes the default value of an',
        '; extension key, which names its default program: the app is offered in "Open with" and in the Default',
        '; apps settings, never made the default.',
        '',
        '; The program, as "Open with" and its "Choose another app" list show it',
        f'Root: HKA; Subkey: "Software\\Classes\\Applications\\{EXE}"; ValueType: string; ValueName: "FriendlyAppName"; '
        f'ValueData: {inno_text(APP_NAME)}; Flags: uninsdeletekey',
        f'Root: HKA; Subkey: "Software\\Classes\\Applications\\{EXE}\\DefaultIcon"; ValueType: string; '
        f'ValueData: {inno_string(icon)}',
        f'Root: HKA; Subkey: "Software\\Classes\\Applications\\{EXE}\\shell\\open\\command"; ValueType: string; '
        f'ValueData: {inno_string(command)}',
        '',
        '; Its Capabilities, which list it in Settings, Apps, Default apps',
        'Root: HKA; Subkey: "Software\\Immuch360"; Flags: uninsdeletekeyifempty',
        'Root: HKA; Subkey: "Software\\Immuch360\\Immuch360 Desktop"; Flags: uninsdeletekey',
        f'Root: HKA; Subkey: "{CAPABILITIES}"; ValueType: string; ValueName: "ApplicationName"; '
        f'ValueData: {inno_text(APP_NAME)}',
        f'Root: HKA; Subkey: "{CAPABILITIES}"; ValueType: string; ValueName: "ApplicationDescription"; '
        f'ValueData: {inno_text(DESCRIPTION)}',
        f'Root: HKA; Subkey: "{CAPABILITIES}"; ValueType: string; ValueName: "ApplicationIcon"; '
        f'ValueData: {inno_string(icon)}',
        f'Root: HKA; Subkey: "Software\\RegisteredApplications"; ValueType: string; ValueName: {inno_text(APP_NAME)}; '
        f'ValueData: "{CAPABILITIES}"; Flags: uninsdeletevalue',
    ]
    for extension, (kind, description) in types.items():
        prog_id = PROG_ID.format(extension)
        classes = 'Software\\Classes'
        lines += [
            '',
            f'; .{extension}, a {kind}: {description}',
            f'Root: HKA; Subkey: "{classes}\\{prog_id}"; ValueType: string; ValueData: {inno_text(description)}; '
            'Flags: uninsdeletekey',
            f'Root: HKA; Subkey: "{classes}\\{prog_id}\\DefaultIcon"; ValueType: string; ValueData: {inno_string(icon)}',
            f'Root: HKA; Subkey: "{classes}\\{prog_id}\\shell\\open\\command"; ValueType: string; '
            f'ValueData: {inno_string(command)}',
            f'Root: HKA; Subkey: "{classes}\\.{extension}"; Flags: uninsdeletekeyifempty',
            f'Root: HKA; Subkey: "{classes}\\.{extension}\\OpenWithProgids"; Flags: uninsdeletekeyifempty',
            f'Root: HKA; Subkey: "{classes}\\.{extension}\\OpenWithProgids"; ValueType: string; ValueName: "{prog_id}"; '
            'ValueData: ""; Flags: uninsdeletevalue',
            f'Root: HKA; Subkey: "{classes}\\Applications\\{EXE}\\SupportedTypes"; ValueType: string; '
            f'ValueName: ".{extension}"; ValueData: ""',
            f'Root: HKA; Subkey: "{CAPABILITIES}\\FileAssociations"; ValueType: string; ValueName: ".{extension}"; '
            f'ValueData: "{prog_id}"',
        ]
    return '\n'.join(lines) + '\n'


def write_inno(types: dict, out: pathlib.Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    # With its byte order mark, Inno Setup reads the file as UTF-8 (the descriptions have a degree sign)
    out.write_text(inno_registry(types), encoding='utf-8-sig', newline='\r\n')


def find_iscc() -> str | None:
    found = shutil.which('iscc') or shutil.which('ISCC.exe')
    if found:
        return found
    for variable in ('ProgramFiles(x86)', 'ProgramFiles'):
        candidate = pathlib.Path(os.environ.get(variable, ''), 'Inno Setup 6', 'ISCC.exe')
        if os.environ.get(variable) and candidate.is_file():
            return str(candidate)
    return None


def inno_version() -> str | None:
    """The version of Inno Setup 6 Windows records for its installation, or None (not Windows, not found)."""
    try:
        import winreg
    except ImportError:
        return None
    for hive, key in ((winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'),
                      (winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'),
                      (winreg.HKEY_CURRENT_USER, r'Software\Microsoft\Windows\CurrentVersion\Uninstall')):
        try:
            with winreg.OpenKey(hive, key + r'\Inno Setup 6_is1') as handle:
                return str(winreg.QueryValueEx(handle, 'DisplayVersion')[0])
        except OSError:
            continue
    return None


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def windows(args, types: dict) -> int:
    parse_label(args.label)
    if not FILE_VERSION.match(args.file_version):
        raise Problem(f'--file-version {args.file_version!r} is not A.B.C.D')
    if not (args.bundle / EXE).is_file():
        raise Problem(f'{args.bundle} has no {EXE}: give the folder windows_bundle.py made')
    iscc = args.iscc or find_iscc()
    if not iscc:
        raise Problem('Inno Setup 6 not found: install it (https://jrsoftware.org/isinfo.php) or give --iscc')
    version = inno_version()
    if version is not None:
        print(f'Inno Setup {version}')
        if not version.startswith('6.'):
            raise Problem(f'Inno Setup {version}: packaging/windows/immuch360.iss is written for Inno Setup 6')
    args.out.mkdir(parents=True, exist_ok=True)
    associations = args.out / 'immuch360-associations.iss'
    write_inno(types, associations)
    name = f'Immuch360-Desktop-{args.label}-windows-x64-setup'
    command = [iscc, '/Qp', f'/DSourceDir={args.bundle.resolve()}', f'/DAppLabel={args.label}',
               f'/DFileVersion={args.file_version}', f'/DAssociations={associations.resolve()}',
               f'/O{args.out.resolve()}', f'/F{name}', str(ISS)]
    print(' '.join(command))
    if args.dry_run:
        return 0
    result = subprocess.run(command)
    associations.unlink()
    setup = args.out / f'{name}.exe'
    if result.returncode != 0 or not setup.is_file():
        print(f'Inno Setup failed (exit {result.returncode})')
        return 1
    print(f'installer: {setup} ({setup.stat().st_size / 1e6:.1f} MB), SHA-256 {sha256(setup)}')
    return 0


# --- Linux -------------------------------------------------------------------------------------------------------


def desktop_entry(types: dict) -> str:
    mime = []
    for extension in types:
        for name in LINUX_MIME.get(extension) or [LINUX_OWN_MIME[extension][0]]:
            if name not in mime:
                mime.append(name)
    template = (LINUX_TEMPLATES / 'immuch360.desktop.in').read_text(encoding='utf-8')
    return template.replace('@MIME_TYPES@', ';'.join(mime) + ';')


def mime_package(types: dict) -> str:
    entries = []
    for extension, (kind, description) in types.items():
        if extension not in LINUX_OWN_MIME:
            continue
        name, parent = LINUX_OWN_MIME[extension]
        entries.append(
            f'  <mime-type type="{name}">\n'
            f'    <comment>{description}</comment>\n'
            f'    <sub-class-of type="{parent}"/>\n'
            f'    <generic-icon name="{"image" if kind == "photo" else "video"}-x-generic"/>\n'
            f'    <glob pattern="*.{extension}"/>\n'
            '  </mime-type>\n')
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!-- The raw files of 360° cameras, which shared-mime-info does not know, so that the file managers offer\n'
            '     Immuch360 Desktop for them; made by .github/desktop/desktop_installers.py -->\n'
            '<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">\n'
            + ''.join(entries) + '</mime-info>\n')


def run_paths(lib: pathlib.Path, patchelf: str | None) -> None:
    """The plugins of a Flutter Linux build keep the folder they were built in as their RUNPATH (the ephemeral folder
    of the build machine): an installed package must not search a folder of the CI, so it becomes $ORIGIN, the lib
    folder itself, where the engine library they link is. The libraries load the same: the executable loads them and
    the engine from $ORIGIN/lib first."""
    for path in sorted(lib.glob('*.so*')):
        if not path.is_file() or path.read_bytes()[:4] != b'\x7fELF':
            continue
        if not patchelf:
            raise Problem('patchelf not found: install it (apt install patchelf) or give --patchelf')
        current = subprocess.run([patchelf, '--print-rpath', str(path)], capture_output=True, text=True, check=True)
        found = current.stdout.strip()
        if found and any(not part.startswith('$ORIGIN') for part in found.split(':')):
            subprocess.run([patchelf, '--set-rpath', '$ORIGIN', str(path)], check=True)
            print(f'RUNPATH of lib/{path.name}: {found} is now $ORIGIN')


def nfpm_config(stage: pathlib.Path, label: str) -> dict:
    version = linux_version(label)

    def file(relative, mode=0o644, packager=None, kind=None):
        entry = {'src': str(stage / relative), 'dst': '/' + relative, 'file_info': {'mode': mode}}
        if packager:
            entry['packager'] = packager
        if kind:
            entry['type'] = kind
        return entry

    contents = [{'src': str(stage / 'opt' / 'immuch360'), 'dst': '/opt/immuch360', 'type': 'tree'}]
    contents.append(file('usr/bin/immuch360', 0o755))
    contents.append(file(f'usr/share/applications/{APP_ID}.desktop'))
    contents.append(file(f'usr/share/mime/packages/{APP_ID}.xml'))
    contents += [file(f'usr/share/icons/hicolor/{size}x{size}/apps/{APP_ID}.png') for size in ICON_SIZES]
    contents.append(file('usr/share/doc/immuch360/copyright', packager='deb'))
    contents.append(file('usr/share/licenses/immuch360/LICENSE', packager='rpm', kind='license'))
    return {
        'name': 'immuch360',
        'arch': 'amd64',
        'platform': 'linux',
        'version': version['version'],
        'version_schema': 'none',
        'prerelease': version['prerelease'],
        'release': version['release'],
        'section': 'graphics',
        'priority': 'optional',
        'maintainer': 'FreeKC <7538438+freeKC@users.noreply.github.com>',
        'description': f'{SUMMARY}\n'
                       'Immuch360 Desktop is the computer version of Immuch360, a media app for 360° photos and\n'
                       'videos and for flat ones: the timeline and albums of your Immich server, the folders of the\n'
                       'computer, SMB, WebDAV and DLNA shares and Plex servers, in one window.',
        'vendor': 'Immuch360',
        'homepage': HOMEPAGE,
        'license': 'AGPL-3.0-only',
        'contents': contents,
        'overrides': {'deb': {'depends': DEB_DEPENDS}, 'rpm': {'depends': RPM_DEPENDS}},
        'rpm': {'group': 'Applications/Multimedia', 'summary': SUMMARY},
    }


def stage_linux(args, types: dict) -> pathlib.Path:
    bundle = args.bundle
    if not (bundle / 'immuch360').is_file() or not (bundle / 'data').is_dir() or not (bundle / 'lib').is_dir():
        raise Problem(f'{bundle} is not the bundle of flutter build linux (immuch360, data/, lib/)')
    stage = args.out / 'stage'
    if stage.exists():
        shutil.rmtree(stage)
    app = stage / 'opt' / 'immuch360'
    shutil.copytree(bundle, app, symlinks=True)
    for name in LINUX_LEFT_OUT:
        if (app / 'lib' / name).is_file():
            (app / 'lib' / name).unlink()
            print(f'left out: lib/{name}')
    run_paths(app / 'lib', args.patchelf or shutil.which('patchelf'))

    def write(relative, text, mode=0o644):
        path = stage / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8', newline='\n')
        path.chmod(mode)

    launcher = (LINUX_TEMPLATES / 'immuch360.sh.in').read_text(encoding='utf-8').replace('@LABEL@', args.label)
    write('usr/bin/immuch360', launcher, 0o755)
    write(f'usr/share/applications/{APP_ID}.desktop', desktop_entry(types))
    write(f'usr/share/mime/packages/{APP_ID}.xml', mime_package(types))
    licence = (ROOT / 'LICENSE').read_text(encoding='utf-8')
    write('usr/share/doc/immuch360/copyright',
          f'{APP_NAME}, {HOMEPAGE}\nA fork of Immich, https://github.com/immich-app/immich\n'
          'Copyright: the Immuch360 and Immich contributors\nLicense: AGPL-3.0-only\n\n' + licence)
    write('usr/share/licenses/immuch360/LICENSE', licence)
    for size in ICON_SIZES:
        target = stage / 'usr' / 'share' / 'icons' / 'hicolor' / f'{size}x{size}' / 'apps' / f'{APP_ID}.png'
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ICONS / f'app_icon_{size}.png', target)
        target.chmod(0o644)
    config = args.out / 'nfpm.json'
    config.write_text(json.dumps(nfpm_config(stage, args.label), indent=2, ensure_ascii=False) + '\n',
                      encoding='utf-8')
    return config


def linux(args, types: dict) -> int:
    version = linux_version(args.label)
    args.out.mkdir(parents=True, exist_ok=True)
    config = stage_linux(args, types)
    print(f'staged in {args.out / "stage"}, nFPM configuration {config}; package version {version["deb"]}')
    if args.stage_only:
        return 0
    nfpm = args.nfpm or shutil.which('nfpm')
    if not nfpm:
        raise Problem('nFPM not found: give --nfpm (https://nfpm.goreleaser.com)')
    made = []
    for packager, arch in (('deb', 'amd64'), ('rpm', 'x86_64')):
        target = args.out / f'Immuch360-Desktop-{args.label}-linux-{arch}.{packager}'
        result = subprocess.run([nfpm, 'package', '--config', str(config), '--packager', packager,
                                 '--target', str(target)])
        if result.returncode != 0 or not target.is_file():
            print(f'nFPM failed for the {packager} (exit {result.returncode})')
            return 1
        made.append(target)
    for target in made:
        print(f'{target.name}: {target.stat().st_size / 1e6:.1f} MB, SHA-256 {sha256(target)}')
    return 0


# --- command line ------------------------------------------------------------------------------------------------


def main(argv=None) -> int:
    # The lines of this script stay in order with those of the programs it runs (Inno Setup, nFPM, patchelf)
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--associations', type=pathlib.Path, default=ASSOCIATIONS)
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('check', help='the list, its types and Info.plist')
    check.add_argument('--plist', type=pathlib.Path, default=PLIST)
    macos = commands.add_parser('macos', help='write the document types of Info.plist')
    macos.add_argument('--plist', type=pathlib.Path, default=PLIST)
    macos.add_argument('--write', action='store_true', required=True)
    inno = commands.add_parser('inno', help='the [Registry] lines of the Windows installer')
    inno.add_argument('--out', type=pathlib.Path, required=True)
    win = commands.add_parser('windows', help='the Windows installer')
    win.add_argument('--bundle', type=pathlib.Path, required=True, help='the folder windows_bundle.py made')
    win.add_argument('--label', required=True)
    win.add_argument('--file-version', required=True)
    win.add_argument('--out', type=pathlib.Path, required=True)
    win.add_argument('--iscc', help='ISCC.exe of Inno Setup 6')
    win.add_argument('--dry-run', action='store_true', help='print the compiler command only')
    lin = commands.add_parser('linux', help='the .deb and the .rpm')
    lin.add_argument('--bundle', type=pathlib.Path, required=True, help='build/linux/x64/release/bundle')
    lin.add_argument('--label', required=True)
    lin.add_argument('--out', type=pathlib.Path, required=True)
    lin.add_argument('--nfpm', help='the nfpm program')
    lin.add_argument('--patchelf', help='the patchelf program, for the RUNPATH of the libraries')
    lin.add_argument('--stage-only', action='store_true', help='stage and write the nFPM configuration only')
    versions = commands.add_parser('versions', help='the version of the Linux packages')
    versions.add_argument('--label', required=True)
    args = parser.parse_args(argv)

    try:
        if args.command == 'versions':
            for key, value in linux_version(args.label).items():
                print(f'{key}={value}')
            return 0
        types = load(args.associations)
        if args.command == 'check':
            # The plist is compared with a list whose every type is known
            found = findings(types) or macos_findings(types, args.plist)
            for line in found:
                print(f'desktop_installers: {line}')
            if found:
                return 1
            photos = sum(1 for kind, _ in types.values() if kind == 'photo')
            print(f'{args.associations.name}: {photos} photo and {len(types) - photos} video extensions, each with its '
                  f'Linux and macOS type; {args.plist.name} declares them')
            return 0
        found = findings(types)
        if found:
            for line in found:
                print(f'desktop_installers: {line}')
            return 1
        if args.command == 'macos':
            macos_write(types, args.plist)
            print(f'{args.plist}: document types written')
            return 0
        if args.command == 'inno':
            write_inno(types, args.out)
            print(f'{args.out}: {len(types)} extensions')
            return 0
        if args.command == 'windows':
            return windows(args, types)
        return linux(args, types)
    except (Problem, OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        print(f'desktop_installers: {error}')
        return 2 if isinstance(error, OSError) else 1


if __name__ == '__main__':
    sys.exit(main())
