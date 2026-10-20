// The real libmpv of the tests that need one (camera_live_libmpv_test, desktop_player_libmpv_test,
// mpv_references_test): on Windows the libmpv-2.dll of a build of the app, the one its ZIP ships; on Linux the
// system's, as the .deb and the .rpm bring it (libmpv2 or libmpv1, mpv-libs on Fedora; libmpv-dev on the Linux job of
// the desktop workflow). Elsewhere, or without one, those tests are skipped.
//
//   Windows: flutter build windows --debug -t lib/main_desktop.dart, then flutter test <file>
//            (IMMUCH360_BUILD_DIR may name another folder holding libmpv-2.dll)
//   Linux:   apt install libmpv2 (or libmpv1), then flutter test <file>
//            (IMMUCH360_LIBMPV may name another libmpv.so)

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// The libmpv to load, or why the tests that need one are skipped
typedef LibmpvForTests = ({String? library, String? skip});

/// The folder of the Windows build that holds libmpv, null when there is none
String? _windowsBuildDir() {
  final given = Platform.environment['IMMUCH360_BUILD_DIR'];
  final candidates = [
    if (given != null && given.isNotEmpty) given,
    for (final mode in ['Debug', 'Profile', 'Release']) p.join('build', 'windows', 'x64', 'runner', mode),
  ];
  for (final dir in candidates) {
    if (File(p.join(dir, 'libmpv-2.dll')).existsSync()) {
      return p.absolute(dir);
    }
  }
  return null;
}

/// The system's libmpv on Linux, under the first name media_kit's NativeLibrary would open
String? _linuxLibrary() {
  final given = Platform.environment['IMMUCH360_LIBMPV'];
  for (final name in [if (given != null && given.isNotEmpty) given, 'libmpv.so', 'libmpv.so.2', 'libmpv.so.1']) {
    try {
      DynamicLibrary.open(name);
      return name;
    } catch (_) {
      // Not this name
    }
  }
  return null;
}

LibmpvForTests libmpvForTests() {
  if (Platform.isWindows) {
    final dir = _windowsBuildDir();
    return dir == null
        ? (
            library: null,
            skip: 'no Windows build with libmpv-2.dll (flutter build windows first, or set IMMUCH360_BUILD_DIR)',
          )
        : (library: p.join(dir, 'libmpv-2.dll'), skip: null);
  }
  if (Platform.isLinux) {
    final library = _linuxLibrary();
    return library == null
        ? (library: null, skip: 'no libmpv on this Linux (install libmpv2 or libmpv1, or set IMMUCH360_LIBMPV)')
        : (library: library, skip: null);
  }
  return (library: null, skip: 'a real libmpv: Windows after a build, or Linux with the system\'s');
}

/// Loads [library] for media_kit; on Windows the DLLs next to it (ANGLE, the libraries libmpv needs) are found too
void loadLibmpvForTests(String library) {
  if (Platform.isWindows) {
    final setDllDirectory = DynamicLibrary.open(
      'kernel32.dll',
    ).lookupFunction<Int32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('SetDllDirectoryW');
    using((arena) => setDllDirectory(p.dirname(library).toNativeUtf16(allocator: arena)));
  }
  MediaKit.ensureInitialized(libmpv: library);
}
