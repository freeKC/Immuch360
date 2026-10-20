// The app's player over a real libmpv (REV-SEC and REV-GPU of phase 2a): with what a file refers to refused
// (access-references, off from the creation of the player), a real video still opens, from its path and through the
// media bridge, given to mpv by loadfile, and the same player opens the next one. What a crafted file must not open is
// checked by mpv_references_test.dart. From the open to the first frame, no file of the temporary folder (%TEMP%, /tmp)
// holds the address (media_kit's own open writes it to a list file there for five seconds;
// desktop_player_open_test.dart checks DesktopPlayer without libmpv).
//
// On Windows the libmpv of a build of the app, on Linux the system's (libmpv_for_tests.dart): the videos of the
// folders, of the shares and of the server, and their thumbnails, play through it there.
//   flutter test test/desktop/video/desktop_player_libmpv_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/desktop/video/video_thumbnail_grabber.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:path/path.dart' as p;

import 'libmpv_for_tests.dart';
import 'mpv_measure_support.dart';

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
  final libmpv = libmpvForTests();
  final library = libmpv.library;
  final skip = libmpv.skip ?? false;

  late Directory dir;
  late File video;
  late LocalMediaBridge bridge;
  late _OneFileSystem share;

  setUpAll(() async {
    if (library == null) {
      return;
    }
    loadLibmpvForTests(library);
    dir = await Directory.systemTemp.createTemp('immuch360_player_');
    video = await aviReference(dir, width: 640, height: 360, frames: 90);
    share = _OneFileSystem(video);
    bridge = LocalMediaBridge();
    await bridge.start();
    bridge.register(share);
  });

  tearDownAll(() async {
    if (library == null) {
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
        expect(pool.created, 1, reason: 'one player for the three opens');
      } finally {
        await pool.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'from the open to the first frame, no file of the temporary folder holds the address',
    () async {
      final url = bridge.urlFor(share.source.id, '/${p.basename(video.path)}').toString();
      final token = Uri.parse(url).pathSegments.first;
      final temp = Directory.systemTemp;
      final made = <String>{};
      final watch = temp.watch(events: FileSystemEvent.create | FileSystemEvent.modify).listen((event) {
        made.add(event.path);
      });
      final player = await DesktopPlayer.create(PlayerKind.thumbnail);
      try {
        for (final (resource, secret) in [(url, token), (video.path, p.basename(video.path))]) {
          made.clear();
          final started = DateTime.now().subtract(const Duration(seconds: 1));
          final firstFrame = player.events.firstWhere((event) => event.kind != PlayerEventKind.loaded);
          await player.open(resource, streamed: resource == url);
          final event = await firstFrame.timeout(const Duration(seconds: 30));
          expect(
            event.kind,
            PlayerEventKind.restarted,
            reason: 'the first frame of ${resource == url ? 'the URL' : 'the path'}',
          );
          // media_kit's list file would still be there: it is deleted five seconds after the open
          final holding = <String>[];
          final candidates = {
            ...made,
            await for (final entity in temp.list(followLinks: false))
              if (entity is File) entity.path,
          };
          for (final path in candidates) {
            final file = File(path);
            try {
              if (!file.existsSync() || file.lengthSync() > 64 * 1024 || file.lastModifiedSync().isBefore(started)) {
                continue;
              }
              if (file.readAsStringSync().contains(secret)) {
                holding.add(path);
              }
            } catch (_) {
              // Another program's file, binary or locked
            }
          }
          expect(holding, isEmpty, reason: 'files of the temporary folder that hold the address');
        }
      } finally {
        await watch.cancel();
        await player.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
