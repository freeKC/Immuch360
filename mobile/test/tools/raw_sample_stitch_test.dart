// Stitches one frame of real raw 360° videos with the CPU reference of the app, from the plan its resolver makes of
// the file (the tracks, the calibration read from the file, the lens order, the window of the sensor): what the native
// players must show, to compare with them on the same frame. Each file is only read, in place; ffmpeg decodes the
// frame of each track. Each test is skipped unless its variable names its file, and IMMUCH_STITCH_OUT a directory:
//   IMMUCH_OSV_SAMPLE=/path/to/CAM_20250715191201_0003_D.OSV (DJI Osmo 360)
//   IMMUCH_GOPRO_SAMPLE=/path/to/GS010013.360 (GoPro MAX)
//   IMMUCH_X4_SAMPLE=/path/to/VID_20240414_135511_00_027.insv (Insta360 X4, two tracks, indexed trailer)
//   IMMUCH_X3_PAIR_SAMPLE=/path/to/VID_20240414_135506_00_088.insv (Insta360 X3 split pair, the _10_ file next to it)
// IMMUCH_STITCH_SECONDS sets the time of the frame (5 by default).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_calibration_store.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_stitcher.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/raw/raw_sampler.dart';
import 'package:immich_mobile/domain/services/raw/raw_video_plan.dart';
import 'package:immich_mobile/providers/raw/dual_fisheye.provider.dart';

import '../infrastructure/repository.mock.dart';

final _out = Platform.environment['IMMUCH_STITCH_OUT'];
final _seconds = Platform.environment['IMMUCH_STITCH_SECONDS'] ?? '5';

void _print(String line) {
  // ignore: avoid_print
  print(line);
}

/// The input of the file at [path], read in place
Future<RawVideoInput> _input(String path) async => RawVideoInput(
  name: path.split('/').last,
  key: 'sample:$path',
  url: Uri.file(path).toString(),
  open: () async {
    final file = await File(path).open();
    return (
      size: await file.length(),
      read: (int offset, int length) async {
        await file.setPosition(offset);
        return file.read(length);
      },
      close: file.close,
    );
  },
);

/// The frame at [_seconds] of the [videoTrack]-th video stream of [path], decoded by ffmpeg to RGBA at half its size
Future<RgbaTexture> _frame(String path, int videoTrack, int width, int height) async {
  final (w, h) = (width ~/ 2, height ~/ 2);
  final result = await Process.run('ffmpeg', [
    '-v', 'error', '-ss', _seconds, '-i', path, '-map', '0:v:$videoTrack', '-frames:v', '1', //
    '-vf', 'scale=$w:$h', '-f', 'rawvideo', '-pix_fmt', 'rgba', '-',
  ], stdoutEncoding: null);
  final bytes = Uint8List.fromList(result.stdout as List<int>);
  expect(bytes.length, w * h * 4, reason: 'ffmpeg: ${result.stderr}');
  return (rgba: bytes, width: w, height: h);
}

/// Plans [path] as a raw video of [kind], decodes a frame of each of its tracks and writes the stitch as [name]
Future<void> _stitch(String path, RawMediaKind kind, String name) async {
  final resolver = RawVideoResolver(
    calibrations: DualFisheyeCalibrationService(
      store: DualFisheyeCalibrationStore(() async => null),
      storage: MockStorageRepository(),
      client: () => throw UnimplementedError('files on this machine'),
      serverEndpoint: () => null,
      headers: () => const {},
    ),
    support: const RawVideoPlaybackSupport(twoStreams: true),
  );
  final directory = File(path).parent.path;
  final plan = await resolver.resolve(
    kind: kind,
    input: await _input(path),
    findSibling: (sibling) async => File('$directory/$sibling').existsSync() ? _input('$directory/$sibling') : null,
  );
  _print('$name: $plan');
  _print('$name: ${const JsonEncoder.withIndent('  ').convert(jsonDecode(plan.toNativeJson()))}');

  final textures = <RgbaTexture>[];
  for (final track in plan.tracks) {
    final file = track.file == 0 ? path : '$directory/${splitPairOf(path.split('/').last)!.siblingName}';
    textures.add(await _frame(file, track.videoTrack, track.width!, track.height!));
  }
  final stitched = stitchRawRgba(textures, plan.sampler, width: 2048, height: 1024);
  File('$_out/$name').writeAsBytesSync(encodeOpaquePng(stitched, 2048, 1024));
  _print('$name written to $_out');
}

dynamic _skip(String variable) =>
    Platform.environment[variable] == null || _out == null ? 'Set $variable and IMMUCH_STITCH_OUT' : false;

void main() {
  const timeout = Timeout(Duration(minutes: 5));

  test(
    'stitches a frame of a DJI Osmo 360 .OSV',
    () async {
      await _stitch(Platform.environment['IMMUCH_OSV_SAMPLE']!, RawMediaKind.djiVideo, 'osv_stitch.png');
    },
    skip: _skip('IMMUCH_OSV_SAMPLE'),
    timeout: timeout,
  );

  test(
    'stitches a frame of a GoPro MAX .360',
    () async {
      await _stitch(Platform.environment['IMMUCH_GOPRO_SAMPLE']!, RawMediaKind.goProVideo, 'gopro_stitch.png');
    },
    skip: _skip('IMMUCH_GOPRO_SAMPLE'),
    timeout: timeout,
  );

  test(
    'stitches a frame of an Insta360 X4 two track .insv',
    () async {
      await _stitch(Platform.environment['IMMUCH_X4_SAMPLE']!, RawMediaKind.insta360Video, 'x4_stitch.png');
    },
    skip: _skip('IMMUCH_X4_SAMPLE'),
    timeout: timeout,
  );

  test(
    'stitches a frame of an Insta360 X3 split pair',
    () async {
      await _stitch(Platform.environment['IMMUCH_X3_PAIR_SAMPLE']!, RawMediaKind.insta360Video, 'x3_pair_stitch.png');
    },
    skip: _skip('IMMUCH_X3_PAIR_SAMPLE'),
    timeout: timeout,
  );
}
