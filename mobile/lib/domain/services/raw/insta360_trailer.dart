// The trailer Insta360 cameras append to their files. A .insp photo is a JPEG with both fisheye circles side by side
// (lens 0 on the left), a .insv video an MP4, and both end with the same records. The last 72 bytes are 32 reserved
// bytes, the size of the trailer (u32 LE, these 72 bytes included), its version (u32 LE, 3) and the ASCII magic
// 8db42d694ccc418790edff439fe026bf. Each record is its payload followed by a footer of 6 bytes, its format (u8), its id
// (u8) and the length of its payload (u32 LE). Record 1 holds the metadata as protobuf, the calibration strings among
// them; record 3 the samples of the accelerometer and the gyroscope. Older trailers (version 2, another magic) are not
// read: such a file is taken as a flat picture.
//
// Two layouts of the records exist. On the X3 and older cameras they are walked backwards from the tail, the metadata
// record last, so the calibration sits in the last 2 KB of the file. From the X4 on (verified on X5 files by GyroView,
// documented by insta360-rs as "indexed records") the record before the tail is a directory, id 0 and format 0, of 10
// byte entries that give the place of every record: the records are padded to 128 KiB boundaries and cannot be walked
// backwards. The trailer may then sit in an MP4 box of type inst, whose 8 byte header the trailer size leaves out.
//
// The field numbers are those of telemetry-parser (MIT/Apache-2.0), checked on X3 files, and of insta360-rs and
// GyroView for the fields of the newer cameras (26, 79, 80, 129, 131), which no file at hand has; see
// docs/16-dual-fisheye-spec.md, sections 1, 2 and 4, and docs/18-design-projections-and-parsers.md, section 5.3.
//
// Pure Dart: the caller reads the bytes, from a file on the device or with HTTP range requests.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/exif_head.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/protobuf_reader.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart' show ByteRangeReader;
import 'package:logging/logging.dart';

final _log = Logger('Insta360Trailer');

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

// The directory of an indexed trailer: the record of id 0 and format 0 right before the tail, entries of 10 bytes (id,
// format, length and offset from the start of the records)
const _directoryEntryLength = 10;
const _maxDirectoryLength = 64 * 1024;

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
    this.groupIdentity,
    this.groupIndex,
    this.fileLayout,
    this.trackOrder,
    this.imageCategory,
    this.streamLayout,
    this.indexed = false,
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

  /// The recording a file belongs to (field 26.3): the two files of a split pair carry the same
  final String? groupIdentity;

  /// Index of the file in its recording (field 26.2)
  final int? groupIndex;

  /// How the camera stored the video (field 79): 0 unknown, 1 one file per lens, 2 one track per lens
  final int? fileLayout;

  /// Which lens the first video track holds (field 80): 0 unknown, 1 the track of stream 10 (lens 1), 2 the one of
  /// stream 00 (lens 0); see [insta360TrackOrder]
  final int? trackOrder;

  /// What the picture is (field 129): 2 a double fisheye, 6 an equirect the camera stitched itself
  final int? imageCategory;

  /// How the lenses are laid out (field 131): 1 one stream, 2 separate files, 3 two tracks, 4 two tracks reversed
  final int? streamLayout;

  /// Whether the records were found through the directory of an indexed trailer (X4 and later) rather than walked
  /// backwards (X3 and older)
  final bool indexed;

  @override
  String toString() =>
      'Insta360Trailer(serial: $serial, cameraModel: $cameraModel, firmware: $firmware, '
      'image: $imageWidth x $imageHeight, crop: $crop, accelerometerRange: $accelerometerRange, '
      'gyroscopeRange: $gyroscopeRange, isRawGyro: $isRawGyro, meanAccelerometer: $meanAccelerometer '
      '($imuSampleCount samples), offsetV1: $offsetV1, offsetV3: $offsetV3, offsetV6: $offsetV6, '
      'group: $groupIdentity #$groupIndex, fileLayout: $fileLayout, trackOrder: $trackOrder, '
      'imageCategory: $imageCategory, streamLayout: $streamLayout, indexed: $indexed)';
}

