// Synthetic DJI Osmo 360 .osv files for the tests of the camd parser: the protobuf records of the camd box (a header,
// a config whose field 6 holds the calibration slots, a frame record), the camd box itself (a small MP4 of its own),
// and a whole file with the tracks of the real sample. The lens values are those of the real sample
// CAM_20250101120000_0001_D.OSV (serial 95SXN0000000AB, firmware 10.00.05.06), as floats, as the camera writes them.

import 'dart:convert';
import 'dart:typed_data';

import '../../domain/services/spherical_probe_fixtures.dart';
import 'insta360.stub.dart';

const djiModel = 'Osmo 360';
const djiSerial = '95SXN0000000AB';
const djiFirmware = '10.00.05.06';

/// The values of a DewarpParams slot
typedef DjiLensValues = ({
  double fx,
  double fy,
  double cx,
  double cy,
  double k1,
  double k2,
  double k3,
  double k4,
  double k5,
  double yaw,
  double pitch,
  double roll,
  List<double> quaternion,
  List<double> tangential,
});

/// Slot 1 of the sample: lens 0, video stream 0, the rear lens
const djiLens0 = (
  fx: 1046.37927,
  fy: 1046.16797,
  cx: 1920.85339,
  cy: 1916.73022,
  k1: 0.0681340024,
  k2: -0.0137970001,
  k3: 0.0117944004,
  k4: -0.00733225001,
  k5: 0.00104408001,
  yaw: 179.5457,
  pitch: 90.6168823,
  roll: -1.35562587,
  quaternion: [-0.011197756, 0.00550154177, -0.70320189, 0.710880756],
  tangential: [-0.000548052019, 0.000574573991],
);

/// Slot 2 of the sample: lens 1, video stream 1, the front lens
const djiLens1 = (
  fx: 1048.02502,
  fy: 1047.87451,
  cx: 1910.76611,
  cy: 1916.24243,
  k1: 0.0644356012,
  k2: -0.00886799023,
  k3: 0.00849703979,
  k4: -0.00639127009,
  k5: 0.000955505995,
  yaw: -0.522708118,
  pitch: 90.5974884,
  roll: 0.403851181,
  quaternion: [0.703410029, 0.710760951, -0.00070360594, 0.00572117651],
  tangential: [-0.000191191997, 0.000472899002],
);

/// Slots 11 and 12 of the sample, a calibration of another recording mode
const _djiLens11 = (
  fx: 1046.13,
  fy: 1046.13,
  cx: 1923.86,
  cy: 1916.5699,
  k1: 0.0681340024,
  k2: -0.0137970001,
  k3: 0.0117944004,
  k4: -0.00733225001,
  k5: 0.00104408001,
  yaw: 179.40236,
  pitch: 90.826859,
  roll: -1.4441991,
  quaternion: [-0.012636213, 0.0051327478, -0.70187402, 0.71217048],
  tangential: [-0.000548052019, 0.000574573991],
);
const _djiLens12 = (
  fx: 1047.0,
  fy: 1047.0,
  cx: 1911.42,
  cy: 1915.1899,
  k1: 0.0644356012,
  k2: -0.00886799023,
  k3: 0.00849703979,
  k4: -0.00639127009,
  k5: 0.000955505995,
  yaw: -0.53114146,
  pitch: 90.407143,
  roll: 0.29184946,
  quaternion: [0.70458853, 0.7095964, -0.0014585386, 0.0050835768],
  tangential: [-0.000191191997, 0.000472899002],
);

List<int> _packedFloats(int field, List<double> values) => pbBytesField(field, [for (final v in values) ...f32le(v)]);

