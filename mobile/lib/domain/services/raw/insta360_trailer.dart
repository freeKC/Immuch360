// The trailer Insta360 cameras append to their files. A .insp photo is a JPEG with both fisheye circles side by side
// (lens 0 on the left), a .insv video an MP4, and both end with the same records. The last 72 bytes are 32 reserved
// bytes, the size of the trailer (u32 LE, these 72 bytes included), its version (u32 LE, 3) and the ASCII magic
// 8db42d694ccc418790edff439fe026bf. The records are walked backwards from there: each one is its payload followed by a
// footer of 6 bytes, its format (u8), its id (u8) and the length of its payload (u32 LE). Record 1 holds the metadata
// as protobuf, the calibration strings among them; record 3 the samples of the accelerometer and the gyroscope. On the
// X3 the metadata record comes last, so the calibration sits in the last 2 KB of the file. Older trailers (version 2,
// another magic) are not read: such a file is taken as a flat picture.
//
// The field numbers are those of telemetry-parser (MIT/Apache-2.0), checked on X3 files; see
// docs/16-dual-fisheye-spec.md, sections 1, 2 and 4.
//
// Pure Dart: the caller reads the bytes, from a file on the device or with HTTP range requests.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart' show ByteRangeReader;

/// The ASCII magic that ends a version 3 Insta360 trailer
const insta360TrailerMagic = '8db42d694ccc418790edff439fe026bf';

// The fixed tail of the trailer: 32 reserved bytes, the size, the version, the magic
const _tailLength = 72;
const _trailerVersion = 3;

// The footer that ends each record: format, id, length of the payload
const _footerLength = 6;

const _metadataRecord = 1;
const _imuRecord = 3;
const _protobufFormat = 1;

// Bytes read at once from the end of the file: on the X3 they hold the metadata record whole, and the footer of the
// record before it, so that a photo costs two reads (three with its accelerometer)
const _tailChunkLength = 64 * 1024;

// Bound on the records walked, so that a damaged trailer cannot make the reader loop
const _maxRecords = 64;

/// Most bytes of the metadata record read (about 2 KB on the X3): a longer one is taken as damaged
const insta360MaxMetadataLength = 1024 * 1024;

/// Most bytes of the IMU record read for the mean of the accelerometer: a photo has about 45 KB of samples, a long video
/// many MB, of which the first ones (about 50 seconds of raw samples on the X3) are enough to level the recording at
/// the cost of a short read over the network
const insta360MaxImuLength = 1024 * 1024;

// IMU samples. Raw (field 62 set): u64 timestamp in microseconds, then 3 accelerometer and 3 gyroscope u16 values,
// offset binary around 32768 and scaled by the range of field 65 over 32768. Otherwise: i64 milliseconds, then 6
// doubles, accelerometer in g first.
const _rawImuSampleLength = 20;
const _imuSampleLength = 56;
const _rawImuZero = 32768;

/// The window of the sensor a picture was cut from (field 27 of the metadata)
class Insta360Crop {
  const Insta360Crop({
    this.sourceWidth = 0,
    this.sourceHeight = 0,
    this.width = 0,
    this.height = 0,
    this.offsetX = 0,
    this.offsetY = 0,
  });

  final int sourceWidth;
  final int sourceHeight;
  final int width;
  final int height;
  final int offsetX;
  final int offsetY;

  @override
  bool operator ==(Object other) =>
      other is Insta360Crop &&
      other.sourceWidth == sourceWidth &&
      other.sourceHeight == sourceHeight &&
      other.width == width &&
      other.height == height &&
      other.offsetX == offsetX &&
      other.offsetY == offsetY;

  @override
  int get hashCode => Object.hash(sourceWidth, sourceHeight, width, height, offsetX, offsetY);

  @override
  String toString() => 'Insta360Crop($sourceWidth x $sourceHeight -> $width x $height at $offsetX, $offsetY)';
}

