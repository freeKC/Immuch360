// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

import 'package:meta/meta.dart';

import 'libsmb2_bindings.dart';

/// Package-internal override for the libsmb2 path. Setting this from a
/// test's `setUpAll` makes every subsequent [openLibSmb2] call open the
/// binary at the given path instead of the platform-default loader name.
///
/// Lives here (and not on [Smb2Client]) so the worker isolate code can
/// read it without an extra dependency cycle. The package never exposes
/// it as public API — production callers always resolve through the
/// Flutter ffiPlugin loader paths below.
@internal
String? debugLibSmb2PathOverride;

/// Open the bundled libsmb2 binary and return a [DynamicLibrary].
///
/// The path is fixed per platform — the Flutter plugin mechanism (see
/// `pubspec.yaml` `ffiPlugin: true`) places the right binary under the
/// loader's search path for every supported OS:
///
///   - macOS:   `libsmb2.framework/libsmb2`
///   - Android: `libsmb2.so`
///   - Linux:   `libsmb2.so`
///   - Windows: `libsmb2.dll`
///   - iOS:     resolved via [DynamicLibrary.process] because the
///              framework is statically linked into the host app.
ffi.DynamicLibrary openLibSmb2() {
  final override = debugLibSmb2PathOverride;
  if (override != null && override.isNotEmpty) {
    return ffi.DynamicLibrary.open(override);
  }
  if (Platform.isMacOS) {
    return ffi.DynamicLibrary.open('libsmb2.framework/libsmb2');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return ffi.DynamicLibrary.open('libsmb2.so');
  }
  if (Platform.isWindows) {
    return ffi.DynamicLibrary.open('libsmb2.dll');
  }
  if (Platform.isIOS) {
    return ffi.DynamicLibrary.process();
  }
  throw UnsupportedError(
    'dart_smb2: unsupported platform ${Platform.operatingSystem}',
  );
}

/// Build a [LibSmb2Bindings] over a freshly-opened library handle.
///
/// Each isolate that needs to call libsmb2 should hold its own bindings
/// instance — the bindings are cheap (just lazy symbol lookups) and the
/// underlying `DynamicLibrary` is cached by the OS loader so repeated
/// `dlopen` of the same path return the same handle.
LibSmb2Bindings openLibSmb2Bindings() => LibSmb2Bindings(openLibSmb2());