/// A populated DewarpParams slot: floats 1 to 15 (fx, fy, cx, cy, k1 to k4, the width and the height of the lens
/// square, yaw, pitch, roll, k5), the tangential pair (20) and the quaternion (21) packed, the lens model (24), then
/// the quaternion again as a message of four floats (28) unless [withQuaternion] is false. With [omitZeros], the
/// components of 28 that are 0 are left out, as protobuf 3 writes them (the identity of the front lens of the Osmo 360
/// II is w = 1 alone).
List<int> djiDewarpSlot(
  DjiLensValues lens, {
  double width = 3840,
  double height = 3840,
  bool withQuaternion = true,
  bool omitZeros = false,
}) => [
  ...pbFloatField(1, lens.fx),
  ...pbFloatField(2, lens.fy),
  ...pbFloatField(3, lens.cx),
  ...pbFloatField(4, lens.cy),
  ...pbFloatField(5, lens.k1),
  ...pbFloatField(6, lens.k2),
  ...pbFloatField(7, lens.k3),
  ...pbFloatField(8, lens.k4),
  ...pbFloatField(10, width),
  ...pbFloatField(11, height),
  ...pbFloatField(12, lens.yaw),
  ...pbFloatField(13, lens.pitch),
  ...pbFloatField(14, lens.roll),
  ...pbFloatField(15, lens.k5),
  ..._packedFloats(20, lens.tangential),
  ..._packedFloats(21, lens.quaternion),
  ..._packedFloats(22, List.filled(14, 1920)),
  ..._packedFloats(23, List.filled(14, 3735)),
  ...pbFloatField(24, 8),
  ..._packedFloats(27, lens.tangential),
  if (withQuaternion)
    ...pbBytesField(28, [
      for (var i = 0; i < 4; i++)
        if (!omitZeros || lens.quaternion[i] != 0) ...pbFloatField(i + 1, lens.quaternion[i]),
    ]),
];

/// A slot of zeros, as slots 3 to 10 of the sample: packed fields only
List<int> djiZeroSlot() => [
  ..._packedFloats(20, [0, 0]),
  ..._packedFloats(21, [0, 0, 0, 0]),
  ..._packedFloats(22, List.filled(14, 0)),
  ..._packedFloats(23, List.filled(14, 0)),
  ..._packedFloats(27, [0, 0]),
];

/// A calibration message: [slots] by slot number
List<int> djiCalibration(Map<int, List<int>> slots) => [
  for (final MapEntry(key: number, value: slot) in slots.entries) ...pbBytesField(number, slot),
];

/// The calibration of the sample: slots 1 and 2 hold the two lenses, 3 to 10 are zero filled, 11 and 12 hold another
/// recording mode. [withQuaternion] false leaves out sub-field 28 of the lenses.
List<int> djiSampleCalibration({bool withQuaternion = true}) => djiCalibration({
  1: djiDewarpSlot(djiLens0, withQuaternion: withQuaternion),
  2: djiDewarpSlot(djiLens1, withQuaternion: withQuaternion),
  for (var slot = 3; slot <= 10; slot++) slot: djiZeroSlot(),
  11: djiDewarpSlot(_djiLens11),
  12: djiDewarpSlot(_djiLens12),
});

/// A config record: a few fields of no consequence, then [calibration] in [calibrationField] (6 on the Osmo 360)
List<int> djiConfig({List<int>? calibration, int calibrationField = 6}) => [
  ...pbStringField(1, 'OQ101  '),
  ...pbBytesField(3, List.filled(19, 3)),
  ...pbBytesField(4, []),
  ...pbBytesField(5, [8, 1]),
  ...pbBytesField(calibrationField, calibration ?? djiSampleCalibration()),
];

/// A header record: field 1 names the schema (1), the camera (10), its serial (5) and firmware (6), and gives the time
/// stamp of the first frame of the video (9, the one of the sample; null leaves it out)
List<int> djiHeader({
  String model = djiModel,
  String serial = djiSerial,
  String firmware = djiFirmware,
  String schema = 'dvtm_oq101.proto',
  int? firstFrameStampUs = 18471494232,
}) => [
  ...pbBytesField(1, [
    ...pbStringField(1, schema),
    ...pbStringField(2, '02.01.13'),
    ...pbStringField(3, '2.0.5'),
    ...pbStringField(5, serial),
    ...pbStringField(6, firmware),
    if (firstFrameStampUs != null) ...pbVarintField(9, firstFrameStampUs),
    ...pbStringField(10, model),
  ]),
  ...pbBytesField(2, [1, 2, 3, 4]),
  ...pbBytesField(3, List.filled(18, 5)),
];