/// The lens that video track 0 of a two-track Insta360 file holds, and what said so: field 80 of [trailer] (1: lens 1,
/// 2: lens 0), else field 131 (4: lens 1, 3: lens 0), else lens 0. Neither field is checked on a real file yet
/// (GyroView marks them provisional): the source goes to the logs so that the first real X4 or X5 file tells.
({int lensOfTrack0, String source}) insta360TrackOrder(Insta360Trailer? trailer) {
  switch (trailer?.trackOrder) {
    case 1:
      return (lensOfTrack0: 1, source: 'field80');
    case 2:
      return (lensOfTrack0: 0, source: 'field80');
  }
  switch (trailer?.streamLayout) {
    case 4:
      return (lensOfTrack0: 1, source: 'field131');
    case 3:
      return (lensOfTrack0: 0, source: 'field131');
  }
  return (lensOfTrack0: 0, source: 'default');
}

/// Reads the trailer of the Insta360 file of [fileSize] bytes that [read] reads; null for a file without a version 3
/// trailer.
///
/// Reads the end of the file first. An indexed trailer (X4 and later) gives the place of the metadata and the IMU
/// records in its directory; an older one is walked backwards, a footer at a time, as far as these two records only.
/// Reads at most [insta360MaxMetadataLength] bytes of metadata and [maxImuLength] bytes of IMU samples, from the first
/// ones. A damaged record ends the walk, and a damaged directory the reading: the trailer then has what was read before
/// it, nothing at worst. Errors of [read] are not caught.
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

  final lastFooter = fileSize - _tailLength - _footerLength >= payloadStart
      ? await bytes.at(fileSize - _tailLength - _footerLength, _footerLength)
      : null;
  final indexed = lastFooter != null && lastFooter[0] == 0 && lastFooter[1] == 0;
  final records = indexed
      ? await _indexedRecords(bytes, lastFooter, fileSize: fileSize, payloadStart: payloadStart)
      : await _walkedRecords(bytes, fileSize: fileSize, payloadStart: payloadStart);
  final _Records(:metadataRecord, :imuRecord) = records;

  final metadata = _Metadata();
  if (metadataRecord != null &&
      metadataRecord.format == _protobufFormat &&
      metadataRecord.length <= insta360MaxMetadataLength) {
    final payload = indexed
        ? _checkedPayload(
            await bytes.at(metadataRecord.start, metadataRecord.length + _footerLength),
            metadataRecord,
            _metadataRecord,
          )
        : await bytes.at(metadataRecord.start, metadataRecord.length);
    if (payload != null) {
      metadata.decode(payload);
    }
  }

  List<double>? meanAccelerometer;
  var sampleCount = 0;
  if (imuRecord != null) {
    final sampleLength = metadata.isRawGyro ? _rawImuSampleLength : _imuSampleLength;
    final count = math.min(imuRecord.length, math.max(0, maxImuLength)) ~/ sampleLength;
    Uint8List? samples;
    if (count > 0) {
      // The footer of a record found through the directory tells that the directory is right, when it is read anyway
      samples = indexed && imuRecord.length <= maxImuLength
          ? _checkedPayload(await bytes.at(imuRecord.start, imuRecord.length + _footerLength), imuRecord, _imuRecord)
          : await bytes.at(imuRecord.start, count * sampleLength);
    }
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
    groupIdentity: metadata.groupIdentity,
    groupIndex: metadata.groupIndex,
    fileLayout: metadata.fileLayout,
    trackOrder: metadata.trackOrder,
    imageCategory: metadata.imageCategory,
    streamLayout: metadata.streamLayout,
    indexed: indexed,
  );
}

/// The metadata and the IMU records of a trailer, the first of each
typedef _Records = ({_Record? metadataRecord, _Record? imuRecord});

// The records of a sequential trailer, walked backwards from the tail: each footer gives the length of the payload
// before it
Future<_Records> _walkedRecords(_CachedBytes bytes, {required int fileSize, required int payloadStart}) async {
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
  return (metadataRecord: metadataRecord, imuRecord: imuRecord);
}

