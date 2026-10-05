// Synthetic DJI Osmo 360 .osv files for the tests of the camd parser: the protobuf records of the camd box (a header,
// a config whose field 6 holds the calibration slots, a frame record), the camd box itself (a small MP4 of its own),
// and a whole file with the tracks of the real sample. The lens values are those of the real sample
// CAM_20250715191201_0003_D.OSV (serial 95SXN6500213WL, firmware 10.00.05.06), as floats, as the camera writes them.

import 'dart:convert';
import 'dart:typed_data';

import '../../domain/services/spherical_probe_fixtures.dart';
import 'insta360.stub.dart';

const djiModel = 'Osmo 360';
const djiSerial = '95SXN6500213WL';
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
/// the quaternion again as a message of four floats (28) unless [withQuaternion] is false
List<int> djiDewarpSlot(DjiLensValues lens, {double width = 3840, double height = 3840, bool withQuaternion = true}) =>
    [
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
      if (withQuaternion) ...pbBytesField(28, [for (var i = 0; i < 4; i++) ...pbFloatField(i + 1, lens.quaternion[i])]),
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

/// A header record: field 1 names the schema (1), the camera (10), its serial (5) and firmware (6)
List<int> djiHeader({
  String model = djiModel,
  String serial = djiSerial,
  String firmware = djiFirmware,
  String schema = 'dvtm_oq101.proto',
}) => [
  ...pbBytesField(1, [
    ...pbStringField(1, schema),
    ...pbStringField(2, '02.01.13'),
    ...pbStringField(3, '2.0.5'),
    ...pbStringField(5, serial),
    ...pbStringField(6, firmware),
    ...pbVarintField(9, 18471494232),
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

/// A camd box: a small MP4 of its own (ftyp, free, an mdat of [records], an empty moov)
List<int> djiCamdBox(List<int> records) => mp4Box('camd', [
  ...mp4Box('ftyp', [...ascii.encode('isom'), ...mp4Zeros(4), ...ascii.encode('isomiso2')]),
  ...mp4Box('free'),
  ...mp4Box('mdat', records),
  ...mp4Box('moov'),
]);

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

/// The moov box of the sample: two square HEVC Main 10 videos, the sound, two djmd and two dbgi metadata tracks
List<int> djiOsvMoov() => mp4Moov([
  _djiVideo(1),
  _djiVideo(2),
  mp4AudioTrack(trackId: 3, handlerType: 'soun', handlerName: 'SoundHandler'),
  mp4MetaTrack('djmd', trackId: 4),
  mp4MetaTrack('djmd', trackId: 5),
  mp4MetaTrack('dbgi', handlerName: 'CAM dbgi', trackId: 6),
  mp4MetaTrack('dbgi', handlerName: 'CAM dbgi', trackId: 7),
]);

/// An Osmo 360 file: ftyp, the media data, the moov box of [djiOsvMoov], then [camd] (the camd box of the sample's
/// records by default)
Uint8List djiOsvFile({List<int>? camd}) =>
    mp4File(djiOsvMoov(), moovAtEnd: true, trailing: camd ?? djiCamdBox(djiCamdRecords()));
