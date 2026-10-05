// The calibration of the DJI Osmo 360 in its raw .osv videos. The file is an MP4 (ftyp, free, mdat, moov: two square
// HEVC video tracks, one per lens, the sound, and the djmd and dbgi metadata tracks) followed by a top level camd box,
// itself a complete MP4 whose mdat is a flat run of length delimited protobuf fields: 1 a header, 2 a config, 3 a
// record per frame, the first header and config being those of the first djmd track. The config holds the calibration
// of the lenses in its field 6, one message per slot (2-6-n): slots 1 and 2 are the lenses of video streams 0 (rear)
// and 1 (front), 3 to 10 are zero filled, 11 to 24 hold other recording modes. Each slot is a DewarpParams of the
// Kannala-Brandt fisheye model with five radial terms, the pose of the lens in yaw, pitch and roll, and its rotation as
// a quaternion.
//
// Verified on a real Osmo 360 file (CAM_20250715191201_0003_D.OSV, firmware 10.00.05.06) and documented by OSVplat
// (docs/osmo360-telemetry.md, scripts/osv_meta.py, MIT) on another unit and firmware; the field names come from
// telemetry-parser's dvtm_library.proto as osv_meta.py quotes it. See docs/18-design-projections-and-parsers.md,
// sections 4.1 and 5.6.
//
// Pure Dart: the caller reads the bytes, from a file on the device or with HTTP range requests.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/protobuf_reader.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:logging/logging.dart';

final _log = Logger('DjiOsv');

/// The schema the header of the Osmo 360 names; another one is read the same way, and logged
const djiOsvSchema = 'dvtm_oq101.proto';

/// Most bytes of the mdat of the camd box read: the first header and config come first (166 and 5,520 bytes on the
/// sample), the per frame records after them
const djiMaxCamdPayloadLength = 256 * 1024;

/// A lens is read up to this angle off its axis, in degrees, and the two lenses blend between [djiBlendStart] and
/// [djiBlendEnd]: the image circle of the Osmo 360 ends a little past 94 degrees, and its lenses overlap less than
/// those of an Insta360
const djiMaxTheta = 94.0;
const djiBlendStart = 87.0;
const djiBlendEnd = 93.0;

// Bound on the child boxes of camd walked
const _maxCamdChildren = 16;

// Bytes read at once from the start of the content of camd: its small boxes before mdat (ftyp and free, 36 bytes on
// the sample) and the header of mdat
const _camdHeadLength = 4 * 1024;

// A quaternion is taken as a rotation when its norm is within this of 1
const _quaternionNormTolerance = 1e-3;

/// What the camd box of an Osmo 360 file says
class DjiOsvCalibration {
  const DjiOsvCalibration({this.model, this.serial, this.firmware, this.schema, required this.calibration});

  /// Name of the camera (header 1-1-10), "Osmo 360"
  final String? model;

  /// Serial number of the camera (1-1-5)
  final String? serial;

  /// Firmware version (1-1-6), "10.00.05.06"
  final String? firmware;

  /// Name of the protobuf schema of the records (1-1-1), "dvtm_oq101.proto"
  final String? schema;

  /// The Kannala-Brandt calibration of the two lenses, lens 0 the rear one (video stream 0), lens 1 the front one
  /// (stream 1); its source is the file
  final DualFisheyeCalibration calibration;

  @override
  String toString() => 'DjiOsvCalibration(model: $model, serial: $serial, firmware: $firmware, schema: $schema)';
}

/// Reads the calibration of the DJI .osv file that [read] reads: a few header reads to reach the camd box after moov,
/// then at most 256 KiB of its mdat; null when the file has no camd box or no usable calibration in it. Errors of
/// [read] are not caught.
Future<DjiOsvCalibration?> readDjiOsvCalibration(ByteRangeReader read) async {
  final boxes = await listTopLevelBoxes(read);
  final camd = boxes.lastWhereOrNull((box) => box.type == 'camd');
  if (camd == null) {
    return null;
  }
  final contentStart = camd.offset + camd.headerLength;
  final size = camd.size;
  final payload = await _mdatPayload(read, contentStart, size == null ? null : camd.offset + size);
  if (payload == null || payload.isEmpty) {
    _log.info('Osmo 360 file: its camd box has no media data');
    return null;
  }
  return parseDjiCamdRecords(payload);
}