/// The records of the mdat of a camd box, as the sample has them: the header and the config of the first djmd track,
/// a frame record, then the header and the 36 byte config (no calibration) of the second track, and a frame record
List<int> djiCamdRecords({List<int>? header, List<int>? config}) => [
  ...pbBytesField(1, header ?? djiHeader()),
  ...pbBytesField(2, config ?? djiConfig()),
  ...pbBytesField(3, List.filled(1061, 7)),
  ...pbBytesField(1, pbBytesField(1, pbStringField(1, 'dvtm_oq101.proto'))),
  ...pbBytesField(2, List.filled(36, 0)),
  ...pbBytesField(3, List.filled(124, 7)),
];

/// A quaternion message: w (1), x (2), y (3), z (4) as floats; with [omitZeros], those that are 0 left out, as
/// protobuf 3 writes them
List<int> djiQuaternion(List<double> q, {bool omitZeros = false}) => [
  for (var i = 0; i < 4; i++)
    if (!omitZeros || q[i] != 0) ...pbFloatField(i + 1, q[i]),
];

/// A per frame record of the attitude track, laid out as the camera writes it: 1 the frame (1 its index, 2 its time
/// stamp in microseconds), 2 a few values with the quaternion of the frame in 9, 3 the run of attitude samples (3-2-1:
/// 1 the low 32 bits of the time stamp of its first sample, 2 a counter, 3 a quaternion per sample, 4 a float), 4 the
/// frame rate (4-1-5). A null argument leaves its field out.
List<int> djiAttitudeRecord({
  int? frameStampUs,
  int index = 0,
  int? runStampUs,
  List<List<double>> run = const [],
  List<double>? frameQuaternion,
  double? frameRate = 25,
}) => [
  ...pbBytesField(1, [
    if (index != 0) ...pbVarintField(1, index),
    if (frameStampUs != null) ...pbVarintField(2, frameStampUs),
  ]),
  ...pbBytesField(2, [
    ...pbBytesField(3, pbFloatField(1, 564)),
    ...pbBytesField(9, frameQuaternion == null ? [] : djiQuaternion(frameQuaternion)),
    ...pbBytesField(10, [...pbFloatField(2, 4.234), ...pbFloatField(3, -0.403)]),
  ]),
  ...pbBytesField(3, [
    ...pbBytesField(
      2,
      pbBytesField(1, [
        if (runStampUs != null) ...pbVarintField(1, runStampUs),
        ...pbVarintField(2, 16760 + index),
        for (final q in run) ...pbBytesField(3, djiQuaternion(q)),
        ...pbFloatField(4, 25.416),
      ]),
    ),
    ...pbBytesField(3, pbVarintField(1, 4)),
  ]),
  ...pbBytesField(4, [
    ...pbBytesField(1, [
      ...pbVarintField(1, 1),
      ...pbStringField(4, 'Osmo OQ001'),
      if (frameRate != null) ...pbFloatField(5, frameRate),
    ]),
  ]),
];

/// A per frame record of the second track: the same fields, without attitude
List<int> djiSecondTrackRecord({int index = 0}) => [
  ...pbBytesField(1, [if (index != 0) ...pbVarintField(1, index)]),
  ...pbBytesField(2, pbBytesField(9, [])),
  ...pbBytesField(3, [...pbBytesField(2, []), ...pbBytesField(3, [])]),
];

/// The records of the mdat of a camd box with the per frame records [frames] (the attitude record and the second
/// track record of each frame, their payloads), laid out as the sample: the header and config of the first track, the
/// first attitude record, the header and the config of the second track, then the records in order
List<int> djiMotionCamdRecords(List<(List<int>, List<int>)> frames, {List<int>? header}) => [
  ...pbBytesField(1, header ?? djiHeader()),
  ...pbBytesField(2, djiConfig()),
  for (final (i, (attitude, second)) in frames.indexed) ...[
    ...pbBytesField(3, attitude),
    if (i == 0) ...[
      ...pbBytesField(1, pbBytesField(1, pbStringField(1, 'dvtm_oq101.proto'))),
      ...pbBytesField(2, List.filled(36, 0)),
    ],
    ...pbBytesField(3, second),
  ],
];

