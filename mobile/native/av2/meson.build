# SPDX-License-Identifier: AGPL-3.0-only
# immuch360-av2, the AV2 companion of Immuch360 Desktop, linked statically with the library of dav2d. dav2d is a
# subproject: .github/desktop/av2/av2_build.py sources puts it in subprojects/dav2d at the commit of av2.lock.json,
# without its command line tools (their getopt.c of Windows would add a licence) and without its tests.
project('immuch360-av2', 'c',
  version: '1',
  license: 'AGPL-3.0-only',
  meson_version: '>= 0.60.0',
  default_options: [
    'c_std=c11',
    'buildtype=release',
    'default_library=static',
    'warning_level=2',
    'b_ndebug=true',
  ])

cc = meson.get_compiler('c')
dav2d = subproject('dav2d', default_options: [
  'default_library=static',
  'enable_tools=false',
  'enable_tests=false',
  'enable_examples=false',
  'enable_docs=false',
])

dependencies = [dav2d.get_variable('dav2d_dep'), dependency('threads')]
arguments = [
  '-DAV2_SOURCE_COMMIT="@0@"'.format(get_option('source_commit')),
  '-DAV2_DAV2D_COMMIT="@0@"'.format(get_option('dav2d_commit')),
]
if host_machine.system() == 'windows'
  dependencies += [cc.find_library('ws2_32'), cc.find_library('shell32')]
  arguments += ['-D_CRT_SECURE_NO_WARNINGS', '-D_WIN32_WINNT=0x0601']
endif

executable('immuch360-av2',
  files('src/main.c', 'src/platform.c', 'src/probe.c', 'src/serve.c', 'src/stream.c'),
  dependencies: dependencies,
  c_args: arguments,
  install: true)
