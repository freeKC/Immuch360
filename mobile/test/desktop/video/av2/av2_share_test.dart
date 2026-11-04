// An AV2 video read from a real share, end to end (review of lot AD6, m4: the lots read a MemoryShare only): a WebDAV
// server holding the clips of the test build, the app's WebDAV client (WebDavFileSystem, NetworkFileSystem.readRange
// for every byte), the real AV2 decoder of an archive of the CI, the media bridge of the app and a real libmpv (on Linux
// the system's, libmpv_for_tests.dart). The share lists the clip, its head says AV2 from 32 bytes read through the
// network; before the decoder is installed the frame of its tile is "not yet"; installed, the frame of the tile comes
// through the bridge URL and the companion, then the player opens the video from the share: indexed in ... from a
// share in the log, the duration its length gives, a seek to the middle and the end of the video. The log of the run
// goes to IMMUCH360_AV2_SHARE_LOG when given (lots/AD11-data of the plan). Without the variables below, skipped:
//   IMMUCH360_AV2_SHARE=http://127.0.0.1:8090/  the WebDAV share (anonymous)
//   IMMUCH360_AV2_DECODER=<folder>              the files of an av2-decoder archive (immuch360-av2, immuch360-run)
//   IMMUCH360_AV2_SHARE_CLIP=/fremantle-lighthouse-1080p30-av2.ivf   the clip (this one by default)
//   IMMUCH360_AV2_SHARE_LOG=<file>              where the log of the run is written

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/video/av2_playback.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/desktop/video/video_thumbnail_grabber.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/av2_stream.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/infrastructure/network/webdav_file_system.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../libmpv_for_tests.dart';