/// The content of a camd box, a small MP4 of its own: ftyp, free, an mdat of [records], an empty moov
List<int> djiCamdContent(List<int> records) => [
  ...mp4Box('ftyp', [...ascii.encode('isom'), ...mp4Zeros(4), ...ascii.encode('isomiso2')]),
  ...mp4Box('free'),
  ...mp4Box('mdat', records),
  ...mp4Box('moov'),
];

/// A camd box: the content of [djiCamdContent]
List<int> djiCamdBox(List<int> records) => mp4Box('camd', djiCamdContent(records));

List<int> _djiVideo(int trackId) => mp4VideoTrack(
  [],
  width: 3840,
  height: 3840,
  config: mp4HvcC(profile: 2, highTier: true, flags: 0x20000000, level: 156, bitDepth: 10),
  timescale: 25000,
  timeToSample: [(585, 1000)],
  trackId: trackId,
  handlerType: 'vide',
  handlerName: 'VideoHandler',
  durationTicks: 585000,
);

/// The moov box of the sample: two square HEVC Main 10 videos, the sound, two djmd and two dbgi metadata tracks, then
/// the tracks of [more]
List<int> djiOsvMoov({List<List<int>> more = const []}) => mp4Moov([
  _djiVideo(1),
  _djiVideo(2),
  mp4AudioTrack(trackId: 3, handlerType: 'soun', handlerName: 'SoundHandler'),
  mp4MetaTrack('djmd', trackId: 4),
  mp4MetaTrack('djmd', trackId: 5),
  mp4MetaTrack('dbgi', handlerName: 'CAM dbgi', trackId: 6),
  mp4MetaTrack('dbgi', handlerName: 'CAM dbgi', trackId: 7),
  ...more,
]);

/// An Osmo 360 file: ftyp, the media data, the moov box of [djiOsvMoov], then [camd] (the camd box of the sample's
/// records by default)
Uint8List djiOsvFile({List<int>? camd}) =>
    mp4File(djiOsvMoov(), moovAtEnd: true, trailing: camd ?? djiCamdBox(djiCamdRecords()));

/// The camera of the Osmo 360 II sample (CAM_20260822131942_0016_D_1.osv, firmware 01.01.02.10); the serial is made up
const djiModel2 = 'Osmo 360 II';
const djiSerial2 = 'DXP7900000AB';
const djiFirmware2 = '01.01.02.10';
const djiSchema2 = 'dvtm_OQ102.proto';

/// Slot 1 of the Osmo 360 II sample: lens 0, video stream 0, the rear lens, turned half a turn about y
const djiLens2Rear = (
  fx: 1053.16,
  fy: 1052.9,
  cx: 1917.94,
  cy: 1915.26,
  k1: 0.0607044,
  k2: -0.00599649,
  k3: 0.00463063,
  k4: -0.0047307,
  k5: 0.000739646,
  yaw: -179.895,
  pitch: 90.8466,
  roll: 0.0551802,
  quaternion: [-0.000447347, -0.00322377, -0.999995, -0.0000606695],
  tangential: [0.0, 0.0],
);

/// Slot 2 of the Osmo 360 II sample: lens 1, video stream 1, the front lens, whose quaternion is the identity
const djiLens2Front = (
  fx: 1050.21,
  fy: 1050.05,
  cx: 1922.37,
  cy: 1919.53,
  k1: 0.0603333,
  k2: -0.00535294,
  k3: 0.00550366,
  k4: -0.0051927,
  k5: 0.000793635,
  yaw: 0.155815,
  pitch: 90.8544,
  roll: -0.314221,
  quaternion: [1.0, 0.0, 0.0, 0.0],
  tangential: [0.0, 0.0],
);

