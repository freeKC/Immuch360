import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/stabilization.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/gopro_eac.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/raw/raw_video_plan.dart';
import 'package:immich_mobile/domain/services/raw/raw_video_stabilization.dart';
import 'package:immich_mobile/domain/services/raw/stabilization.dart';
import 'package:immich_mobile/platform/spherical_video_api.g.dart';

import '../../../fixtures/raw/insta360_motion_slices.dart';
import '../../../fixtures/raw/stabilization_slices.dart';
import '../../../fixtures/raw/stabilization_videos.dart';

// The stabilisation of a raw video from its file to the native player (issue 14, lot c): which cameras, the request,
// the table built in a background isolate that asks this one for its reads, and the two messages to the player.

/// The input of [file], opened and closed as the plan does it
class _File {
  _File(this.bytes, {this.size, this.failAt});

  final Uint8List bytes;
  final int? size;

  /// A read from this offset on fails
  final int? failAt;

  final reads = <(int, int)>[];
  var opened = 0;
  var closed = 0;

  RawVideoInput input(String name) => RawVideoInput(
    name: name,
    key: 'test:$name',
    url: 'file:///$name',
    open: () async {
      opened++;
      final read = bytesReader(bytes, reads: reads);
      return (
        size: size ?? bytes.length,
        read: (int offset, int length) {
          final fail = failAt;
          if (fail != null && offset + length > fail) {
            throw StateError('the share went away');
          }
          return read(offset, length);
        },
        close: () async => closed++,
      );
    },
  );
}

RawVideoPlan _plan(RawMediaKind kind, {RawVideoInput? input, double? frameRate = 29.97, List<double>? downBody}) =>
    RawVideoPlan(
      kind: kind,
      layout: kind == RawMediaKind.insta360Video ? RawVideoLayout.sideBySide : RawVideoLayout.twoTracks,
      tracks: [RawVideoTrack(file: 0, videoTrack: 0, width: 5760, height: 2880, frameRate: frameRate)],
      calibration: kind == RawMediaKind.insta360Video
          ? nominalX3(2880).copyWith(downBody: downBody ?? const [0.99, 0.12, -0.09])
          : null,
      url: input?.url ?? 'file:///video',
      trackOrderSource: 'single',
      motionTrackInput: input,
    );

/// What the player is told, in order
class _Player extends SphericalVideoApi {
  _Player({this.fails = false});

  final bool fails;
  final told =
      <({String url, bool enabled, bool hasTrack, Int64List? times, Float64List? corrections, String? summary})>[];

  @override
  Future<void> setStabilization(
    String url,
    bool enabled,
    bool hasTrack,
    Int64List? presentationTimesUs,
    Float64List? corrections,
    String? summary,
  ) async {
    told.add((
      url: url,
      enabled: enabled,
      hasTrack: hasTrack,
      times: presentationTimesUs,
      corrections: corrections,
      summary: summary,
    ));
    if (fails) {
      throw StateError('no player');
    }
  }
}

