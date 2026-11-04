// The y4m of an AV2 companion through a real libmpv (lot AD3; the risk of plan section 9: a seek in a y4m served over
// HTTP was seen with FFmpeg 5.1 and 7.1 only): on Windows the libmpv of a build of the app, on Linux the system's, the
// libmpv1 of Ubuntu 22.04 and its FFmpeg 4.4 on the Linux job of the desktop workflow (libmpv_for_tests.dart). The
// companion is the compiled fake (IMMUCH360_FAKE_AV2), which serves the same y4m as the real one over a test pattern:
// the player of the app opens it with the options of an AV2 video, reads the duration the length gives, seeks by a byte
// range to the picture asked (the companion restarting at the access point before it), and the thumbnail grabber takes
// a frame of it. Without both, skipped.
//   IMMUCH360_FAKE_AV2=<fake> flutter test test/desktop/video/av2/av2_libmpv_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/video/av2_playback.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/desktop/video/video_thumbnail_grabber.dart';
import 'package:path/path.dart' as p;

import '../libmpv_for_tests.dart';
import 'av2_test_support.dart';

void main() {
  final libmpv = libmpvForTests();
  final library = libmpv.library;
  final Object skip = libmpv.skip ?? skipWithoutFakeAv2;

  late Directory folder;
  late File clip;
  late Av2Playbacks playbacks;

  setUpAll(() {
    if (library == null || fakeAv2Program == null) {
      return;
    }
    loadLibmpvForTests(library);
  });

  setUp(() {
    folder = Directory.systemTemp.createTempSync('av2-libmpv-');
    // 240 pictures at 30 a second, a key frame every 6: 8 s of video
    clip = File(p.join(folder.path, 'phare.ivf'))
      ..writeAsBytesSync(repeatAv2Ivf(av2Fixture('av2-256x144-8bit.ivf'), 20));
    final runner = ManagedProcessRunner(journal: ProcessJournal(File(p.join(folder.path, 'processes.json'))));
    playbacks = Av2Playbacks(
      companion: () async => (program: fakeAv2Program!, launcher: null),
      runner: (_) => EnvironmentRunner(runner, {'IMMUCH360_FAKE_AV2_FPS': '400'}),
      enabled: () => true,
      decoderVersion: 'fake',
      parentPid: pid,
    );
  });

  tearDown(() async {
    await playbacks.releaseAll();
    folder.deleteSync(recursive: true);
  });

  Future<PlayerEvent> next(DesktopPlayer player) =>
      player.events.firstWhere((event) => event.kind != PlayerEventKind.loaded).timeout(const Duration(seconds: 30));

  test(
    'the player opens the y4m with its duration, seeks by a byte range to the picture asked, and pauses',
    () async {
      final url = await playbacks.open(Av2Bytes.file(clip.path));
      final session = playbacks.sessionOf(url)!;
      final player = await DesktopPlayer.create(PlayerKind.thumbnail);
      try {
        final opened = next(player);
        await player.open(url, streamed: true);
        expect((await opened).kind, PlayerEventKind.restarted, reason: 'a first frame of the y4m');
        final watch = Stopwatch()..start();
        while (player.duration.value == Duration.zero && watch.elapsed < const Duration(seconds: 10)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(player.duration.value.inMilliseconds, closeTo(8000, 40), reason: 'the length of the y4m tells it');
        expect(session.requestedFrame.value, 0);

        // Five seconds in: picture 150, an access point; mpv asks for its bytes
        final sought = next(player);
        await player.seek(const Duration(seconds: 5));
        expect((await sought).kind, PlayerEventKind.restarted, reason: 'a frame after the seek');
        expect(session.requestedFrame.value, inInclusiveRange(140, 150), reason: 'a range at the picture asked');
        expect(player.position.value.inMilliseconds, closeTo(5000, 100));

        // Back to 1.1 s: picture 33, the companion restarts at 30
        final back = next(player);
        await player.seek(const Duration(milliseconds: 1100));
        expect((await back).kind, PlayerEventKind.restarted);
        expect(session.requestedFrame.value, inInclusiveRange(25, 33));
        expect(session.failure.value, isNull);
        // The stat line comes every half second
        final stat = Stopwatch()..start();
        while ((session.stat.value?.generation ?? 0) < 2 && stat.elapsed < const Duration(seconds: 3)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(session.stat.value?.generation, greaterThanOrEqualTo(2), reason: 'restarted at least once');
      } finally {
        await player.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'the thumbnail of an AV2 video comes from its companion, which is gone after the grab',
    () async {
      final pool = PlayerPool(create: DesktopPlayer.create);
      final grabber = VideoThumbnailGrabber(pool: pool, av2: () => playbacks);
      try {
        final frame = await grabber.grab(
          clip.path,
          time: const Duration(seconds: 1),
          box: (width: 160, height: 160, cover: false),
        );
        expect(frame, isNotNull);
        expect(frame!.sublist(0, 2), [0xFF, 0xD8], reason: 'a JPEG');
        expect(playbacks.sessions, isEmpty, reason: 'the companion of the grab let go');
      } finally {
        await pool.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