/// The records of the camd sample of an Osmo 360 II, laid out as the real one: its header, a config whose field 5
/// holds the two lenses (their quaternions written as protobuf 3 does, the zeros left out), then [frames] as
/// [djiMotionCamdRecords] lays them out
List<int> djiOsv2Records({List<(List<int>, List<int>)> frames = const [], int? firstFrameStampUs = 2465177400}) => [
  ...pbBytesField(
    1,
    djiHeader(
      model: djiModel2,
      serial: djiSerial2,
      firmware: djiFirmware2,
      schema: djiSchema2,
      firstFrameStampUs: firstFrameStampUs,
    ),
  ),
  ...pbBytesField(
    2,
    djiConfig(
      calibrationField: 5,
      calibration: djiCalibration({
        1: djiDewarpSlot(djiLens2Rear, omitZeros: true),
        2: djiDewarpSlot(djiLens2Front, omitZeros: true),
      }),
    ),
  ),
  for (final (attitude, second) in frames) ...[...pbBytesField(3, attitude), ...pbBytesField(3, second)],
];

/// An Osmo 360 II file: no camd box after its moov box, the same content ([djiCamdContent] of [records]) being the one
/// sample of a timed metadata track whose sample entry is camd (track 13 of the sample), in the media data after the
/// frames
Uint8List djiOsv2File(List<int> records) {
  const standIn = 64;
  final content = djiCamdContent(records);
  final offset = mp4Ftyp.length + 8 + standIn;
  final camdTrack = mp4Track(
    mp4FullBox('stsd', [...mp4Uint32(1), ...mp4Box('camd', mp4Zeros(16))]),
    trackId: 13,
    handlerType: 'meta',
    handlerName: 'CAM camd',
    timescale: 25000,
    timeToSample: [(1, 1000)],
    stsz: [
      ...mp4Stsz(sizes: [content.length]),
      ...mp4FullBox('stsc', [...mp4Uint32(1), ...mp4Uint32(1), ...mp4Uint32(1), ...mp4Uint32(1)]),
      ...mp4FullBox('stco', [...mp4Uint32(1), ...mp4Uint32(offset)]),
    ],
  );
  return mp4File(
    djiOsvMoov(more: [camdTrack]),
    moovAtEnd: true,
    mdat: mp4Box('mdat', [...List.filled(standIn, 0x11), ...content]),
  );
}

/// A per frame record of the attitude track of the Osmo 360 II, laid out as its sample: 1 the frame (1 its index, 2 its
/// time stamp in microseconds); 2 a few values, the frame rate among them (2-1-5, a float after the name of the camera
/// in 2-1-4) and the quaternion of the frame (22; 9 holds a varint there); 3 the run of attitude samples, as on the Osmo
/// 360 ([djiAttitudeRecord]); 4 the position (4-1: 1 a fix flag, 2 and 3 the latitude and the longitude as doubles, 0
/// here), and no frame rate in 4-1-5. A null argument leaves its field out.
List<int> djiAttitudeRecord2({
  int? frameStampUs,
  int index = 0,
  int? runStampUs,
  List<List<double>> run = const [],
  List<double>? frameQuaternion,
  double? frameRate = 25,
}) => [
  ...pbBytesField(1, [
    if (index != 0) ...pbVarintField(1, index),
    if (frameStampUs != null) ...pbVarintField(2, frameStampUs),
  ]),
  ...pbBytesField(2, [
    ...pbBytesField(1, [
      ...pbVarintField(2, 1),
      ...pbVarintField(3, 1),
      ...pbStringField(4, 'Osmo OQ002'),
      if (frameRate != null) ...pbFloatField(5, frameRate),
    ]),
    ...pbBytesField(3, pbFloatField(1, 1600)),
    ...pbBytesField(9, pbVarintField(1, 5296)),
    if (frameQuaternion != null) ...pbBytesField(22, djiQuaternion(frameQuaternion, omitZeros: true)),
  ]),
  ...pbBytesField(3, [
    ...pbBytesField(
      2,
      pbBytesField(1, [
        if (runStampUs != null) ...pbVarintField(1, runStampUs),
        ...pbVarintField(2, 32571 + index),
        for (final q in run) ...pbBytesField(3, djiQuaternion(q, omitZeros: true)),
      ]),
    ),
  ]),
  ...pbBytesField(4, [
    ...pbBytesField(1, [...pbVarintField(1, 1), ...pbDoubleField(2, 0), ...pbDoubleField(3, 0)]),
    ...pbVarintField(2, 61215),
  ]),
];
