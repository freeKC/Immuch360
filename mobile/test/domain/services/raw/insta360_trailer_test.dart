import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/insta360_trailer.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

import '../../../fixtures/raw/insta360.stub.dart';

/// Reads [file] as a local file or a server does: fewer bytes at the end, none past it. Records each read.
ByteRangeReader _reader(Uint8List file, [List<(int, int)>? reads]) => (offset, length) async {
  reads?.add((offset, length));
  if (offset >= file.length) {
    return Uint8List(0);
  }
  return Uint8List.sublistView(file, offset, math.min(file.length, offset + length));
};

Future<Insta360Trailer?> _trailer(Uint8List file, {List<(int, int)>? reads, int? maxImuLength}) => maxImuLength == null
    ? readInsta360Trailer(_reader(file, reads), file.length)
    : readInsta360Trailer(_reader(file, reads), file.length, maxImuLength: maxImuLength);

// Raw accelerometer values of 32 g full scale (1024 per g) around the X3 photo's gravity: -1028, -127 and 84 from zero
const _x3Raw = (32768 - 1028, 32768 - 127, 32768 + 84);
const _x3Accelerometer = [-1028 / 1024, -127 / 1024, 84 / 1024];

// Gravity in the body frame for that accelerometer, as the prototype of the stitch computes it
const _x3DownBody = [0.98920772, -0.08082998, -0.12220717];

/// Two raw samples whose mean is [_x3Raw]
List<int> _x3ImuRecord() => insta360Record(
  3,
  rawImuSamples([(_x3Raw.$1 + 10, _x3Raw.$2 - 6, _x3Raw.$3 + 2), (_x3Raw.$1 - 10, _x3Raw.$2 + 6, _x3Raw.$3 - 2)]),
);

List<int> _metadataRecord(List<int> metadata) => insta360Record(1, metadata, format: 1);

/// An X3 photo: IMU samples, a thumbnail, then the metadata next to the tail, as the camera writes them
Uint8List _x3Photo({List<int>? metadata, int thumbnailLength = 2000}) => insta360File([
  _x3ImuRecord(),
  insta360Record(2, List.filled(thumbnailLength, 0x55)),
  _metadataRecord(metadata ?? x3Metadata()),
]);

Matcher _closeToList(List<double> expected, [double delta = 1e-6]) => predicate<List<double>>(
  (values) =>
      values.length == expected.length &&
      [for (var i = 0; i < values.length; i++) (values[i] - expected[i]).abs() <= delta].every((close) => close),
  'a list within $delta of $expected',
);