/// What the trailer of an Insta360 file says. A field the metadata does not have is null; all of them are when the
/// trailer has no readable metadata record, which still tells the file is a raw dual fisheye one.
class Insta360Trailer {
  const Insta360Trailer({
    this.serial,
    this.cameraModel,
    this.firmware,
    this.offsetV1,
    this.offsetV3,
    this.offsetV6,
    this.imageWidth,
    this.imageHeight,
    this.crop,
    this.accelerometerRange,
    this.gyroscopeRange,
    this.isRawGyro = false,
    this.meanAccelerometer,
    this.imuSampleCount = 0,
  });

  /// Serial number of the camera (field 1)
  final String? serial;

  /// Name of the camera, "Insta360 X3" (field 2)
  final String? cameraModel;

  /// Firmware version, "v1.0.93_build1" (field 3)
  final String? firmware;

  /// Calibration string V1, an equidistant fisheye per lens (field 5, or its factory copy 17)
  final String? offsetV1;

  /// Calibration string V3, the Mei model per lens (field 54, or 56)
  final String? offsetV3;

  /// Calibration string V6 of the newer cameras (field 111, or 112), read with its first terms when there is no V3
  final String? offsetV6;

  /// Size of the picture the camera took (field 19): the whole side by side photo of a .insp (11968 x 5984 or 5952 x
  /// 2976 on the X3), but the square of one lens for a video the camera records as a split pair, even in the trailer of
  /// its side by side LRV proxy (2880 x 2880 on the X3). The frame size of a video comes from its video track.
  final int? imageWidth;
  final int? imageHeight;

  /// Window of the sensor the picture was cut from (field 27)
  final Insta360Crop? crop;

  /// Full scale of the accelerometer in g and of the gyroscope in degrees per second (field 65)
  final double? accelerometerRange;
  final double? gyroscopeRange;

  /// Whether the IMU record holds raw 20 byte samples (field 62) rather than 56 byte ones
  final bool isRawGyro;

  /// Mean of the accelerometer samples read (x, y, z in the frame of the IMU): in g, or in units of the full scale
  /// when the trailer does not give it (only its direction matters for leveling). Null without samples.
  final List<double>? meanAccelerometer;

  /// Number of accelerometer samples in [meanAccelerometer]
  final int imuSampleCount;

  @override
  String toString() =>
      'Insta360Trailer(serial: $serial, cameraModel: $cameraModel, firmware: $firmware, '
      'image: $imageWidth x $imageHeight, crop: $crop, accelerometerRange: $accelerometerRange, '
      'gyroscopeRange: $gyroscopeRange, isRawGyro: $isRawGyro, meanAccelerometer: $meanAccelerometer '
      '($imuSampleCount samples), offsetV1: $offsetV1, offsetV3: $offsetV3, offsetV6: $offsetV6)';
}