// The records of an indexed trailer, from its directory, the record whose footer [directoryFooter] ends next to the
// tail. Each entry is the id, the format, the length of the payload and its offset from [payloadStart], all little
// endian, id first unlike a footer; an entry of zeros is padding. An entry that points out of the records is left out,
// and a directory of a length that is no whole number of entries gives no record at all.
Future<_Records> _indexedRecords(
  _CachedBytes bytes,
  Uint8List directoryFooter, {
  required int fileSize,
  required int payloadStart,
}) async {
  const none = (metadataRecord: null, imuRecord: null);
  final length = ByteData.sublistView(directoryFooter).getUint32(2, Endian.little);
  final directoryStart = fileSize - _tailLength - _footerLength - length;
  if (length % _directoryEntryLength != 0 || length > _maxDirectoryLength || directoryStart < payloadStart) {
    _log.warning('Insta360 trailer: an indexed directory of $length bytes that cannot be read');
    return none;
  }
  final directory = await bytes.at(directoryStart, length);
  if (directory == null) {
    return none;
  }
  final data = ByteData.sublistView(directory);
  _Record? metadataRecord;
  _Record? imuRecord;
  for (var entry = 0; entry < length; entry += _directoryEntryLength) {
    if (directory.sublist(entry, entry + _directoryEntryLength).every((byte) => byte == 0)) {
      continue;
    }
    final id = data.getUint8(entry);
    final format = data.getUint8(entry + 1);
    final recordLength = data.getUint32(entry + 2, Endian.little);
    final start = payloadStart + data.getUint32(entry + 6, Endian.little);
    if (start + recordLength + _footerLength > directoryStart) {
      continue;
    }
    if (id == _metadataRecord) {
      metadataRecord ??= (format: format, start: start, length: recordLength);
    } else if (id == _imuRecord) {
      imuRecord ??= (format: format, start: start, length: recordLength);
    }
  }
  return (metadataRecord: metadataRecord, imuRecord: imuRecord);
}

// The payload of the record [id] out of [bytes], its payload and its footer, when the footer agrees with the directory
// entry that gave [record]; null otherwise
Uint8List? _checkedPayload(Uint8List? bytes, _Record record, int id) {
  if (bytes == null) {
    return null;
  }
  final footer = ByteData.sublistView(bytes, record.length);
  if (footer.getUint8(0) != record.format ||
      footer.getUint8(1) != id ||
      footer.getUint32(2, Endian.little) != record.length) {
    _log.warning('Insta360 trailer: the footer of record $id does not match its directory entry');
    return null;
  }
  return Uint8List.sublistView(bytes, 0, record.length);
}