/// The calibration in [records], the start of the mdat of a camd box (a run of protobuf fields: 1 header, 2 config, 3
/// frame record), as [readDjiOsvCalibration] reads it; null without a config that holds a usable calibration
DjiOsvCalibration? parseDjiCamdRecords(Uint8List records) {
  Uint8List? header;
  List<_DjiLens>? lenses;
  for (final field in protoFieldsLenient(records)) {
    if (field.wireType != protoLengthDelimited) {
      continue;
    }
    if (field.number == 1) {
      header ??= field.bytes;
    } else if (field.number == 2 && lenses == null) {
      lenses = _calibrationLenses(field.bytes!);
    }
    if (header != null && lenses != null) {
      break;
    }
  }

  final info = header == null ? null : protoPath(header, [1]);
  String? text(int number) {
    if (info == null) {
      return null;
    }
    for (final field in protoFieldsLenient(info)) {
      if (field.number == number && field.wireType == protoLengthDelimited) {
        final value = field.string?.trim();
        return value == null || value.isEmpty ? null : value;
      }
    }
    return null;
  }

  final schema = text(1);
  final serial = text(5);
  final firmware = text(6);
  final model = text(10);
  if (schema != null && schema != djiOsvSchema) {
    _log.info('Osmo 360 file: records of schema $schema, read as $djiOsvSchema');
  }
  if (lenses == null) {
    _log.info('Osmo 360 file: no config with a calibration in its camd box');
    return null;
  }
  final calibration = _calibration(lenses, serial: serial, cameraModel: model);
  if (calibration == null) {
    return null;
  }
  return DjiOsvCalibration(model: model, serial: serial, firmware: firmware, schema: schema, calibration: calibration);
}

/// Mean values of the four lenses of two real Osmo 360 units, for a file without a readable camd box: the seams may be
/// off by a few pixels. Lens 0 faces backwards, lens 1 forwards, the camera taken as upright.
DualFisheyeCalibration nominalOsmo360() {
  const side = 3840.0;
  DualFisheyeLens lens(int index) => DualFisheyeLens(
    cx: 1912.9 + index * side,
    cy: 1918.4,
    yaw: index == 0 ? 180 : 0,
    pitch: 90,
    roll: 0,
    fx: 1047.3,
    fy: 1047.3,
    k1: 0.06586,
    k2: -0.01104,
    k3: 0.009376,
    k4: -0.006463,
    k5: 0.0009427,
    // M(180, 90, 0) and M(0, 90, 0) times the view to world rotation
    viewToLens: index == 0 ? const [-1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, -1.0] : Mat3.identity.values,
  );
  return DualFisheyeCalibration(
    model: DualFisheyeModel.kannalaBrandt,
    lenses: [lens(0), lens(1)],
    canvasSquare: side,
    cameraModel: 'Osmo 360',
    source: DualFisheyeSource.nominal,
    maxTheta: djiMaxTheta,
    blendStart: djiBlendStart,
    blendEnd: djiBlendEnd,
  );
}

// The payload of the mdat box among the children of the camd box whose content runs from [start] to [end] (to the end
// of the file when null), at most [djiMaxCamdPayloadLength] bytes of it
Future<Uint8List?> _mdatPayload(ByteRangeReader read, int start, int? end) async {
  final head = await read(start, end == null ? _camdHeadLength : math.min(_camdHeadLength, end - start));
  var offset = 0;
  for (var count = 0; count < _maxCamdChildren; count++) {
    // The headers past the first bytes read cost a read each
    final header = offset + 16 <= head.length ? Uint8List.sublistView(head, offset, offset + 16) : null;
    final bytes = header ?? await read(start + offset, 16);
    if (bytes.length < 8 || (end != null && start + offset + 8 > end)) {
      return null;
    }
    final data = ByteData.sublistView(bytes);
    var size = data.getUint32(0);
    final type = String.fromCharCodes(bytes, 4, 8);
    var headerLength = 8;
    if (size == 1) {
      if (bytes.length < 16) {
        return null;
      }
      size = data.getUint32(8) * 0x100000000 + data.getUint32(12);
      headerLength = 16;
    }
    final available = end == null ? null : end - start - offset;
    if (size == 0) {
      // Runs to the end of camd
      if (available == null) {
        size = djiMaxCamdPayloadLength + headerLength;
      } else {
        size = available;
      }
    }
    if (size < headerLength || (available != null && size > available)) {
      return null;
    }
    if (type == 'mdat') {
      final payloadStart = offset + headerLength;
      final length = math.min(size - headerLength, djiMaxCamdPayloadLength);
      if (payloadStart + length <= head.length) {
        return Uint8List.sublistView(head, payloadStart, payloadStart + length);
      }
      return read(start + payloadStart, length);
    }
    offset += size;
  }
  return null;
}