/// Reads the trailer of the Insta360 file of [fileSize] bytes that [read] reads; null for a file without a version 3
/// trailer.
///
/// Reads the end of the file first, then walks the records backwards, a footer at a time, as far as the metadata and
/// the IMU records only. Reads at most [insta360MaxMetadataLength] bytes of metadata and [maxImuLength] bytes of IMU
/// samples, from the first ones. A damaged record ends the walk: the trailer then has what was read before it. Errors
/// of [read] are not caught.
Future<Insta360Trailer?> readInsta360Trailer(
  ByteRangeReader read,
  int fileSize, {
  int maxImuLength = insta360MaxImuLength,
}) async {
  if (fileSize < _tailLength) {
    return null;
  }
  final tailStart = math.max(0, fileSize - _tailChunkLength);
  final tail = await read(tailStart, fileSize - tailStart);
  if (tail.length != fileSize - tailStart || !_endsWithMagic(tail)) {
    return null;
  }
  final end = ByteData.sublistView(tail, tail.length - _tailLength);
  final trailerLength = end.getUint32(32, Endian.little);
  final version = end.getUint32(36, Endian.little);
  if (version != _trailerVersion || trailerLength < _tailLength || trailerLength > fileSize) {
    return null;
  }
  final payloadStart = fileSize - trailerLength;
  final bytes = _CachedBytes(read, tailStart, tail);

  _Record? metadataRecord;
  _Record? imuRecord;
  var recordEnd = fileSize - _tailLength;
  for (var count = 0; count < _maxRecords && recordEnd - _footerLength >= payloadStart; count++) {
    final footer = await bytes.at(recordEnd - _footerLength, _footerLength);
    if (footer == null) {
      break;
    }
    final data = ByteData.sublistView(footer);
    final format = data.getUint8(0);
    final id = data.getUint8(1);
    final length = data.getUint32(2, Endian.little);
    final start = recordEnd - _footerLength - length;
    if (start < payloadStart) {
      break;
    }
    if (id == _metadataRecord && metadataRecord == null) {
      metadataRecord = (format: format, start: start, length: length);
    } else if (id == _imuRecord && imuRecord == null) {
      imuRecord = (format: format, start: start, length: length);
    }
    if (metadataRecord != null && imuRecord != null) {
      break;
    }
    recordEnd = start;
  }

  final metadata = _Metadata();
  if (metadataRecord != null &&
      metadataRecord.format == _protobufFormat &&
      metadataRecord.length <= insta360MaxMetadataLength) {
    final payload = await bytes.at(metadataRecord.start, metadataRecord.length);
    if (payload != null) {
      metadata.decode(payload);
    }
  }

  List<double>? meanAccelerometer;
  var sampleCount = 0;
  if (imuRecord != null) {
    final sampleLength = metadata.isRawGyro ? _rawImuSampleLength : _imuSampleLength;
    final count = math.min(imuRecord.length, math.max(0, maxImuLength)) ~/ sampleLength;
    final samples = count > 0 ? await bytes.at(imuRecord.start, count * sampleLength) : null;
    if (samples != null) {
      meanAccelerometer = metadata.isRawGyro
          ? _meanRawAccelerometer(samples, count, metadata.accelerometerRange)
          : _meanAccelerometer(samples, count);
      sampleCount = meanAccelerometer == null ? 0 : count;
    }
  }

  return Insta360Trailer(
    serial: metadata.serial,
    cameraModel: metadata.cameraModel,
    firmware: metadata.firmware,
    offsetV1: metadata.offsetV1 ?? metadata.offsetV1Factory,
    offsetV3: metadata.offsetV3 ?? metadata.offsetV3Copy,
    offsetV6: metadata.offsetV6 ?? metadata.offsetV6Copy,
    imageWidth: metadata.imageWidth,
    imageHeight: metadata.imageHeight,
    crop: metadata.crop,
    accelerometerRange: metadata.accelerometerRange,
    gyroscopeRange: metadata.gyroscopeRange,
    isRawGyro: metadata.isRawGyro,
    meanAccelerometer: meanAccelerometer,
    imuSampleCount: sampleCount,
  );
}

/// The calibration of the file whose trailer is [trailer]: the Mei model of its V3 string, else the equidistant model
/// of its V1 string; null when it has neither. Gravity comes from the mean accelerometer of the trailer, else from
/// [accelerometer] (the sample of the MakerNote of a photo, see [readInsta360PhotoHead]), else the camera is taken as
/// upright.
DualFisheyeCalibration? calibrationOf(Insta360Trailer trailer, {List<double>? accelerometer}) {
  final v3 = trailer.offsetV3;
  final v6 = trailer.offsetV6;
  final v1 = trailer.offsetV1;
  // V3 first (validated against Insta360 Studio on the X3), then V6 read with its first terms (the only string of the
  // X6), then the equidistant V1 as a last resort
  final lenses =
      (v3 == null ? null : parseInsta360OffsetV3(v3)) ??
      (v6 == null ? null : parseInsta360OffsetV6(v6)) ??
      (v1 == null ? null : parseInsta360OffsetV1(v1));
  if (lenses == null) {
    return null;
  }
  return lenses.copyWith(
    downBody: downBodyFromAccelerometer(trailer.meanAccelerometer ?? accelerometer),
    serial: trailer.serial,
    cameraModel: trailer.cameraModel,
    source: DualFisheyeSource.file,
  );
}