/// The calibration of the file whose trailer is [trailer]: the Mei model of its V3 string, else of its V6 string, else
/// the equidistant model of its V1 string; null when it has none of them. Gravity comes from the mean accelerometer of
/// the trailer, else from [accelerometer] (the sample of the MakerNote of a photo, see [readInsta360PhotoHead]), else
/// the camera is taken as upright.
DualFisheyeCalibration? calibrationOf(Insta360Trailer trailer, {List<double>? accelerometer}) {
  final v3 = trailer.offsetV3;
  final v6 = trailer.offsetV6;
  final v1 = trailer.offsetV1;
  // V3 first (validated against Insta360 Studio on the X3), then V6 with its five radial terms (the only string of the
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
// type, 56 tokens for two lenses (packed >> 16 = 6). The Mei model takes the five radial terms; p3, p4 and the thin
// prism terms s1 to s4 stay unread: GyroView (ADR 0032) measured that every reading of them makes the V6 of an X5 agree
// less with its V3.
const _v6LensTokens = 27;

// Tokens per lens of a V1 string: radius cx cy yaw pitch roll; then the canvas width and height and a packed word, 16
// tokens for two lenses
const _v1LensTokens = 6;

/// The Mei model of the V3 calibration string [offset] of a two lens camera, in canvas pixels and degrees; null when it
/// is not one, its packed word included
DualFisheyeCalibration? parseInsta360OffsetV3(String offset) {
  final tokens = _numbers(offset);
  if (tokens == null || tokens.length != 2 + 2 * _v3LensTokens || tokens[0] != 2 || !_packedVersion(tokens, 3)) {
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

/// The Mei model of the V6 calibration string [offset] of a two lens camera, with its five radial terms (p3, p4 and the
/// thin prism terms are left out), in canvas pixels and degrees; null when it is not one, its packed word included
DualFisheyeCalibration? parseInsta360OffsetV6(String offset) {
  final tokens = _numbers(offset);
  if (tokens == null || tokens.length != 2 + 2 * _v6LensTokens || tokens[0] != 2 || !_packedVersion(tokens, 6)) {
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
      k4: t[14],
      k5: t[15],
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

// Whether the packed word that ends the calibration string [tokens] names [version] in its high 16 bits: a string
// of the right length whose word names another version is another layout, read wrongly token by token
bool _packedVersion(List<double> tokens, int version) {
  final packed = tokens.last;
  if (packed == packed.roundToDouble() && packed >= 0 && packed.toInt() >> 16 == version) {
    return true;
  }
  _log.warning('Insta360 calibration string V$version skipped: its packed word $packed names another version');
  return false;
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
const insta360PhotoHeadLength = exifHeadLength;

/// Reads the EXIF head of the Insta360 photo that [read] reads (see [parseInsta360PhotoHead]): a fallback for leveling
/// when the trailer has no IMU record, and for naming the camera when there is no trailer. Errors of [read] are not
/// caught.
Future<Insta360PhotoHead?> readInsta360PhotoHead(ByteRangeReader read) async =>
    parseInsta360PhotoHead(await read(0, insta360PhotoHeadLength));

/// The camera and the IMU sample of the EXIF of an Insta360 photo whose first bytes are [head] (see [parseExifHead]);
/// null when it has none of them there.
///
/// The camera writes in the MakerNote one IMU sample as ASCII, six underscore separated numbers, accelerometer then
/// gyroscope, padded with zeros: "-1.003906_-0.124023_0.082031_0.024501_0.007457_0.053263". On the X3 that value starts
/// at byte 1211 of the file, right after the ASCII values of IFD0 (Make "Arashi Vision", Model "Insta360 X3", firmware,
/// dates), so the first 4 KB of the file hold it all. The X3 writes no BodySerialNumber.
Insta360PhotoHead? parseInsta360PhotoHead(Uint8List head) {
  final exif = parseExifHead(head);
  if (exif == null) {
    return null;
  }
  final makerNote = exif.makerNote;
  final numbers = makerNote == null ? null : _numbers(makerNote);
  final imu = numbers == null || numbers.length != 6
      ? null
      : Insta360ImuSample(accelerometer: numbers.sublist(0, 3), gyroscope: numbers.sublist(3));
  if (exif.model == null && exif.serial == null && imu == null) {
    return null;
  }
  return Insta360PhotoHead(cameraModel: exif.model, serial: exif.serial, imu: imu);
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
  String? groupIdentity;
  int? groupIndex;
  int? fileLayout;
  int? trackOrder;
  int? imageCategory;
  int? streamLayout;

  /// Reads the protobuf message [bytes]; a damaged message keeps the fields before the damage
  void decode(Uint8List bytes) {
    try {
      for (final field in protoFields(bytes)) {
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
          case 19 when field.wireType == protoLengthDelimited:
            _decodeDimension(field.bytes!);
          case 26 when field.wireType == protoLengthDelimited && groupIdentity == null && groupIndex == null:
            _decodeGroup(field.bytes!);
          case 27 when field.wireType == protoLengthDelimited:
            crop ??= _decodeCrop(field.bytes!);
          case 54:
            offsetV3 ??= field.string;
          case 56:
            offsetV3Copy ??= field.string;
          case 62 when field.wireType == protoVarint:
            isRawGyro = field.integer != 0;
          case 65 when field.wireType == protoLengthDelimited:
            _decodeImuRanges(field.bytes!);
          case 79 when field.wireType == protoVarint:
            fileLayout ??= field.integer;
          case 80 when field.wireType == protoVarint:
            trackOrder ??= field.integer;
          case 111:
            offsetV6 ??= field.string;
          case 112:
            offsetV6Copy ??= field.string;
          case 129 when field.wireType == protoVarint:
            imageCategory ??= field.integer;
          case 131 when field.wireType == protoVarint:
            streamLayout ??= field.integer;
        }
      }
    } on FormatException {
      // The fields read so far stay
    }
  }

  void _decodeDimension(Uint8List bytes) {
    for (final field in protoFields(bytes)) {
      if (field.wireType != protoVarint) {
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

  // The recording a file belongs to: its type (1), the index of the file (2), the identity of the recording (3) and
  // the number of its files (4)
  void _decodeGroup(Uint8List bytes) {
    for (final field in protoFieldsLenient(bytes)) {
      switch (field.number) {
        case 2 when field.wireType == protoVarint:
          groupIndex ??= field.integer;
        case 3 when field.wireType == protoLengthDelimited:
          final identity = field.string?.trim();
          if (identity != null && identity.isNotEmpty) {
            groupIdentity ??= identity;
          }
      }
    }
  }

  Insta360Crop _decodeCrop(Uint8List bytes) {
    final values = List.filled(6, 0);
    for (final field in protoFields(bytes)) {
      if (field.wireType == protoVarint && field.number >= 1 && field.number <= 6) {
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
    for (final field in protoFields(bytes)) {
      switch (field.number) {
        case 1:
          accelerometerRange ??= field.asDouble;
        case 2:
          gyroscopeRange ??= field.asDouble;
      }
    }
  }
}
