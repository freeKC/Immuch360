// Writes the inputs of the device tests of the raw videos (docs/18-design-projections-and-parsers.md, section 9.4):
// for an Insta360 X5 like two track file, an Insta360 X3 split pair, a DJI Osmo 360 and a GoPro MAX 2, the PNG of each
// video track drawn from the pattern at its real size, the equirect picture a player must show (2048 x 1024, stitched
// from those PNG by the CPU reference), the rawProjection JSON the app sends for the encoded file (its codecs strings
// aside, which the encoder decides), and the trailer or camd box to append to the encoded MP4. ffmpeg then encodes
// still clips of the PNG, as the design shows.
//
// Runs only with IMMUCH_RAW_MEDIA_OUT=/a/directory. IMMUCH_RAW_MEDIA_SIDE=512 draws the lens squares smaller, for a
// quick look (the GoPro tracks keep their real size, which their layout needs).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_calibration_store.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_stitcher.dart';
import 'package:immich_mobile/domain/services/raw/gopro_eac.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/raw/raw_sampler.dart';
import 'package:immich_mobile/domain/services/raw/raw_video_plan.dart';
import 'package:immich_mobile/providers/raw/dual_fisheye.provider.dart';

import '../domain/services/spherical_probe_fixtures.dart';
import '../fixtures/raw/dji_osv.stub.dart';
import '../fixtures/raw/insta360.stub.dart';
import '../fixtures/raw/raw_frames.dart';
import '../infrastructure/repository.mock.dart';

final _out = Platform.environment['IMMUCH_RAW_MEDIA_OUT'];
final _side = int.tryParse(Platform.environment['IMMUCH_RAW_MEDIA_SIDE'] ?? '');

const _goldenWidth = 2048;
const _goldenHeight = 1024;

void _print(String line) {
  // ignore: avoid_print
  print(line);
}

/// An Insta360 camera at rest, upright: the accelerometer reads -1 g along IMU x (32 g full scale, raw samples)
List<int> _restingImu() => rawImuSamples(List.filled(1000, (32768 - 1024, 32768, 32768)));

/// The two video tracks of an encoded clip, as ffmpeg writes them: track IDs 1 and 2
List<int> _moov(int width, int height, {int bitDepth = 8, int tracks = 2}) => mp4Moov([
  for (var track = 1; track <= tracks; track++)
    mp4VideoTrack(
      [],
      width: width,
      height: height,
      config: mp4HvcC(profile: bitDepth == 10 ? 2 : 1, bitDepth: bitDepth),
      trackId: track,
      handlerType: 'vide',
      handlerName: 'VideoHandler',
    ),
]);

/// An input of the file [bytes] named [name], read in memory
RawVideoInput _input(String name, Uint8List bytes) => RawVideoInput(
  name: name,
  key: 'tool:$name',
  url: 'file:///sdcard/DCIM/$name',
  open: () async => (
    size: bytes.length,
    read: (int offset, int length) async =>
        Uint8List.sublistView(bytes, math.min(offset, bytes.length), math.min(offset + length, bytes.length)),
    close: () async {},
  ),
);

/// The resolver of the app, its calibrations read from the files themselves
RawVideoResolver _resolver() => RawVideoResolver(
  calibrations: DualFisheyeCalibrationService(
    store: DualFisheyeCalibrationStore(() async => null),
    storage: MockStorageRepository(),
    client: () => throw UnimplementedError('files in memory'),
    serverEndpoint: () => null,
    headers: () => const {},
  ),
  support: const RawVideoPlaybackSupport(twoStreams: true),
);

/// Writes [texture] as [name] in the output directory
void _writePng(String name, RgbaTexture texture) {
  File('$_out/$name').writeAsBytesSync(encodeOpaquePng(texture.rgba, texture.width, texture.height));
  _print('$name: ${texture.width} x ${texture.height}');
}