// Tokens per lens of a V3 string: xi fx fy cx cy yaw pitch roll tx ty tz k1 k2 k3 p1 p2 w h type. The lens count comes
// first and a packed word last (packed >> 16 = 3): 40 tokens for two lenses. w and h are the size of the calibration
// canvas, one square per lens side by side (11904 x 5952 on the X3).
const _v3LensTokens = 19;

// Tokens per lens of a V6 string: xi fx fy cx cy yaw pitch roll tx ty tz k1 k2 k3 k4 k5 p1 p2 p3 p4 s1 s2 s3 s4 w h
// type, 56 tokens for two lenses (packed >> 16 = 6). The extra radial, tangential and thin prism terms are small
// corrections the stitch does not apply: the Mei model is read from the first terms, which is the same approximation as
// reading V3 on a camera that writes both.
const _v6LensTokens = 27;

// Tokens per lens of a V1 string: radius cx cy yaw pitch roll; then the canvas width and height and a packed word, 16
// tokens for two lenses
const _v1LensTokens = 6;

/// The Mei model of the V3 calibration string [offset] of a two lens camera, in canvas pixels and degrees; null when it
/// is not one
DualFisheyeCalibration? parseInsta360OffsetV3(String offset) {
  final tokens = _numbers(offset);
  if (tokens == null || tokens.length != 2 + 2 * _v3LensTokens || tokens[0] != 2) {
    return null;
  }
  final canvasSquare = tokens[1 + 17];
  if (canvasSquare <= 0) {
    return null;
  }
  DualFisheyeLens lens(int index) {
    final t = tokens.sublist(1 + index * _v3LensTokens, 1 + (index + 1) * _v3LensTokens);
    return DualFisheyeLens(
      xi: t[0],
      fx: t[1],
      fy: t[2],
      cx: t[3],
      cy: t[4],
      yaw: t[5],
      pitch: t[6],
      roll: t[7],
      // t[8] to t[10]: the offset of the lens from the centre of the camera, in metres, which the stitch neglects
      k1: t[11],
      k2: t[12],
      k3: t[13],
      p1: t[14],
      p2: t[15],
    );
  }

  return DualFisheyeCalibration(model: DualFisheyeModel.mei, lenses: [lens(0), lens(1)], canvasSquare: canvasSquare);
}

/// The Mei model read from the first terms of the V6 calibration string [offset] of a two lens camera (k4, k5, p3, p4
/// and the thin prism terms are ignored), in canvas pixels and degrees; null when it is not one
DualFisheyeCalibration? parseInsta360OffsetV6(String offset) {
  final tokens = _numbers(offset);
  if (tokens == null || tokens.length != 2 + 2 * _v6LensTokens || tokens[0] != 2) {
    return null;
  }
  final canvasSquare = tokens[1 + 25];
  if (canvasSquare <= 0) {
    return null;
  }
  DualFisheyeLens lens(int index) {
    final t = tokens.sublist(1 + index * _v6LensTokens, 1 + (index + 1) * _v6LensTokens);
    return DualFisheyeLens(
      xi: t[0],
      fx: t[1],
      fy: t[2],
      cx: t[3],
      cy: t[4],
      yaw: t[5],
      pitch: t[6],
      roll: t[7],
      k1: t[11],
      k2: t[12],
      k3: t[13],
      p1: t[16],
      p2: t[17],
    );
  }

  return DualFisheyeCalibration(model: DualFisheyeModel.mei, lenses: [lens(0), lens(1)], canvasSquare: canvasSquare);
}