void main() {
  final x4 = insta360SliceVideo(insta360X4MotionSlice, indexed: true);

  test('the raw videos of the three cameras that record their motion carry a track, a photo none', () {
    expect(rawKindHasMotionTrack(RawMediaKind.insta360Video), isTrue);
    expect(rawKindHasMotionTrack(RawMediaKind.goProVideo), isTrue);
    expect(rawKindHasMotionTrack(RawMediaKind.djiVideo), isTrue);
    expect(rawKindHasMotionTrack(RawMediaKind.insta360Photo), isFalse);
  });

  test('asks for the level of the stitch of an Insta360 and the frame duration of the first track', () {
    final insta = RawStabilizationRequest.of(
      _plan(RawMediaKind.insta360Video, downBody: const [0.6, 0.07, -0.79]),
      name: 'VID_00_027.insv',
      fileSize: 1000,
    );
    expect(insta.kind, RawMediaKind.insta360Video);
    expect(insta.downBody, [0.6, 0.07, -0.79]);
    expect(insta.frameDurationUs, closeTo(33366.7, 0.1));
    expect(insta.fileSize, 1000);

    // GoPro and DJI: their view frame is fixed, no gravity of a stitch; an unknown frame rate keeps the track's times
    final goPro = RawStabilizationRequest.of(_plan(RawMediaKind.goProVideo), name: 'GS010013.360', fileSize: 5);
    expect(goPro.downBody, isNull);
    final dji = RawStabilizationRequest.of(_plan(RawMediaKind.djiVideo, frameRate: null), name: 'a.osv', fileSize: 5);
    expect((dji.downBody, dji.frameDurationUs), (null, null));
    expect(dji.toString(), contains('djiVideo'));
  });

  group('the table built from the file', () {
    test('of an Insta360 is the one of its reader, the frames on the timeline of the track', () async {
      final request = RawStabilizationRequest(
        kind: RawMediaKind.insta360Video,
        name: 'x4.insv',
        fileSize: x4.length,
        downBody: const [0.6, 0.07, -0.79],
        frameDurationUs: 1e6 / 29.97,
      );
      final table = await buildRawStabilization(request, bytesReader(x4));
      final direct = await readInsta360Stabilization(
        bytesReader(x4),
        x4.length,
        downBody: const [0.6, 0.07, -0.79],
        frameDurationUs: 1e6 / 29.97,
      );
      expect(table, isNotNull);
      expect(table!.corrections, direct!.corrections);
      expect(table.presentationTimesUs, [for (var i = 0; i < table.length; i++) (i * 1e6 / 29.97).round()]);
    });

    test('of a GoPro whose faces are not those of the MAX is none: its axes were not measured', () async {
      final request = RawStabilizationRequest.of(
        const RawVideoPlan(
          kind: RawMediaKind.goProVideo,
          layout: RawVideoLayout.twoTracks,
          tracks: [
            RawVideoTrack(file: 0, videoTrack: 0, width: 5952, height: 1920, frameRate: 29.97),
            RawVideoTrack(file: 0, videoTrack: 1, width: 5952, height: 1920, frameRate: 29.97),
          ],
          eac: GoProEacGeometry(trackWidth: 5952, trackHeight: 1920),
          url: 'file:///max2.360',
          trackOrderSource: 'single',
        ),
        name: 'max2.360',
        fileSize: 10,
      );
      expect(request.goProFace, 1920);
      var reads = 0;
      final table = await buildRawStabilization(request, (offset, length) async {
        reads++;
        return Uint8List(0);
      });
      expect((table, reads), (null, 0));
      expect(request.toString(), contains('goProFace: 1920'));
    });

    test('of a GoPro and of a DJI come from their orientations', () async {
      final goPro = goProSpreadVideo();
      final goProTable = await buildRawStabilization(
        RawStabilizationRequest(kind: RawMediaKind.goProVideo, name: 'g.360', fileSize: goPro.length),
        bytesReader(goPro),
      );
      expect(goProTable!.summary.source, 'GoPro CORI');
      expect(goProTable.length, 24);

      final dji = djiSliceVideo();
      final djiTable = await buildRawStabilization(
        RawStabilizationRequest(
          kind: RawMediaKind.djiVideo,
          name: 'd.osv',
          fileSize: dji.length,
          frameDurationUs: 40000,
        ),
        bytesReader(dji),
      );
      expect(djiTable!.summary.source, 'DJI attitude');
      // Frame i at i frame durations of the video track, as the player times them
      expect(djiTable.presentationTimesUs.first, 0);
      expect(djiTable.presentationTimesUs[1], 40000);
    });

    test('in a background isolate is the same, its reads served by this isolate', () async {
      final reads = <(int, int)>[];
      final request = RawStabilizationRequest(
        kind: RawMediaKind.insta360Video,
        name: 'x4.insv',
        fileSize: x4.length,
        frameDurationUs: 1e6 / 29.97,
      );
      final inPlace = await buildRawStabilization(request, bytesReader(x4));
      final inIsolate = await buildRawStabilizationInIsolate(request, bytesReader(x4, reads: reads));

      expect(inIsolate, isNotNull);
      expect(inIsolate!.corrections, inPlace!.corrections);
      expect(inIsolate.presentationTimesUs, inPlace.presentationTimesUs);
      expect(inIsolate.summary.toString(), inPlace.summary.toString());
      expect(reads, isNotEmpty, reason: 'the file is read here, not in the isolate');
    });

    test('in a background isolate fails as its read does', () async {
      final request = RawStabilizationRequest(kind: RawMediaKind.insta360Video, name: 'x4.insv', fileSize: x4.length);
      Future<Uint8List> failing(int offset, int length) async => throw StateError('the share went away');
      await expectLater(
        buildRawStabilizationInIsolate(request, failing),
        throwsA(predicate((Object error) => '$error'.contains('the share went away'))),
      );
    });
  });

  group('stabilizationOfRawVideo', () {
    test('opens the file of the motion track, builds the table and closes the file', () async {
      final file = _File(x4);
      final table = await stabilizationOfRawVideo(
        _plan(RawMediaKind.insta360Video, input: file.input('x4.insv')),
        build: buildRawStabilization,
      );
      expect(table, isNotNull);
      expect(table!.length, insta360X4StabilizationSlice.camera.length);
      expect((file.opened, file.closed), (1, 1));
    });

    test('is null without a file to read, without a size, without a track, or when a read fails', () async {
      // A plan made without the resolver: nothing to open
      expect(await stabilizationOfRawVideo(_plan(RawMediaKind.insta360Video), build: buildRawStabilization), isNull);

      final noSize = _File(x4, size: 0);
      expect(
        await stabilizationOfRawVideo(
          _plan(RawMediaKind.insta360Video, input: noSize.input('a')),
          build: buildRawStabilization,
        ),
        isNull,
      );
      expect(noSize.closed, 1);

      // An mp4 without a trailer
      final plain = _File(Uint8List.fromList([0, 0, 0, 8, ...'free'.codeUnits, ...List.filled(2000, 0)]));
      expect(
        await stabilizationOfRawVideo(
          _plan(RawMediaKind.insta360Video, input: plain.input('b')),
          build: buildRawStabilization,
        ),
        isNull,
      );

      final failing = _File(x4, failAt: x4.length - 100);
      expect(
        await stabilizationOfRawVideo(
          _plan(RawMediaKind.insta360Video, input: failing.input('c')),
          build: buildRawStabilization,
        ),
        isNull,
      );
      expect(failing.closed, 1, reason: 'closed after a failure too');
    });

    test('is null without reading for a file that does not read at any position, a stream without ranges', () async {
      final file = _File(x4);
      final input = file.input('x4.insv');
      final stream = RawVideoInput(
        name: input.name,
        key: input.key,
        url: input.url,
        open: input.open,
        readsAnywhere: () => false,
      );
      final plan = _plan(RawMediaKind.insta360Video, input: stream);
      expect(rawVideoHasReadableTrack(plan), isFalse);
      expect(await stabilizationOfRawVideo(plan, build: buildRawStabilization), isNull);
      expect(file.opened, 0);
      expect(file.reads, isEmpty);
    });

    test('is null for a photo, which has no track', () async {
      final file = _File(x4);
      expect(await stabilizationOfRawVideo(_plan(RawMediaKind.insta360Photo, input: file.input('a.insp'))), isNull);
      expect(file.opened, 0);
    });
  });

  group('RawVideoStabilizer', () {
    test('announces the track before the player opens, then delivers the table', () async {
      final player = _Player();
      final file = _File(x4);
      final stabilizer = RawVideoStabilizer(
        api: player,
        url: 'file:///x4.insv',
        enabled: true,
        plan: _plan(RawMediaKind.insta360Video, input: file.input('x4.insv')),
        build: buildRawStabilization,
      );
      expect(stabilizer.applies, isTrue);

      await stabilizer.announce();
      expect(player.told.single.hasTrack, isTrue);
      expect(player.told.single.times, isNull, reason: 'no table yet: the switch shows, the video plays');

      final table = await stabilizer.deliver();
      expect(player.told, hasLength(2));
      final delivered = player.told.last;
      expect((delivered.url, delivered.enabled, delivered.hasTrack), ('file:///x4.insv', true, true));
      expect(delivered.times, table!.presentationTimesUs);
      expect(delivered.corrections, hasLength(4 * table.length));
      for (var i = 0; i < table.corrections.length; i++) {
        expect(delivered.corrections![i], table.corrections[i]);
      }
      expect(delivered.summary, contains('frames'));
    });

    test('tells the player the file has no track, with the setting off as it is', () async {
      final player = _Player();
      final plain = _File(Uint8List.fromList([0, 0, 0, 8, ...'free'.codeUnits]));
      final stabilizer = RawVideoStabilizer(
        api: player,
        url: 'file:///plain.insv',
        enabled: false,
        plan: _plan(RawMediaKind.insta360Video, input: plain.input('plain.insv')),
        build: buildRawStabilization,
      );
      expect(await stabilizer.deliver(), isNull);
      expect(player.told.single.hasTrack, isFalse);
      expect(player.told.single.enabled, isFalse);
      expect((player.told.single.times, player.told.single.corrections), (null, null));
    });

    test('stops the build when the player closes, and tells the player nothing more', () async {
      final player = _Player();
      final file = _File(x4);
      late RawVideoStabilizer stabilizer;
      var reads = 0;
      stabilizer = RawVideoStabilizer(
        api: player,
        url: 'file:///x4.insv',
        enabled: true,
        plan: _plan(RawMediaKind.insta360Video, input: file.input('x4.insv')),
        // The player closes after the second read
        build: (request, read) => buildRawStabilization(request, (offset, length) async {
          reads++;
          final bytes = await read(offset, length);
          if (reads == 2) {
            stabilizer.cancel();
          }
          return bytes;
        }),
      );
      await stabilizer.announce();

      expect(await stabilizer.deliver(), isNull);
      expect(stabilizer.cancelled, isTrue);
      expect(reads, 3, reason: 'the read after the close fails, which ends the build');
      expect(player.told, hasLength(1), reason: 'the announce only');
      expect(file.closed, 1);
    });

    test('tells a video without a table the setting, so that the switch of a CAMM track starts there', () async {
      final player = _Player();
      await tellStabilizationSetting(player, 'https://server/video.mp4', enabled: false);
      final told = player.told.single;
      expect(
        (told.url, told.enabled, told.hasTrack, told.times, told.corrections),
        ('https://server/video.mp4', false, false, null, null),
      );
      // A failing player stops nothing
      await tellStabilizationSetting(_Player(fails: true), 'u', enabled: true);
    });

    test('does not apply to a GoPro whose faces are not those of the MAX: its switch never shows', () {
      final file = _File(goProSpreadVideo());
      RawVideoPlan goPro(int face) => RawVideoPlan(
        kind: RawMediaKind.goProVideo,
        layout: RawVideoLayout.twoTracks,
        tracks: [RawVideoTrack(file: 0, videoTrack: 0, width: face * 3 + 64, height: face, frameRate: 29.97)],
        eac: GoProEacGeometry(trackWidth: face * 3 + 64, trackHeight: face),
        url: 'file:///g.360',
        trackOrderSource: 'single',
        motionTrackInput: file.input('g.360'),
      );
      expect(RawVideoStabilizer(api: _Player(), url: 'u', enabled: true, plan: goPro(1920)).applies, isFalse);
      expect(RawVideoStabilizer(api: _Player(), url: 'u', enabled: true, plan: goPro(1344)).applies, isTrue);
    });

    test('applies only to a camera with a track and a file to read, and a failing player stops nothing', () async {
      final player = _Player(fails: true);
      expect(
        RawVideoStabilizer(api: player, url: 'u', enabled: true, plan: _plan(RawMediaKind.insta360Video)).applies,
        isFalse,
      );
      final file = _File(x4);
      final stabilizer = RawVideoStabilizer(
        api: player,
        url: 'u',
        enabled: true,
        plan: _plan(RawMediaKind.insta360Video, input: file.input('x4.insv')),
        build: buildRawStabilization,
      );
      await stabilizer.announce();
      expect(await stabilizer.deliver(), isA<StabilizationTable>());
      expect(player.told, hasLength(2));
    });
  });
}
