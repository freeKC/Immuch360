// The screens of the AV2 videos wired to their playback in the app (av2_app.dart, lot AD6 of store/m2/av2-2026-11-02/
// plan-2026-11-02.md): the gate reads the format from the probe of the companion, which the player's open then takes
// rather than probing again; the speed measured here for that format brings the notice of a computer too slow before
// the player; "Play anyway" tells the playback; the "Video decoding" line follows the session the player plays; the
// errors of the playback give their reason to the screens (the failure panel: video_failure_panel_test.dart); the
// library takes the frame of an AV2 video through the app's grabber once the playbacks are made.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/platform/desktop_local_image_api.dart';
import 'package:immich_mobile/desktop/video/av2_app.dart';
import 'package:immich_mobile/desktop/video/av2_decoding.dart';
import 'package:immich_mobile/desktop/video/av2_playback.dart';
import 'package:immich_mobile/desktop/video/desktop_video_view.dart';
import 'package:immich_mobile/domain/services/av2_stream.dart';

import 'av2_test_support.dart';

const _head = Av2Head.ivf(width: 256, height: 144, rate: 30, scale: 1, framesInHeader: 12, headerLength: 32);
const _path = '/clips/video.ivf';

Future<void> _until(bool Function() condition, {Duration timeout = const Duration(seconds: 10)}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) {
      fail('waited ${timeout.inSeconds} s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late ScriptedAv2Runner runner;
  late MemoryShare share;
  late List<(Av2Format, String)> asked;
  Av2SpeedMeasure? measure;
  var on = true;

  setUp(() {
    runner = ScriptedAv2Runner();
    share = MemoryShare(av2Fixture('av2-256x144-8bit.ivf'), path: _path);
    asked = [];
    measure = null;
    on = true;
  });

  Av2Playbacks playbacks({bool installed = true}) => Av2Playbacks(
    companion: () async => installed ? (program: 'immuch360-av2', launcher: null) : null,
    runner: (_) => runner,
    enabled: () => on,
    decoderVersion: '30140b5-1',
    loadMeasure: (format, decoder) async {
      asked.add((format, decoder));
      return measure;
    },
  );

  Av2VideoRef shared() => const Av2VideoRef.share('av2-share', _path, _head);

  /// The player's open of the share's file, once its serve listens
  Future<String> open(Av2Playbacks playbacks, {bool forThumbnail = false}) async {
    final serves = runner.serves.length;
    final opening = playbacks.open(Av2Bytes.share(share, _path), forThumbnail: forThumbnail);
    await _until(() => runner.serves.length > serves);
    runner.serves.last.say(av2ListeningLine);
    return opening;
  }

  group('the format the gate shows', () {
    test('the size and the depth of the first picture the probe read, the frame rate of the container', () {
      final probe = Av2Probe.fromJson(av2ProbeJson(bits: 10));
      expect(
        av2FormatOfProbe(_head, probe),
        const Av2VideoFormat(width: 256, height: 144, frameRate: 30, bitDepth: 10),
      );
      // A Section 5 stream plays at 30 frames a second, its size from the probe
      expect(
        av2FormatOfProbe(const Av2Head.obu(), Av2Probe.fromJson(av2ProbeJson())),
        const Av2VideoFormat(width: 256, height: 144, frameRate: 30, bitDepth: 8),
      );
    });

    test('a stream the decoder does not play is named as the playback refuses it', () {
      final refused = Av2Probe.fromJson(av2ProbeJson(playable: false, refusal: '4:4:4 10-bit'));
      expect(av2FormatOfProbe(_head, refused).refusedFormat, '4:4:4 10-bit');
      final unnamed = Av2Probe.fromJson(av2ProbeJson(playable: false));
      expect(av2FormatOfProbe(_head, unnamed).refusedFormat, '4:2:0 8-bit');
      expect(av2FormatOfProbe(_head, unnamed).width, 256, reason: 'the size of its head');
    });
  });

  group('the probe of the gate, then the player', () {
    test('the player opens with the probe the gate had made: one probe for both', () async {
      final app = playbacks();
      final format = await av2ProbeFormat(app, shared(), shareOf: (_) async => share);
      expect(format, const Av2VideoFormat(width: 256, height: 144, frameRate: 30, bitDepth: 8));
      expect(runner.launchesOf('probe'), hasLength(1));
      // A share is probed through the standard input, from its first bytes
      expect(runner.launchesOf('probe').single.arguments, ['probe', '-']);

      final url = await open(app);
      expect(runner.launchesOf('probe'), hasLength(1), reason: 'the open took the probe of the gate');
      await app.release(url);

      await app.release(await open(app));
      expect(runner.launchesOf('probe'), hasLength(2), reason: 'a probe serves one open only');
    });

    test('a thumbnail probes for itself and leaves the probe of the gate to the player', () async {
      final app = playbacks();
      await av2ProbeFormat(app, shared(), shareOf: (_) async => share);
      await app.release(await open(app, forThumbnail: true));
      expect(runner.launchesOf('probe'), hasLength(2));
      await app.release(await open(app));
      expect(runner.launchesOf('probe'), hasLength(2), reason: 'the player took the probe of the gate');
    });

    test('turned off or without the decoder, the probe says so and runs nothing', () async {
      on = false;
      await expectLater(
        av2ProbeFormat(playbacks(), shared(), shareOf: (_) async => share),
        throwsA(isA<Av2TurnedOff>()),
      );
      on = true;
      await expectLater(
        av2ProbeFormat(playbacks(installed: false), shared(), shareOf: (_) async => share),
        throwsA(isA<Av2DecoderMissing>()),
      );
      expect(runner.launches, isEmpty);
    });
  });

  group('the speed measured here', () {
    test('the last measure of the format with this decoder, against the frame rate of the video', () async {
      final app = playbacks();
      const format = Av2VideoFormat(width: 3840, height: 2160, frameRate: 24, bitDepth: 10);
      expect(await av2MeasuredSpeed(format, load: app.loadMeasure, decoder: app.decoderVersion), isNull);
      measure = const Av2SpeedMeasure(
        format: Av2Format(width: 3840, height: 2160, bits: 10, frameRate: 24),
        fps: 5.9,
        decoder: '30140b5-1',
      );
      final speed = await av2MeasuredSpeed(format, load: app.loadMeasure, decoder: app.decoderVersion);
      expect(speed, const Av2Speed(decodedFps: 5.9, neededFps: 24));
      expect(speed!.tooSlow, isTrue);
      expect(asked.last, (const Av2Format(width: 3840, height: 2160, bits: 10, frameRate: 24), '30140b5-1'));
    });

    test('a format not fully known has no measure', () async {
      final app = playbacks();
      const format = Av2VideoFormat(width: 256, height: 144, frameRate: 30);
      expect(await av2MeasuredSpeed(format, load: app.loadMeasure, decoder: app.decoderVersion), isNull);
      expect(asked, isEmpty);
    });
  });

  group('the app overrides', () {
    test('the gate of the app asks the playback: the probe, the speed, and Play anyway lets the player in', () async {
      final app = playbacks();
      measure = const Av2SpeedMeasure(
        format: Av2Format(width: 256, height: 144, bits: 8, frameRate: 30),
        fps: 12,
        decoder: '30140b5-1',
      );
      final container = ProviderContainer(
        overrides: [...av2AppOverrides(), av2PlaybacksProvider.overrideWithValue(app)],
      );
      addTearDown(container.dispose);
      const video = Av2VideoRef.file('/clips/video.ivf', _head);
      final format = await container.read(av2ProbeProvider)(video);
      expect(runner.launchesOf('probe').single.arguments, ['probe', '/clips/video.ivf']);
      final speed = await container.read(av2SpeedProvider)(format);
      expect(speed, const Av2Speed(decodedFps: 12, neededFps: 30));

      // The player's own check of the measure stops a format too slow, until Play anyway
      final file = MemoryShare(av2Fixture('av2-256x144-8bit.ivf'), path: _path);
      await expectLater(app.open(Av2Bytes.share(file, _path)), throwsA(isA<Av2TooSlow>()));
      container.read(av2PlayAnywayProvider)(const Av2VideoRef.share('av2-share', _path, _head));
      share = file;
      final url = await open(app);
      expect(app.sessionOf(url), isNotNull);
      await app.release(url);
    });

    test('without the app (the tests, the phones) the gate takes the head and knows no speed', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final format = await container.read(av2ProbeProvider)(const Av2VideoRef.file('/a.ivf', _head));
      expect(format, Av2VideoFormat.ofHead(_head));
      expect(await container.read(av2SpeedProvider)(format), isNull);
      container.read(av2PlayAnywayProvider)(const Av2VideoRef.file('/a.ivf', _head));
    });
  });

  group('the speed in the details', () {
    test('follows the session the player plays, never a thumbnail, and is gone once the player lets go', () async {
      final app = playbacks();
      final target = ValueNotifier<Av2DecodingStats?>(null);
      final follower = Av2DecodingFollower(app.playing, target);
      addTearDown(follower.dispose);

      final thumbnail = await open(app, forThumbnail: true);
      expect(target.value, isNull, reason: 'a thumbnail plays nothing');
      await app.release(thumbnail);

      final url = await open(app);
      expect(target.value, const Av2DecodingStats(neededFps: 30));
      runner.serves.last.say('stat decoded=24 served=12 fps=120.5 simd=avx2 gen=1 frame=12 serving=1');
      await _until(() => target.value?.decodedFps != null);
      expect(target.value, const Av2DecodingStats(neededFps: 30, decodedFps: 120.5, simd: 'avx2'));
      expect(target.value!.lacksAvx2, isFalse);
      runner.serves.last.say('stat decoded=48 served=24 fps=40.0 simd=sse41 gen=1 frame=24 serving=1');
      await _until(() => target.value?.simd == 'sse41');
      expect(target.value!.lacksAvx2, isTrue);

      await app.release(url);
      expect(target.value, isNull);
    });
  });

  group('the errors of the playback', () {
    test('give their reason after "The AV2 decoder stopped on this video:", never the sentence twice', () {
      expect(av2ErrorReason(const Av2DecoderStopped('it crashed (code 0xC0000005)')), 'it crashed (code 0xC0000005)');
      expect(
        av2ErrorReason(const Av2FormatRefused('4:4:4 10-bit')),
        'This AV2 video is 4:4:4 10-bit: this version of the AV2 decoder does not play it yet',
      );
      expect(av2ErrorReason(const Av2DecoderMissing()), 'The AV2 decoder is not installed');
      expect(av2ErrorReason(const Av2NotAv2('its first bytes')), 'not an AV2 stream: its first bytes');
    });
  });

  group('the thumbnails of the library', () {
    test('take the frame of an AV2 video through the app grabber once the playbacks are made', () {
      DesktopLocalImageApi.av2FrameGrab = null;
      final container = ProviderContainer();
      expect(container.read(av2PlaybacksProvider), same(Av2Playbacks.app));
      expect(DesktopLocalImageApi.av2FrameGrab, DesktopLocalImageApi.appVideoFrame);
      container.dispose();
      expect(Av2Playbacks.app, isNull);
      expect(DesktopLocalImageApi.av2FrameGrab, isNull);
    });

    test('without libmpv the app grabber gives no frame', () async {
      expect(await DesktopLocalImageApi.appVideoFrame('/clips/video.ivf', 320), isNull);
    });
  });

  test('the frames of the fixtures are what they were', () {
    // The probe of the support is that of the 8-bit fixture: 256x144, 12 pictures at 30 a second
    final head = readAv2Head(Uint8List.sublistView(av2Fixture('av2-256x144-8bit.ivf'), 0, av2HeadLength));
    expect(head, _head);
  });
}
