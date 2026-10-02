// Where the tests that need a real libsmb2 (IMMUCH_NET_TESTS=1) load it from

import 'dart:io';
import 'dart:isolate';

/// The libsmb2 to load in the tests, null to let the loader find "libsmb2.so"
String? libsmb2TestPath() {
  final given = Platform.environment['IMMUCH_LIBSMB2'];
  if (given != null && given.isNotEmpty) {
    return given;
  }
  final home = Platform.environment['HOME'];
  if (home != null) {
    final cached = File('$home/.cache/immuch-net-tests/libsmb2.so');
    if (cached.existsSync()) {
      return cached.path;
    }
  }
  final library = Isolate.resolvePackageUriSync(Uri.parse('package:dart_smb2/dart_smb2.dart'));
  if (library != null) {
    final arch = Platform.version.contains('arm64') ? 'aarch64' : 'x86_64';
    final bundled = File.fromUri(library.resolve('../linux/libs/$arch/libsmb2.so'));
    if (bundled.existsSync()) {
      return bundled.path;
    }
  }
  return null;
}