/// The PNG of each track of [plan] ([names] in track order), the golden equirect, the JSON and the [tail] to append
void _writeCamera(String camera, RawVideoPlan plan, List<RgbaTexture> textures, List<String> names, List<int> tail) {
  for (final (k, texture) in textures.indexed) {
    _writePng(names[k], texture);
  }
  final golden = stitchRawRgba(textures, plan.sampler, width: _goldenWidth, height: _goldenHeight);
  _writePng('${camera}_golden.png', (rgba: golden, width: _goldenWidth, height: _goldenHeight));
  final json = plan.toNativeJson();
  File('$_out/$camera.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(jsonDecode(json)));
  if (tail.isNotEmpty) {
    File('$_out/${camera}_${plan.kind == RawMediaKind.djiVideo ? 'camd' : 'tail'}.bin').writeAsBytesSync(tail);
  }
  _print('$camera: $plan');
}

/// The textures of the tracks of a fisheye [plan], each drawn from the calibration the app found, [side] pixels square
List<RgbaTexture> _lensTextures(RawVideoPlan plan, int side) {
  final calibration = plan.calibration!;
  final textureOfLens = plan.textureOfLens!;
  return [for (var k = 0; k < plan.tracks.length; k++) patternLensTexture(calibration, textureOfLens.indexOf(k), side)];
}

// The V6 string of the illustrative X5 of section 3.5 B: the lens values of a nominal camera, k4 and k5 at 0
String _x5OffsetV6() {
  String lens(int index) => [
    1.95, 4180, 4180, 2688 + index * 5376, 2688, 0, 0, 90, 0, 0, 0, 0.39, 1.28, -3.94, //
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 10752, 5376, 71,
  ].join('_');
  return '2_${lens(0)}_${lens(1)}_394240';
}

void main() {
  setUpAll(() {
    final out = _out;
    if (out != null) {
      Directory(out).createSync(recursive: true);
    }
  });
  final skip = _out == null ? 'Set IMMUCH_RAW_MEDIA_OUT to the directory to write the test media in' : false;

  test(
    'Insta360 X5 like, two tracks, field 80 = 1 (track 0 holds lens 1), indexed inst trailer',
    () async {
      final side = _side ?? 3840;
      final metadata = [
        ...pbStringField(1, 'IAXFB2501ABCDE'),
        ...pbStringField(2, x5Model),
        ...pbBytesField(19, [...pbVarintField(1, 3840), ...pbVarintField(2, 3840)]),
        ...pbVarintField(62, 1),
        ...pbBytesField(65, [...pbVarintField(1, 32), ...pbVarintField(2, 2000)]),
        ...pbVarintField(79, 2),
        ...pbVarintField(80, 1),
        ...pbStringField(111, _x5OffsetV6()),
        ...pbVarintField(131, 3),
      ];
      final tail = insta360IndexedTail(metadata: metadata, imu: _restingImu(), padTo: 4096);
      final file = Uint8List.fromList([...mp4File(_moov(3840, 3840)), ...tail]);

      final plan = await _resolver().resolve(
        kind: RawMediaKind.insta360Video,
        input: _input('VID_20261005_120000_00_001.insv', file),
        findSibling: (_) async => null,
      );

      expect((plan.layout, plan.trackOrderSource), (RawVideoLayout.twoTracks, 'field80'));
      expect(plan.textureOfLens, [1, 0]);
      expect(plan.calibration?.gravity, GravitySource.imu);
      _writeCamera('x5', plan, _lensTextures(plan, side), ['x5_lens1.png', 'x5_lens0.png'], tail);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'Insta360 X3 split pair, the trailer on the _00_ file only, its video window included',
    () async {
      final side = _side ?? 2880;
      final metadata = [
        ...pbBytesField(27, [
          ...pbVarintField(1, 5952),
          ...pbVarintField(2, 5952),
          ...pbVarintField(3, 5760),
          ...pbVarintField(4, 5760),
        ]),
        ...pbVarintField(79, 1),
        ...pbVarintField(131, 2),
        ...x3Metadata(),
      ];
      // Bare and sequential, as the X3 writes it
      final tail = insta360File([insta360Record(3, _restingImu()), insta360Record(1, metadata, format: 1)], body: []);
      final first = Uint8List.fromList([...mp4File(_moov(2880, 2880, tracks: 1)), ...tail]);
      final second = mp4File(_moov(2880, 2880, tracks: 1));

      final plan = await _resolver().resolve(
        kind: RawMediaKind.insta360Video,
        input: _input('VID_20261005_120000_10_002.insv', second),
        findSibling: (name) async => _input(name, first),
      );

      expect(plan.layout, RawVideoLayout.twoFiles);
      expect(plan.textureOfLens, [1, 0]);
      expect(plan.calibration?.canvasSquare, 5760, reason: 'the window of field 27');
      // The tracks of the plan are the _10_ file (lens 1) then the _00_ file (lens 0)
      _writeCamera('x3', plan, _lensTextures(plan, side), ['x3_lens1.png', 'x3_lens0.png'], tail);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'DJI Osmo 360, 10 bit, the camd box of the sample',
    () async {
      final side = _side ?? 3840;
      final camd = djiCamdBox(djiCamdRecords());
      final file = Uint8List.fromList([...mp4File(_moov(3840, 3840, bitDepth: 10), moovAtEnd: true), ...camd]);

      final plan = await _resolver().resolve(
        kind: RawMediaKind.djiVideo,
        input: _input('CAM_20261005120000_0001_D.OSV', file),
        findSibling: (_) async => null,
      );

      expect(plan.calibration?.source, DualFisheyeSource.file);
      _writeCamera('dji', plan, _lensTextures(plan, side), ['dji_lens0.png', 'dji_lens1.png'], camd);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'GoPro MAX 2, 10 bit, tracks of 5952 x 1920',
    () async {
      final file = mp4File(_moov(5952, 1920, bitDepth: 10));

      final plan = await _resolver().resolve(
        kind: RawMediaKind.goProVideo,
        input: _input('GS010001.360', file),
        findSibling: (_) async => null,
      );

      final eac = plan.eac!;
      expect(eac, const GoProEacGeometry(trackWidth: 5952, trackHeight: 1920));
      final textures = [for (var k = 0; k < 2; k++) patternEacTrack(eac, k, plan.viewToCamera!)];
      _writeCamera('gp', plan, textures, ['gp_track0.png', 'gp_track1.png'], const []);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