/// The equidistant model of the V1 calibration string [offset] of a two lens camera, in canvas pixels and degrees; null
/// when it is not one. The order of the lens tokens is radius, cx, cy (the files contradict the README of
/// gitbellcreek/Insta360, which puts the radius last).
DualFisheyeCalibration? parseInsta360OffsetV1(String offset) {
  final tokens = _numbers(offset);
  if (tokens == null || tokens.length != 4 + 2 * _v1LensTokens || tokens[0] != 2) {
    return null;
  }
  final canvasSquare = tokens[1 + 2 * _v1LensTokens + 1];
  if (canvasSquare <= 0) {
    return null;
  }
  DualFisheyeLens lens(int index) {
    final t = tokens.sublist(1 + index * _v1LensTokens, 1 + (index + 1) * _v1LensTokens);
    return DualFisheyeLens(radius: t[0], cx: t[1], cy: t[2], yaw: t[3], pitch: t[4], roll: t[5]);
  }

  return DualFisheyeCalibration(
    model: DualFisheyeModel.equidistant,
    lenses: [lens(0), lens(1)],
    canvasSquare: canvasSquare,
  );
}

// The underscore separated numbers of [text], null when one is not a finite number
List<double>? _numbers(String text) {
  final numbers = <double>[];
  for (final token in text.trim().split('_')) {
    final value = double.tryParse(token);
    if (value == null || !value.isFinite) {
      return null;
    }
    numbers.add(value);
  }
  return numbers;
}

/// The IMU sample an Insta360 camera writes in the MakerNote of a photo: accelerometer in g, then gyroscope
class Insta360ImuSample {
  const Insta360ImuSample({required this.accelerometer, required this.gyroscope});

  final List<double> accelerometer;
  final List<double> gyroscope;

  @override
  String toString() => 'Insta360ImuSample(accelerometer: $accelerometer, gyroscope: $gyroscope)';
}

/// What the EXIF of an Insta360 photo tells in its first bytes: the camera that took it, and the IMU sample of its
/// MakerNote. A field the head does not have is null. A photo without a trailer (the members _008 and _009 of an X3
/// HDR group) names its camera here only.
class Insta360PhotoHead {
  const Insta360PhotoHead({this.cameraModel, this.serial, this.imu});

  /// Model of IFD0 (tag 0x0110), "Insta360 X3": the name the trailer gives too (field 2)
  final String? cameraModel;

  /// BodySerialNumber of the Exif IFD (tag 0xA431), which the X3 does not write
  final String? serial;

  /// The IMU sample of the MakerNote, which levels a photo whose trailer has none
  final Insta360ImuSample? imu;

  @override
  String toString() => 'Insta360PhotoHead(cameraModel: $cameraModel, serial: $serial, imu: $imu)';
}

/// Bytes of the head of a photo read for its EXIF
const insta360PhotoHeadLength = 4 * 1024;

/// Reads the EXIF head of the Insta360 photo that [read] reads (see [parseInsta360PhotoHead]): a fallback for leveling
/// when the trailer has no IMU record, and for naming the camera when there is no trailer. Errors of [read] are not
/// caught.
Future<Insta360PhotoHead?> readInsta360PhotoHead(ByteRangeReader read) async =>
    parseInsta360PhotoHead(await read(0, insta360PhotoHeadLength));

// EXIF tags of the head of a photo
const _modelTag = 0x0110;
const _exifIfdTag = 0x8769;
const _makerNoteTag = 0x927c;
const _bodySerialNumberTag = 0xa431;