void main() {
  final environment = Platform.environment;
  final shareUrl = environment['IMMUCH360_AV2_SHARE'];
  final decoder = environment['IMMUCH360_AV2_DECODER'];
  final clip = environment['IMMUCH360_AV2_SHARE_CLIP'] ?? '/fremantle-lighthouse-1080p30-av2.ivf';
  final logFile = environment['IMMUCH360_AV2_SHARE_LOG'];
  final libmpv = libmpvForTests();
  final Object skip =
      libmpv.skip ??
      (shareUrl == null || decoder == null
          ? 'no share or decoder (IMMUCH360_AV2_SHARE, IMMUCH360_AV2_DECODER)'
          : false);

  setUpAll(() {
    if (skip == false) {
      loadLibmpvForTests(libmpv.library!);
    }
  });

  test(
    'a WebDAV share: listed, AV2 from its head, no frame before the decoder, then its frame and the video from it',
    () async {
      final lines = <String>[];
      final level = Logger.root.level;
      Logger.root.level = Level.FINE;
      final listening = Logger.root.onRecord.listen(
        (record) => lines.add('${record.time.toIso8601String()} ${record.loggerName} ${record.message}'),
      );
      // The listing of a share on a computer, where .ivf and .obu are videos
      debugDefaultTargetPlatformOverride = Platform.isWindows
          ? TargetPlatform.windows
          : Platform.isMacOS
          ? TargetPlatform.macOS
          : TargetPlatform.linux;
      final folder = Directory.systemTemp.createTempSync('av2-share-');
      final bridge = LocalMediaBridge();
      final pool = PlayerPool(create: DesktopPlayer.create);
      WebDavFileSystem? share;
      Av2Playbacks? playbacks;
      void note(String line) => lines.add('${DateTime.now().toIso8601String()} test $line');
      try {
        final address = Uri.parse(shareUrl!);
        final source = NetworkSource(
          id: 'ad11-webdav',
          type: NetworkSourceType.webdav,
          name: 'AVT clips',
          host: address.host,
          port: address.port,
        );
        share = await WebDavFileSystem.open(source, null);
        final listed = await share.list('/');
        final entry = listed.singleWhere((entry) => '/${entry.name}' == clip);
        note('listed ${listed.length} entries; ${entry.name}: ${entry.size} bytes, a video: ${entry.isVideo}');
        expect(entry.isVideo, isTrue, reason: 'an .ivf is a video on the computers');
        final head = readAv2Head(await share.readRange(clip, 0, av2HeadLength));
        note('head: $head');
        expect(head, isNotNull, reason: 'AV2 from its first bytes, read through the share');

        await bridge.start();
        bridge.register(share);
        final url = bridge.urlFor(source.id, clip).toString();
        var installed = false;
        playbacks = Av2Playbacks(
          companion: () async => installed ? av2CompanionFilesIn(p.join(decoder!, av2ProgramFileName())) : null,
          runner: (launcher) => ManagedProcessRunner(
            linuxLauncher: launcher,
            journal: ProcessJournal(File(p.join(folder.path, 'processes.json'))),
          ),
          enabled: () => true,
          decoderVersion: '30140b5-1',
          parentPid: pid,
          bridge: bridge.fileOf,
        );
        final grabber = VideoThumbnailGrabber(pool: pool, av2: () => playbacks);
        const box = (width: 320, height: 320, cover: true);

        // The tile of the share before the decoder is installed: no frame yet, asked again once it is
        await expectLater(
          grabber.grab(url, time: const Duration(seconds: 1), box: box),
          throwsA(isA<VideoFrameNotYet>()),
        );
        note('before the installation: no frame yet');
        installed = true;
        final watch = Stopwatch()..start();
        final frame = await grabber.grab(url, time: const Duration(seconds: 1), box: box);
        note('the frame of the tile after the installation: ${frame?.length} bytes in ${watch.elapsedMilliseconds} ms');
        expect(frame, isNotNull);
        expect(frame!.sublist(0, 2), [0xFF, 0xD8], reason: 'a JPEG');
        if (logFile != null) {
          File(p.join(p.dirname(logFile), 'share-tile.jpg')).writeAsBytesSync(frame);
        }
        expect(playbacks.sessions, isEmpty, reason: 'the companion of the grab let go');

        // The player opens the video of the share through its companion
        watch.reset();
        final served = await playbacks.open(Av2Bytes.share(share, clip));
        final session = playbacks.sessionOf(served)!;
        note('served in ${watch.elapsedMilliseconds} ms: ${session.format}, ${session.layout.frames} pictures');
        expect(lines.where((line) => line.contains('from a share), read and probed in')), isNotEmpty);
        final player = await DesktopPlayer.create(PlayerKind.thumbnail);
        try {
          Future<PlayerEvent> next() => player.events
              .firstWhere((event) => event.kind != PlayerEventKind.loaded)
              .timeout(const Duration(seconds: 60));
          final opened = next();
          await player.open(served, streamed: true);
          expect((await opened).kind, PlayerEventKind.restarted, reason: 'a first frame of the share');
          note('first frame ${watch.elapsedMilliseconds} ms after the open');
          final until = Stopwatch()..start();
          while (player.duration.value == Duration.zero && until.elapsed < const Duration(seconds: 10)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          final expected = session.layout.frames * 1000 ~/ session.neededFps;
          expect(player.duration.value.inMilliseconds, closeTo(expected, 50));
          for (final at in [const Duration(seconds: 5), Duration(milliseconds: expected - 500)]) {
            watch.reset();
            final sought = next();
            await player.seek(at);
            expect((await sought).kind, PlayerEventKind.restarted, reason: 'a frame after the seek to $at');
            note('seek to $at: a frame in ${watch.elapsedMilliseconds} ms, picture ${session.requestedFrame.value}');
            expect(player.position.value.inMilliseconds, closeTo(at.inMilliseconds, 100));
          }
          expect(session.failure.value, isNull);
        } finally {
          await player.dispose();
        }
        await playbacks.release(served);
        expect(playbacks.sessions, isEmpty);
      } finally {
        await playbacks?.releaseAll();
        await pool.dispose();
        await bridge.stop();
        await share?.close();
        debugDefaultTargetPlatformOverride = null;
        Logger.root.level = level;
        await listening.cancel();
        folder.deleteSync(recursive: true);
        if (logFile != null) {
          File(logFile).writeAsStringSync('${lines.join('\n')}\n');
        }
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