/// One populated slot of the calibration: a DewarpParams
class _DjiLens {
  const _DjiLens(this.values, this.quaternion);

  /// Sub-fields 1 to 19 by number: fx, fy, cx, cy, k1 to k4, xi, width, height, yaw, pitch, roll, k5, k6 to k9
  final Map<int, double> values;

  /// Sub-field 28, cam_extri_q: w, x, y, z
  final List<double>? quaternion;

  double? operator [](int number) => values[number];
}

// The two first populated slots of the calibration of [config]: those of field 6, else of the first other length
// delimited field that has two (the Avata 360 keeps its calibration in field 5, as osv_meta.py reads it). Null without.
List<_DjiLens>? _calibrationLenses(Uint8List config) {
  final fields = protoFieldsLenient(config);
  for (final field in fields) {
    if (field.number == 6 && field.wireType == protoLengthDelimited) {
      final lenses = _populatedSlots(field.bytes!);
      if (lenses != null) {
        return lenses;
      }
      break;
    }
  }
  for (final field in fields) {
    if (field.number != 6 && field.wireType == protoLengthDelimited) {
      final lenses = _populatedSlots(field.bytes!);
      if (lenses != null) {
        return lenses;
      }
    }
  }
  return null;
}

// The first two slots of the calibration message [calibration] whose sub-fields 1 to 8 are all floats and whose fx is
// positive, in their order; null when there are fewer
List<_DjiLens>? _populatedSlots(Uint8List calibration) {
  final lenses = <_DjiLens>[];
  for (final slot in protoFieldsLenient(calibration)) {
    if (slot.wireType != protoLengthDelimited) {
      continue;
    }
    final lens = _slot(slot.bytes!);
    if (lens != null) {
      lenses.add(lens);
      if (lenses.length == 2) {
        return lenses;
      }
    }
  }
  return null;
}

// The DewarpParams of a slot, null when it is not populated
_DjiLens? _slot(Uint8List bytes) {
  final values = <int, double>{};
  final floats = <int>{};
  List<double>? quaternion;
  final tangential = <double>[];
  for (final field in protoFieldsLenient(bytes)) {
    final number = field.number;
    if (number == 28 && field.wireType == protoLengthDelimited) {
      quaternion ??= _quaternion(field.bytes!);
    } else if (number == 20 && field.wireType == protoLengthDelimited && tangential.isEmpty) {
      tangential.addAll(protoPackedFloats(field.bytes!));
    } else if (number >= 1 && number <= 19 && !values.containsKey(number)) {
      final value = field.asDouble;
      if (value != null && value.isFinite) {
        values[number] = value;
        if (field.wireType == protoFixed32) {
          floats.add(number);
        }
      }
    }
  }
  for (var number = 1; number <= 8; number++) {
    if (!floats.contains(number)) {
      return null;
    }
  }
  if (!(values[1]! > 0)) {
    return null;
  }
  final higher = [for (var number = 16; number <= 19; number++) values[number] ?? 0];
  if (higher.any((k) => k != 0)) {
    _log.info('Osmo 360 calibration: radial terms k6 to k9 $higher left out');
  }
  if (tangential.any((p) => p != 0)) {
    _log.fine('Osmo 360 calibration: tangential terms $tangential left out (about a pixel at the rim)');
  }
  return _DjiLens(values, quaternion);
}