/// The camera and the IMU sample of the EXIF of an Insta360 photo whose first bytes are [head]; null when it has none
/// of them there.
///
/// It is read the way EXIF is: the APP1 segment of the JPEG, its TIFF header, then IFD0, with the Model (tag 0x0110)
/// and the Exif IFD it points to (tag 0x8769), with the BodySerialNumber (tag 0xA431, absent on the X3) and the
/// MakerNote (tag 0x927C). The camera writes in the MakerNote one IMU sample as ASCII, six underscore separated numbers,
/// accelerometer then gyroscope, padded with zeros: "-1.003906_-0.124023_0.082031_0.024501_0.007457_0.053263". On the
/// X3 that value starts at byte 1211 of the file, right after the ASCII values of IFD0 (Make "Arashi Vision", Model
/// "Insta360 X3", firmware, dates), so the first 4 KB of the file hold it all.
Insta360PhotoHead? parseInsta360PhotoHead(Uint8List head) {
  final tiff = _exifTiffStart(head);
  if (tiff == null || tiff + 8 > head.length) {
    return null;
  }
  final data = ByteData.sublistView(head);
  final Endian endian;
  switch (String.fromCharCodes(head, tiff, tiff + 2)) {
    case 'II':
      endian = Endian.little;
    case 'MM':
      endian = Endian.big;
    default:
      return null;
  }
  if (data.getUint16(tiff + 2, endian) != 42) {
    return null;
  }
  String? text(int ifd, int tag) {
    final value = _ifdEntry(data, tiff, ifd, tag, endian);
    return value == null ? null : _exifText(head, data, tiff, value, endian);
  }

  final ifd0 = data.getUint32(tiff + 4, endian);
  final cameraModel = text(ifd0, _modelTag);
  final exifEntry = _ifdEntry(data, tiff, ifd0, _exifIfdTag, endian);
  final exifIfd = exifEntry == null ? null : data.getUint32(exifEntry, endian);
  final serial = exifIfd == null ? null : text(exifIfd, _bodySerialNumberTag);
  final makerNote = exifIfd == null ? null : text(exifIfd, _makerNoteTag);
  final numbers = makerNote == null ? null : _numbers(makerNote);
  final imu = numbers == null || numbers.length != 6
      ? null
      : Insta360ImuSample(accelerometer: numbers.sublist(0, 3), gyroscope: numbers.sublist(3));
  if (cameraModel == null && serial == null && imu == null) {
    return null;
  }
  return Insta360PhotoHead(cameraModel: cameraModel, serial: serial, imu: imu);
}

// Where the TIFF header of the EXIF of the JPEG [head] starts: the segments are walked from the start of the image to the
// APP1 segment that begins with "Exif\0\0". Null for a file that is not a JPEG, or without EXIF in [head].
int? _exifTiffStart(Uint8List head) {
  if (head.length < 4 || head[0] != 0xff || head[1] != 0xd8) {
    return null;
  }
  var offset = 2;
  while (offset + 4 <= head.length) {
    if (head[offset] != 0xff) {
      return null;
    }
    final marker = head[offset + 1];
    if (marker == 0xff) {
      // Fill byte before a marker
      offset++;
      continue;
    }
    // Start of the scan or end of the image: no EXIF before the picture data
    if (marker == 0xda || marker == 0xd9) {
      return null;
    }
    final length = head[offset + 2] << 8 | head[offset + 3];
    if (marker == 0xe1 && offset + 10 <= head.length && String.fromCharCodes(head, offset + 4, offset + 8) == 'Exif') {
      return offset + 10;
    }
    offset += 2 + length;
  }
  return null;
}

// The position of the value field (its last 4 bytes) of the entry [tag] of the IFD at [ifdOffset] from the TIFF header
// at [tiff], null when that IFD is not in [data] or has no such entry
int? _ifdEntry(ByteData data, int tiff, int ifdOffset, int tag, Endian endian) {
  final ifd = tiff + ifdOffset;
  if (ifdOffset < 8 || ifd + 2 > data.lengthInBytes) {
    return null;
  }
  final count = data.getUint16(ifd, endian);
  for (var i = 0; i < count; i++) {
    final entry = ifd + 2 + 12 * i;
    if (entry + 12 > data.lengthInBytes) {
      return null;
    }
    if (data.getUint16(entry, endian) == tag) {
      return entry + 8;
    }
  }
  return null;
}

// The text of the EXIF entry whose value field is at [value] (see [_ifdEntry]): its printable ASCII up to the first NUL
// or other control byte, trimmed; null when it is empty or not in [head]
String? _exifText(Uint8List head, ByteData data, int tiff, int value, Endian endian) {
  final count = data.getUint32(value - 4, endian);
  // A value of more than 4 bytes sits at the offset the entry gives, from the TIFF header
  final start = count <= 4 ? value : tiff + data.getUint32(value, endian);
  if (start >= head.length) {
    return null;
  }
  var stop = start;
  while (stop < head.length && stop < start + count && head[stop] >= 0x20 && head[stop] < 0x7f) {
    stop++;
  }
  final text = String.fromCharCodes(head, start, stop).trim();
  return text.isEmpty ? null : text;
}

