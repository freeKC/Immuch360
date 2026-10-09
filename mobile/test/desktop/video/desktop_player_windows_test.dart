// The app's player over the libmpv of the Windows build (REV-SEC and REV-GPU of phase 2a): with what a file refers to
// refused (access-references, turned off as mpv loads each file and on again for media_kit's list of one entry), a
// real video still opens, from its path and through the media bridge, and the same player opens the next one. What a
// crafted file must not open is checked by mpv_references_test.dart.
//
// Windows only, after a Windows build of the app (it holds libmpv-2.dll):
//   flutter build windows --debug -t lib/main_desktop.dart
//   flutter test test/desktop/video/desktop_player_windows_test.dart
// IMMUCH360_BUILD_DIR may name another folder holding libmpv-2.dll.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/desktop/video/video_thumbnail_grabber.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import 'mpv_measure_support.dart';

/// The folder of the Windows build that holds libmpv, null when there is none
String? _buildDir() {
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

/// One file of this computer as a share, for the media bridge
class _OneFileSystem implements NetworkFileSystem {
  _OneFileSystem(this._file);

  final File _file;

  @override
  final NetworkSource source = const NetworkSource(
    id: 'player-test',
    type: NetworkSourceType.smb,
    name: 'player',
    host: 'localhost',
  );

  @override
  Future<List<NetworkEntry>> list(String path) async => const [];

  @override
  Future<NetworkEntry> stat(String path) async =>
      NetworkEntry(sourceId: source.id, path: path, isDirectory: false, size: await _file.length());

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async {
    final file = await _file.open();
    try {
      await file.setPosition(offset);
      return await file.read(length);
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> close() async {}
}

bool _isJpeg(Uint8List? bytes) => bytes != null && bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;

void main() {
  final buildDir = Platform.isWindows ? _buildDir() : null;
  final skip = !Platform.isWindows
      ? 'libmpv of the Windows build: Windows only'
      : buildDir == null
      ? 'no Windows build with libmpv-2.dll (flutter build windows first, or set IMMUCH360_BUILD_DIR)'
      : false;

  late Directory dir;
  late File video;
  late LocalMediaBridge bridge;
  late _OneFileSystem share;

  setUpAll(() async {
    if (buildDir == null) {
      return;
    }
    final setDllDirectory = DynamicLibrary.open(
      'kernel32.dll',
    ).lookupFunction<Int32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('SetDllDirectoryW');
    using((arena) => setDllDirectory(buildDir.toNativeUtf16(allocator: arena)));
    MediaKit.ensureInitialized(libmpv: p.join(buildDir, 'libmpv-2.dll'));
    dir = await Directory.systemTemp.createTemp('immuch360_player_');
    video = await aviReference(dir, width: 640, height: 360, frames: 90);
    share = _OneFileSystem(video);
    bridge = LocalMediaBridge();
    await bridge.start();
    bridge.register(share);
  });

  tearDownAll(() async {
    if (buildDir == null) {
      return;
    }
    await bridge.stop();
    await dir.delete(recursive: true);
  });

  test(
    'a real video opens from its path and through the bridge, again and again in the same player',
    () async {
      final pool = PlayerPool(create: DesktopPlayer.create);
      final grabber = VideoThumbnailGrabber(pool: pool);
      final url = bridge.urlFor(share.source.id, '/${p.basename(video.path)}').toString();
      try {
        for (final resource in [video.path, url, video.path]) {
          final frame = await grabber.grab(
            resource,
            time: const Duration(seconds: 1),
            box: (width: 160, height: 160, cover: false),
          );
          expect(_isJpeg(frame), isTrue, reason: 'a frame of ${resource == url ? 'the bridge URL' : 'the path'}');
        }
        expect(pool.created, 1, reason: 'one player, its references turned on and off at each open');
      } finally {
        await pool.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
