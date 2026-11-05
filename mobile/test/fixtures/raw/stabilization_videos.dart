// Small videos of the real slices of the motion tracks (a few KB each, built at each run from the fixtures of lots a,
// a2 and a3), for the tests of the stabilisation from a file to the player: an Insta360 trailer (walked or indexed), a
// GoPro .360 of 24 real CORI and GRAV frames, a DJI .osv of 5 real attitude records. Built as stabilization_test.dart
// and stabilization_cameras_test.dart build theirs.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/spherical_probe.dart' show ByteRangeReader;

import 'dji_motion_slices.dart';
import 'dji_osv.stub.dart';
import 'gopro_gpmf.stub.dart';
import 'gopro_gpmf_frames.dart';
import 'insta360.stub.dart';
import 'insta360_motion_slices.dart';

final _mp4 = [0, 0, 0, 8, ...'free'.codeUnits];

/// A video of the real Insta360 [slice] in a walked (X3) or an indexed (X4, X5) trailer
Uint8List insta360SliceVideo(Insta360MotionSlice slice, {required bool indexed}) {
  final metadata = [
    ...pbStringField(1, x3Serial),
    ...pbStringField(2, slice.model),
    ...pbStringField(3, slice.firmware),
    ...pbVarintField(24, slice.firstFrameTimestamp),
    ...pbDoubleField(25, slice.rollingShutterMs),
    ...pbVarintField(62, 1),
    ...pbBytesField(65, [...pbVarintField(1, 32), ...pbVarintField(2, 2000)]),
  ];
  if (indexed) {
    return Uint8List.fromList([
      ..._mp4,
      ...insta360IndexedTail(metadata: metadata, imu: slice.imu, frames: slice.frames, padTo: 128 * 1024),
    ]);
  }
  return insta360File([
    insta360Record(4, slice.frames),
    insta360Record(3, slice.imu),
    insta360Record(2, List.filled(300, 0x55)),
    insta360Record(1, metadata, format: 1),
  ], body: _mp4);
}

/// The 24 real frames of the GoPro MAX sample, every 25th one, one payload each, 0.834 s apart
Uint8List goProSpreadVideo() => goProMotionFile(
  [
    for (var i = 0; i < goProSpreadFrames.length; i++)
      goProPayload(cori: [goProSpreadCori[i]], grav: [goProSpreadGrav[i]], shut: [0.0003]),
  ],
  withVideo: false,
  payloadTicks: List.filled(goProSpreadFrames.length, 834),
);

/// The real frames 0, 1, 2, 300 and 301 of the DJI Osmo 360 sample
Uint8List djiSliceVideo() => djiOsvFile(
  camd: djiCamdBox(
    djiMotionCamdRecords([
      for (final (attitude, second) in djiMotionSliceRecords) (base64.decode(attitude), base64.decode(second)),
    ]),
  ),
);

/// Range reads of [file], counted in [reads] when given
ByteRangeReader bytesReader(Uint8List file, {List<(int, int)>? reads}) => (offset, length) async {
  reads?.add((offset, length));
  if (offset >= file.length) {
    return Uint8List(0);
  }
  return Uint8List.sublistView(file, offset, math.min(file.length, offset + length));
};