bool _endsWithMagic(Uint8List bytes) {
  final magic = ascii.encode(insta360TrailerMagic);
  final start = bytes.length - magic.length;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[start + i] != magic[i]) {
      return false;
    }
  }
  return true;
}

typedef _Record = ({int format, int start, int length});

/// Bytes of the file: out of the tail read first when they are in it, else read
class _CachedBytes {
  _CachedBytes(this._read, this._tailStart, this._tail);

  final ByteRangeReader _read;
  final int _tailStart;
  final Uint8List _tail;

  /// The [length] bytes at [offset], null when the file has fewer
  Future<Uint8List?> at(int offset, int length) async {
    final start = offset - _tailStart;
    if (start >= 0 && start + length <= _tail.length) {
      return Uint8List.sublistView(_tail, start, start + length);
    }
    final bytes = await _read(offset, length);
    return bytes.length < length ? null : bytes;
  }
}

// Mean of the accelerometer of [count] raw samples, scaled by [range] (in g) over the half span of the u16 values
List<double> _meanRawAccelerometer(Uint8List samples, int count, double? range) {
  final data = ByteData.sublistView(samples);
  final scale = (range ?? 1) / _rawImuZero;
  var x = 0.0;
  var y = 0.0;
  var z = 0.0;
  for (var i = 0; i < count; i++) {
    final sample = i * _rawImuSampleLength + 8;
    x += data.getUint16(sample, Endian.little) - _rawImuZero;
    y += data.getUint16(sample + 2, Endian.little) - _rawImuZero;
    z += data.getUint16(sample + 4, Endian.little) - _rawImuZero;
  }
  return [x / count * scale, y / count * scale, z / count * scale];
}

// Mean of the accelerometer of [count] samples of doubles, leaving out the ones that are not finite
List<double>? _meanAccelerometer(Uint8List samples, int count) {
  final data = ByteData.sublistView(samples);
  var x = 0.0;
  var y = 0.0;
  var z = 0.0;
  var used = 0;
  for (var i = 0; i < count; i++) {
    final sample = i * _imuSampleLength + 8;
    final ax = data.getFloat64(sample, Endian.little);
    final ay = data.getFloat64(sample + 8, Endian.little);
    final az = data.getFloat64(sample + 16, Endian.little);
    if (ax.isFinite && ay.isFinite && az.isFinite) {
      x += ax;
      y += ay;
      z += az;
      used++;
    }
  }
  return used == 0 ? null : [x / used, y / used, z / used];
}

// Protobuf wire types
const _varint = 0;
const _fixed64 = 1;
const _lengthDelimited = 2;
const _fixed32 = 5;

/// A field of a protobuf message: its number, its wire type, and its value: the integer of a varint, the bytes of the
/// other wire types (8 for a 64 bit field, 4 for a 32 bit one)
class _ProtoField {
  const _ProtoField(this.number, this.wireType, {this.integer = 0, this.bytes});

  final int number;
  final int wireType;
  final int integer;
  final Uint8List? bytes;

  String? get string => wireType == _lengthDelimited ? utf8.decode(bytes!, allowMalformed: true) : null;

  /// The value as a number whatever its encoding: a varint, a float or a double
  double? get asDouble => switch (wireType) {
    _varint => integer.toDouble(),
    _fixed32 => ByteData.sublistView(bytes!).getFloat32(0, Endian.little),
    _fixed64 => ByteData.sublistView(bytes!).getFloat64(0, Endian.little),
    _ => null,
  };
}