void main() {
  group('readInsta360Trailer', () {
    test('reads every field of the metadata and the mean of the raw accelerometer of an X3 photo', () async {
      final trailer = await _trailer(_x3Photo());

      expect(trailer, isNotNull);
      expect(trailer!.serial, x3Serial);
      expect(trailer.cameraModel, x3Model);
      expect(trailer.firmware, x3Firmware);
      expect(trailer.offsetV1, x3OffsetV1);
      expect(trailer.offsetV3, x3OffsetV3);
      expect(trailer.offsetV6, isNull);
      expect(trailer.imageWidth, 11968);
      expect(trailer.imageHeight, 5984);
      expect(trailer.crop, const Insta360Crop(sourceWidth: 5952, sourceHeight: 5952, width: 5984, height: 5984));
      expect(trailer.accelerometerRange, 32);
      expect(trailer.gyroscopeRange, 2000);
      expect(trailer.isRawGyro, isTrue);
      expect(trailer.imuSampleCount, 2);
      expect(trailer.meanAccelerometer, _closeToList(_x3Accelerometer));
    });

    test('takes the ranges of the IMU as floats too, and scales the raw samples by the accelerometer range', () async {
      final trailer = await _trailer(_x3Photo(metadata: x3Metadata(floatRanges: true)));

      expect(trailer!.accelerometerRange, 16);
      expect(trailer.gyroscopeRange, 1000);
      expect(trailer.meanAccelerometer, _closeToList([for (final g in _x3Accelerometer) g / 2]));
    });

    test('gives the raw accelerometer in units of the full scale when the trailer has no range', () async {
      final trailer = await _trailer(_x3Photo(metadata: x3Metadata(withRanges: false)));

      expect(trailer!.accelerometerRange, isNull);
      expect(trailer.meanAccelerometer, _closeToList([for (final g in _x3Accelerometer) g / 32]));
    });

    test('reads samples of doubles when the metadata does not say the gyro is raw, leaving out broken ones', () async {
      final file = insta360File([
        insta360Record(3, imuSamples([(-0.98, 0.1, 0.2), (double.nan, 0, 0), (-1.02, 0.3, 0.0)])),
        _metadataRecord(x3Metadata(rawGyro: null)),
      ]);

      final trailer = await _trailer(file);

      expect(trailer!.isRawGyro, isFalse);
      expect(trailer.imuSampleCount, 3);
      expect(trailer.meanAccelerometer, _closeToList([-1.0, 0.2, 0.1]));
    });

    test('reads the tail, the footer of the IMU record and its samples, and none of the thumbnail', () async {
      const thumbnailLength = 200 * 1024;
      final file = _x3Photo(thumbnailLength: thumbnailLength);
      final reads = <(int, int)>[];

      final trailer = await _trailer(file, reads: reads);

      expect(trailer!.meanAccelerometer, isNotNull);
      expect(reads, hasLength(3));
      final imuStart = jpegStub.length;
      expect(reads[0], (file.length - 64 * 1024, 64 * 1024), reason: 'the tail, metadata included');
      expect(reads[1], (imuStart + 40, 6), reason: 'the footer of the IMU record');
      expect(reads[2], (imuStart, 40), reason: 'the two IMU samples');
    });

    test('reads a small file once', () async {
      final reads = <(int, int)>[];

      await _trailer(_x3Photo(), reads: reads);

      expect(reads, hasLength(1));
    });

    test('reads the first IMU samples only, up to the limit', () async {
      final file = insta360File([
        insta360Record(
          3,
          rawImuSamples([
            for (var i = 0; i < 1000; i++) i < 10 ? (32768 + 1024, 32768, 32768) : (32768 - 1024, 32768, 32768),
          ]),
        ),
        _metadataRecord(x3Metadata()),
      ]);
      final reads = <(int, int)>[];

      final trailer = await _trailer(file, reads: reads, maxImuLength: 205);

      expect(trailer!.imuSampleCount, 10);
      expect(trailer.meanAccelerometer, _closeToList([1.0, 0.0, 0.0]));
    });

    test('has no accelerometer without an IMU record', () async {
      final trailer = await _trailer(insta360File([_metadataRecord(x3Metadata())]));

      expect(trailer!.meanAccelerometer, isNull);
      expect(trailer.imuSampleCount, 0);
      expect(trailer.serial, x3Serial);
    });

    test('tells an Insta360 file without metadata, with nothing in it', () async {
      final trailer = await _trailer(insta360File([insta360Record(2, List.filled(100, 1))]));

      expect(trailer, isNotNull);
      expect(trailer!.serial, isNull);
      expect(trailer.offsetV3, isNull);
      expect(calibrationOf(trailer), isNull);
    });

    test('does not read metadata in another format than protobuf', () async {
      final trailer = await _trailer(insta360File([insta360Record(1, x3Metadata(), format: 2)]));

      expect(trailer!.serial, isNull);
    });

    test('keeps the fields before the damage of a truncated metadata message', () async {
      // A V3 string cut short at the end of the message
      final metadata = [...x3Metadata(offsetV3: null), ...pbStringField(54, x3OffsetV3).sublist(0, 100)];

      final trailer = await _trailer(insta360File([_metadataRecord(metadata)]));

      expect(trailer!.serial, x3Serial);
      expect(trailer.offsetV1, x3OffsetV1);
      expect(trailer.imageWidth, 11968);
      expect(trailer.isRawGyro, isTrue);
      expect(trailer.offsetV3, isNull);
    });

    test('ends the walk at a record running before the trailer, keeping what was read', () async {
      final damaged = [...List.filled(10, 0), 0, 7, ...u32le(1 << 20)];
      final file = insta360File([_x3ImuRecord(), damaged, _metadataRecord(x3Metadata())]);

      final trailer = await _trailer(file);

      expect(trailer!.serial, x3Serial);
      expect(trailer.meanAccelerometer, isNull);
    });

    test('takes a file without the Insta360 tail as a flat one', () async {
      final valid = _x3Photo();

      expect(await _trailer(Uint8List.fromList(jpegStub)), isNull, reason: 'too short');
      expect(await _trailer(Uint8List.fromList([...jpegStub, ...List.filled(100, 0)])), isNull, reason: 'no magic');
      expect(
        await _trailer(insta360File([_metadataRecord(x3Metadata())], magic: '9c792b1ac55c40418d36ffb0d1d16b58')),
        isNull,
        reason: 'another magic',
      );
      expect(await _trailer(insta360File([_metadataRecord(x3Metadata())], version: 2)), isNull, reason: 'version 2');
      expect(
        await _trailer(insta360File([_metadataRecord(x3Metadata())], trailerLength: valid.length * 2)),
        isNull,
        reason: 'a trailer longer than the file',
      );
      expect(await _trailer(insta360File([], trailerLength: 10)), isNull, reason: 'a trailer shorter than its tail');
    });
  });

  group('calibrationOf', () {
    test('builds the Mei model of the V3 string of an X3, levelled by the accelerometer of the trailer', () async {
      final calibration = calibrationOf((await _trailer(_x3Photo()))!);

      expect(calibration, isNotNull);
      expect(calibration!.model, DualFisheyeModel.mei);
      expect(calibration.source, DualFisheyeSource.file);
      expect(calibration.serial, x3Serial);
      expect(calibration.cameraModel, x3Model);
      expect(calibration.canvasSquare, 5952);
      expect(calibration.downBody, _closeToList(_x3DownBody, 1e-5));
      expect(calibration.lenses, hasLength(2));

      final lens0 = calibration.lenses[0];
      expect(lens0.xi, 1.948170);
      expect(lens0.fx, 4627.54);
      expect(lens0.fy, 4627.46);
      expect(lens0.cx, 2967.48);
      expect(lens0.cy, 2999.85);
      expect(lens0.yaw, -0.029);
      expect(lens0.pitch, -0.038);
      expect(lens0.roll, 89.510);
      expect(lens0.k1, 0.38808271);
      expect(lens0.k2, 1.29547262);
      expect(lens0.k3, -3.96876335);
      expect(lens0.p1, 0.00178320);
      expect(lens0.p2, -0.00158561);
      expect(lens0.radius, isNull);

      final lens1 = calibration.lenses[1];
      expect(lens1.xi, 1.948170);
      expect(lens1.fx, 4615.53);
      expect(lens1.fy, 4615.53);
      expect(lens1.cx, 8933.20);
      expect(lens1.cy, 2998.62);
      expect(lens1.yaw, -0.030);
      expect(lens1.pitch, -0.086);
      expect(lens1.roll, 89.487);
      expect(lens1.k1, 0.39306432);
      expect(lens1.k2, 1.25673521);
      expect(lens1.k3, -3.90715361);
      expect(lens1.p1, -0.00147705);
      expect(lens1.p2, 0.00090004);
    });

    test('falls back on the equidistant model of the V1 string without a usable V3 one', () async {
      for (final offsetV3 in [null, '2_1_2_3', x3OffsetV3.replaceFirst('4627.540', 'x')]) {
        final calibration = calibrationOf((await _trailer(_x3Photo(metadata: x3Metadata(offsetV3: offsetV3))))!);

        expect(calibration!.model, DualFisheyeModel.equidistant, reason: 'V3 $offsetV3');
        expect(calibration.canvasSquare, 5952);
        final [lens0, lens1] = calibration.lenses;
        expect(
          [lens0.radius, lens0.cx, lens0.cy, lens0.yaw, lens0.pitch, lens0.roll],
          [2905.880, 2960.630, 3009.220, 0.171, 0.125, 89.532],
        );
        expect(
          [lens1.radius, lens1.cx, lens1.cy, lens1.yaw, lens1.pitch, lens1.roll],
          [2897.780, 8937.430, 3000.010, -0.013, -0.020, 89.463],
        );
        expect(lens0.xi, isNull);
        expect(lens0.fx, isNull);
      }
    });

    test('has no calibration without a calibration string', () async {
      final trailer = await _trailer(_x3Photo(metadata: x3Metadata(offsetV1: null, offsetV3: null)));

      expect(calibrationOf(trailer!), isNull);
    });

    test('levels with the accelerometer given when the trailer has none, upright without any', () async {
      final trailer = (await _trailer(insta360File([_metadataRecord(x3Metadata())])))!;

      expect(calibrationOf(trailer)!.downBody, [1.0, 0.0, 0.0]);
      expect(
        calibrationOf(trailer, accelerometer: [-1.003906, -0.124023, 0.082031])!.downBody,
        _closeToList(_x3DownBody, 1e-6),
      );
    });

    test('prefers the accelerometer of the trailer to the one given', () async {
      final trailer = (await _trailer(_x3Photo()))!;

      expect(calibrationOf(trailer, accelerometer: [0, 0, 1])!.downBody, _closeToList(_x3DownBody, 1e-5));
    });
  });

  group('parseInsta360OffsetV3 and parseInsta360OffsetV1', () {
    test('refuse strings of another length or lens count', () {
      expect(parseInsta360OffsetV3(x3OffsetV1), isNull);
      expect(parseInsta360OffsetV1(x3OffsetV3), isNull);
      expect(parseInsta360OffsetV3(x3OffsetV3.replaceFirst('2_', '3_')), isNull);
      expect(parseInsta360OffsetV1(''), isNull);
      expect(parseInsta360OffsetV1(x3OffsetV1.replaceFirst('_5952_', '_0_')), isNull, reason: 'no canvas');
      expect(parseInsta360OffsetV6(x3OffsetV3), isNull);
    });

    test('reads a V6 string with the first terms of the Mei model', () {
      // A V6 string built from the X3 V3 values: k4 k5 after k3, p3 p4 after p2, then s1..s4, per lens
      final v3 = x3OffsetV3.split('_');
      String v6Lens(int index) {
        final t = v3.sublist(1 + index * 19, 1 + (index + 1) * 19);
        return [
          ...t.sublist(0, 14),
          '0.01',
          '0.02',
          ...t.sublist(14, 16),
          '0.03',
          '0.04',
          '0',
          '0',
          '0',
          '0',
          ...t.sublist(16),
        ].join('_');
      }

      final packed = (6 << 16) | (int.parse(v3.last) & 0xffff);
      final v6 = '2_${v6Lens(0)}_${v6Lens(1)}_$packed';
      final fromV6 = parseInsta360OffsetV6(v6)!;
      final fromV3 = parseInsta360OffsetV3(x3OffsetV3)!;

      expect(fromV6.model, DualFisheyeModel.mei);
      expect(fromV6.canvasSquare, fromV3.canvasSquare);
      for (var i = 0; i < 2; i++) {
        expect(fromV6.lenses[i].toJson(), fromV3.lenses[i].toJson(), reason: 'lens $i');
      }
      expect(parseInsta360OffsetV3(v6), isNull);
    });
  });

  group('photo head', () {
    test('reads the camera model and the IMU sample of the MakerNote of an X3 photo', () {
      for (final (bigEndian, app0) in [(false, false), (true, false), (false, true)]) {
        final head = parseInsta360PhotoHead(insta360PhotoHead(bigEndian: bigEndian, app0: app0));

        expect(head, isNotNull, reason: 'big endian $bigEndian, JFIF $app0');
        expect(head!.cameraModel, x3Model);
        expect(head.serial, isNull, reason: 'the X3 writes no BodySerialNumber');
        expect(head.imu!.accelerometer, [-1.003906, -0.124023, 0.082031]);
        expect(head.imu!.gyroscope, [0.024501, 0.007457, 0.053263]);
      }
    });

    test('reads the BodySerialNumber of a camera that writes one', () {
      for (final bigEndian in [false, true]) {
        final head = parseInsta360PhotoHead(insta360PhotoHead(serial: x3Serial, bigEndian: bigEndian))!;

        expect(head.serial, x3Serial, reason: 'big endian $bigEndian');
        expect(head.cameraModel, x3Model);
        expect(head.imu, isNotNull);
      }
    });

    test('reads the first 4 KB of the photo', () async {
      final head = insta360PhotoHead();
      final file = Uint8List.fromList([...head, ...List.filled(10000, 0)]);
      final reads = <(int, int)>[];

      final read = await readInsta360PhotoHead(_reader(file, reads));

      expect(read!.imu!.accelerometer, [-1.003906, -0.124023, 0.082031]);
      expect(read.cameraModel, x3Model);
      expect(reads, [(0, 4096)]);
    });

    test('keeps the camera of a MakerNote of another kind', () {
      for (final makerNote in ['Nikon', '1_2_3_4_5', '']) {
        final head = parseInsta360PhotoHead(insta360PhotoHead(makerNote: makerNote));

        expect(head!.imu, isNull, reason: makerNote);
        expect(head.cameraModel, x3Model, reason: makerNote);
      }
    });

    test('has nothing without the camera nor the sample, or for a file that is not a JPEG', () {
      expect(parseInsta360PhotoHead(insta360PhotoHead(makerNote: 'Nikon', model: null)), isNull);
      expect(parseInsta360PhotoHead(Uint8List.fromList(List.filled(4096, 0))), isNull);
      expect(parseInsta360PhotoHead(Uint8List.fromList(jpegStub)), isNull);
      // Cut before the values of the entries
      expect(parseInsta360PhotoHead(Uint8List.sublistView(insta360PhotoHead(), 0, 60)), isNull);
    });
  });
}