// cam_extri_q: w (1), x (2), y (3), z (4), floats; null unless all four are there
List<double>? _quaternion(Uint8List bytes) {
  final values = <int, double>{};
  for (final field in protoFieldsLenient(bytes)) {
    final value = field.float32;
    if (field.number >= 1 && field.number <= 4 && value != null && value.isFinite) {
      values.putIfAbsent(field.number, () => value);
    }
  }
  return values.length == 4 ? [values[1]!, values[2]!, values[3]!, values[4]!] : null;
}

// The rotation of a quaternion [q] (w, x, y, z) when its norm is within the tolerance of 1
Mat3? _rotation(List<double>? q) {
  if (q == null) {
    return null;
  }
  final norm = math.sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
  if ((norm - 1).abs() > _quaternionNormTolerance) {
    return null;
  }
  return quaternionMatrix(q[0], q[1], q[2], q[3]);
}

// The calibration of the two slots [lenses]: the canvas is one square of the slot width per lens, lens 1 to the right
// of lens 0. Lens 0 is placed by its yaw, pitch and roll; lens 1 relative to it by their two quaternions (Q1 Q0^T),
// which agree with the yaw, pitch and roll reading within 0.3 to 1.5 degrees on two units and give continuous seams
// on the real sample where that reading does not, else by its own yaw, pitch and roll. Null without a square slot or a
// pose.
DualFisheyeCalibration? _calibration(List<_DjiLens> lenses, {String? serial, String? cameraModel}) {
  final [lens0, lens1] = lenses;
  final width = lens0[10];
  final height = lens0[11];
  if (width == null || height == null || width <= 0 || width != height) {
    _log.warning('Osmo 360 calibration: a lens square of $width x $height');
    return null;
  }
  if ((lens1[10] != null && lens1[10] != width) || (lens1[11] != null && lens1[11] != height)) {
    _log.warning('Osmo 360 calibration: lenses of ${lens0[10]} and ${lens1[10]} pixels');
    return null;
  }
  Mat3? pose(_DjiLens lens) {
    final yaw = lens[12];
    final pitch = lens[13];
    final roll = lens[14];
    return yaw == null || pitch == null || roll == null ? null : djiLensRotation(yaw, pitch, roll) * djiViewToWorld;
  }

  final viewToLens0 = pose(lens0);
  if (viewToLens0 == null) {
    _log.warning('Osmo 360 calibration: lens 0 has no yaw, pitch and roll');
    return null;
  }
  final q0 = _rotation(lens0.quaternion);
  final q1 = _rotation(lens1.quaternion);
  final viewToLens1 = q0 != null && q1 != null ? q1 * q0.transposed * viewToLens0 : pose(lens1);
  if (viewToLens1 == null) {
    _log.warning('Osmo 360 calibration: lens 1 has neither quaternions nor yaw, pitch and roll');
    return null;
  }
  if (q0 == null || q1 == null) {
    _log.info('Osmo 360 calibration: lens 1 placed by its yaw, pitch and roll, without quaternions');
  }
  DualFisheyeLens lens(_DjiLens slot, int index, Mat3 viewToLens) => DualFisheyeLens(
    cx: slot[3]! + index * width,
    cy: slot[4]!,
    yaw: slot[12] ?? 0,
    pitch: slot[13] ?? 0,
    roll: slot[14] ?? 0,
    fx: slot[1],
    fy: slot[2],
    k1: slot[5]!,
    k2: slot[6]!,
    k3: slot[7]!,
    k4: slot[8]!,
    k5: slot[15] ?? 0,
    viewToLens: viewToLens.values,
  );
  return DualFisheyeCalibration(
    model: DualFisheyeModel.kannalaBrandt,
    lenses: [lens(lens0, 0, viewToLens0), lens(lens1, 1, viewToLens1)],
    canvasSquare: width,
    serial: serial,
    cameraModel: cameraModel,
    source: DualFisheyeSource.file,
    maxTheta: djiMaxTheta,
    blendStart: djiBlendStart,
    blendEnd: djiBlendEnd,
  );
}