/// The fields of the protobuf message [bytes], in their order. A truncated field, or a group (wire types 3 and 4, long
/// deprecated and not in these messages), ends the message with a [FormatException].
Iterable<_ProtoField> _protoFields(Uint8List bytes) sync* {
  var offset = 0;

  int varint() {
    var value = 0;
    for (var shift = 0; shift < 64; shift += 7) {
      if (offset >= bytes.length) {
        throw const FormatException('Truncated varint');
      }
      final byte = bytes[offset++];
      value |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) {
        return value;
      }
    }
    throw const FormatException('Varint too long');
  }

  Uint8List take(int length) {
    if (length < 0 || offset + length > bytes.length) {
      throw const FormatException('Truncated field');
    }
    final field = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return field;
  }

  while (offset < bytes.length) {
    final key = varint();
    final number = key >> 3;
    final wireType = key & 7;
    yield switch (wireType) {
      _varint => _ProtoField(number, wireType, integer: varint()),
      _fixed64 => _ProtoField(number, wireType, bytes: take(8)),
      _lengthDelimited => _ProtoField(number, wireType, bytes: take(varint())),
      _fixed32 => _ProtoField(number, wireType, bytes: take(4)),
      _ => throw FormatException('Unsupported wire type $wireType'),
    };
  }
}

/// The fields of the metadata record the reader keeps, the first of each
class _Metadata {
  String? serial;
  String? cameraModel;
  String? firmware;
  String? offsetV1;
  String? offsetV1Factory;
  String? offsetV3;
  String? offsetV3Copy;
  String? offsetV6;
  String? offsetV6Copy;
  int? imageWidth;
  int? imageHeight;
  Insta360Crop? crop;
  double? accelerometerRange;
  double? gyroscopeRange;
  bool isRawGyro = false;

  /// Reads the protobuf message [bytes]; a damaged message keeps the fields before the damage
  void decode(Uint8List bytes) {
    try {
      for (final field in _protoFields(bytes)) {
        switch (field.number) {
          case 1:
            serial ??= field.string;
          case 2:
            cameraModel ??= field.string;
          case 3:
            firmware ??= field.string;
          case 5:
            offsetV1 ??= field.string;
          case 17:
            offsetV1Factory ??= field.string;
          case 19 when field.wireType == _lengthDelimited:
            _decodeDimension(field.bytes!);
          case 27 when field.wireType == _lengthDelimited:
            crop ??= _decodeCrop(field.bytes!);
          case 54:
            offsetV3 ??= field.string;
          case 56:
            offsetV3Copy ??= field.string;
          case 62 when field.wireType == _varint:
            isRawGyro = field.integer != 0;
          case 65 when field.wireType == _lengthDelimited:
            _decodeImuRanges(field.bytes!);
          case 111:
            offsetV6 ??= field.string;
          case 112:
            offsetV6Copy ??= field.string;
        }
      }
    } on FormatException {
      // The fields read so far stay
    }
  }

  void _decodeDimension(Uint8List bytes) {
    for (final field in _protoFields(bytes)) {
      if (field.wireType != _varint) {
        continue;
      }
      switch (field.number) {
        case 1:
          imageWidth ??= field.integer;
        case 2:
          imageHeight ??= field.integer;
      }
    }
  }

  Insta360Crop _decodeCrop(Uint8List bytes) {
    final values = List.filled(6, 0);
    for (final field in _protoFields(bytes)) {
      if (field.wireType == _varint && field.number >= 1 && field.number <= 6) {
        values[field.number - 1] = field.integer;
      }
    }
    return Insta360Crop(
      sourceWidth: values[0],
      sourceHeight: values[1],
      width: values[2],
      height: values[3],
      offsetX: values[4],
      offsetY: values[5],
    );
  }

  // The X3 writes both ranges as varints (32 g, 2000 degrees per second); the schema has them as floats
  void _decodeImuRanges(Uint8List bytes) {
    for (final field in _protoFields(bytes)) {
      switch (field.number) {
        case 1:
          accelerometerRange ??= field.asDouble;
        case 2:
          gyroscopeRange ??= field.asDouble;
      }
    }
  }
}
