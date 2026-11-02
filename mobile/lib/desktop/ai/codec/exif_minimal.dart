// The EXIF of a 3D photo, and what it takes from the EXIF of its original. Minimal on purpose (design-final
// 2026-10-26, section 2.3, point 10): the orientation is always 1, since the pixels are written upright; the date
// taken and its offset, the GPS position and Software are kept; no make, no model and no thumbnail. A 2:1 picture with
// the make of a 360° camera or of a DJI drone would be taken for a sphere by the rules of
// domain/services/raw/raw_360_detection.dart, and a thumbnail of the original would show one eye where the viewers
// expect the pair.
//
// A photo prepared for a splat scene (plan 2026-11-01, lot SP5) gets another minimal EXIF, splatPhotoExif: the
// orientation 1, the make and the model, and its focal length the way COLMAP reads it to start its cameras from
// (Bitmap::ExifFocalLength of COLMAP 4.2.1: FocalLengthIn35mmFilm, else FocalLength with FocalPlaneXResolution, else
// FocalLength with the sensor width of its camera database, found by make and model). The focal plane resolution is in
// pixels of the original: it is scaled with the photo, otherwise COLMAP starts from a focal length several times too
// long (10 221 pixels for the 1 600 pixels of the skull of the measure, about 3 830 in truth).
//
// The reader is a small one of its own rather than the one of the library scan (desktop/library/library_metadata.dart,
// private to the scan) or of package:image (which turns a damaged EXIF into an exception): it reads the few tags it
// needs, checks every offset and gives up on a tag rather than on the file.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';

const _tagMake = 0x010F;
const _tagModel = 0x0110;
const _tagOrientation = 0x0112;
const _tagSoftware = 0x0131;
const _tagExifIfd = 0x8769;
const _tagGpsIfd = 0x8825;
const _tagExifVersion = 0x9000;
const _tagDateTimeOriginal = 0x9003;
const _tagOffsetTimeOriginal = 0x9011;
const _tagFocalLength = 0x920A;
const _tagFocalPlaneXResolution = 0xA20E;
const _tagFocalPlaneYResolution = 0xA20F;
const _tagFocalPlaneResolutionUnit = 0xA210;
const _tagFocalLength35mm = 0xA405;
const _tagGpsVersion = 0x0000;
const _tagGpsLatitudeRef = 0x0001;
const _tagGpsLatitude = 0x0002;
const _tagGpsLongitudeRef = 0x0003;
const _tagGpsLongitude = 0x0004;
const _tagGpsAltitudeRef = 0x0005;
const _tagGpsAltitude = 0x0006;

const _typeByte = 1;
const _typeAscii = 2;
const _typeShort = 3;
const _typeLong = 4;
const _typeRational = 5;
const _typeUndefined = 7;

const _exifHeader = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]; // "Exif\0\0"

/// The APP1 payload of the EXIF of a 3D photo: "Exif\0\0", then little endian TIFF. IFD0 holds the orientation 1,
/// Software and the pointers to the EXIF IFD (version 0232, DateTimeOriginal, OffsetTimeOriginal) and to the GPS IFD
/// (version 2.3, latitude, longitude and altitude with their references). IFD0 points to no IFD1: no thumbnail. An
/// IFD without a field to hold is left out.
Uint8List minimalExif(ImmersiveExif exif) {
  final latitude = exif.latitude;
  final longitude = exif.longitude;
  final hasGps = latitude != null && longitude != null && latitude.isFinite && longitude.isFinite;
  final altitude = exif.altitude;
  final hasExifIfd = exif.dateTimeOriginal != null || exif.offsetTimeOriginal != null;

  final exifEntries = <_Entry>[
    _Entry(_tagExifVersion, _typeUndefined, 4, ascii.encode('0232')),
    if (exif.dateTimeOriginal case final date?) _Entry.ascii(_tagDateTimeOriginal, date),
    if (exif.offsetTimeOriginal case final offset?) _Entry.ascii(_tagOffsetTimeOriginal, offset),
  ];
  final gpsEntries = <_Entry>[
    if (hasGps) ...[
      const _Entry(_tagGpsVersion, _typeByte, 4, [2, 3, 0, 0]),
      _Entry.ascii(_tagGpsLatitudeRef, latitude < 0 ? 'S' : 'N'),
      _Entry.rationals(_tagGpsLatitude, _degreesMinutesSeconds(latitude)),
      _Entry.ascii(_tagGpsLongitudeRef, longitude < 0 ? 'W' : 'E'),
      _Entry.rationals(_tagGpsLongitude, _degreesMinutesSeconds(longitude)),
      if (altitude != null && altitude.isFinite) ...[
        _Entry(_tagGpsAltitudeRef, _typeByte, 1, [if (altitude < 0) 1 else 0]),
        _Entry.rationals(_tagGpsAltitude, [((altitude.abs() * 1000).round(), 1000)]),
      ],
    ],
  ];

  // The sizes never depend on the offsets: lay the IFDs out once at zero to find where each one starts
  List<_Entry> ifd0(int exifAt, int gpsAt) => [
    _Entry.short(_tagOrientation, 1),
    if (exif.software case final software?) _Entry.ascii(_tagSoftware, software),
    if (hasExifIfd) _Entry.long(_tagExifIfd, exifAt),
    if (hasGps) _Entry.long(_tagGpsIfd, gpsAt),
  ];
  final ifd0Size = _ifdSize(ifd0(0, 0));
  final exifAt = 8 + ifd0Size;
  final gpsAt = exifAt + (hasExifIfd ? _ifdSize(exifEntries) : 0);

  final tiff = BytesBuilder(copy: false)
    ..add(const [0x49, 0x49, 0x2A, 0x00]) // "II*\0", little endian
    ..add(_u32(8))
    ..add(_ifd(ifd0(exifAt, gpsAt), 8));
  if (hasExifIfd) {
    tiff.add(_ifd(exifEntries, exifAt));
  }
  if (hasGps) {
    tiff.add(_ifd(gpsEntries, gpsAt));
  }
  return Uint8List.fromList([..._exifHeader, ...tiff.takeBytes()]);
}

/// The EXIF orientation (1 to 8) of [exif], an APP1 payload from "Exif\0\0" on; 1 without one or when it cannot be
/// read
int exifOrientation(Uint8List? exif) {
  final tiff = _Tiff.of(exif);
  final value = tiff?.ifd(tiff.firstIfd)[_tagOrientation];
  final orientation = value == null ? null : tiff!.integer(value);
  return orientation != null && orientation >= 1 && orientation <= 8 ? orientation : 1;
}

/// The focal length equivalent to 35 mm of [exif] (FocalLengthIn35mmFilm of the Exif IFD), in millimetres; null
/// without one, or when it is 0 (unknown) or cannot be read. A 3D scene fixes the focal length of its geometry by it
/// (design-final 2026-10-27, section 2.3, step 3).
int? exifFocalLength35mm(Uint8List? exif) {
  final tiff = _Tiff.of(exif);
  if (tiff == null) {
    return null;
  }
  final ifd0 = tiff.ifd(tiff.firstIfd);
  final exifIfd = ifd0[_tagExifIfd] == null ? const <int, _Value>{} : tiff.ifd(tiff.integer(ifd0[_tagExifIfd]!));
  final value = exifIfd[_tagFocalLength35mm];
  final focal = value == null ? null : tiff.integer(value);
  return focal == null || focal <= 0 ? null : focal;
}

/// The fields of the EXIF of an original that its 3D photo keeps: the date taken and its offset, the GPS position;
/// [software] names the app that wrote the 3D photo. Anything unreadable is left out.
ImmersiveExif keptExif(Uint8List? exif, {String? software}) {
  final tiff = _Tiff.of(exif);
  if (tiff == null) {
    return ImmersiveExif(software: software);
  }
  final ifd0 = tiff.ifd(tiff.firstIfd);
  final exifIfd = ifd0[_tagExifIfd] == null ? const <int, _Value>{} : tiff.ifd(tiff.integer(ifd0[_tagExifIfd]!));
  final gpsIfd = ifd0[_tagGpsIfd] == null ? const <int, _Value>{} : tiff.ifd(tiff.integer(ifd0[_tagGpsIfd]!));

  double? coordinate(int tag, int refTag, String negative) {
    final value = gpsIfd[tag];
    if (value == null) {
      return null;
    }
    final parts = tiff.rationals(value);
    if (parts.isEmpty || parts.any((part) => part == null)) {
      return null;
    }
    var degrees = parts[0]!;
    if (parts.length > 1) {
      degrees += parts[1]! / 60;
    }
    if (parts.length > 2) {
      degrees += parts[2]! / 3600;
    }
    final ref = gpsIfd[refTag] == null ? null : tiff.text(gpsIfd[refTag]!);
    return ref != null && ref.toUpperCase().startsWith(negative) ? -degrees : degrees;
  }

  double? altitude() {
    final value = gpsIfd[_tagGpsAltitude];
    final metres = value == null ? null : tiff.rationals(value).firstOrNull;
    if (metres == null) {
      return null;
    }
    final ref = gpsIfd[_tagGpsAltitudeRef];
    return ref != null && tiff.integer(ref) == 1 ? -metres : metres;
  }

  final latitude = coordinate(_tagGpsLatitude, _tagGpsLatitudeRef, 'S');
  final longitude = coordinate(_tagGpsLongitude, _tagGpsLongitudeRef, 'W');
  final hasPosition = latitude != null && longitude != null;
  return ImmersiveExif(
    dateTimeOriginal: _blankToNull(
      exifIfd[_tagDateTimeOriginal] == null ? null : tiff.text(exifIfd[_tagDateTimeOriginal]!),
    ),
    offsetTimeOriginal: _blankToNull(
      exifIfd[_tagOffsetTimeOriginal] == null ? null : tiff.text(exifIfd[_tagOffsetTimeOriginal]!),
    ),
    latitude: hasPosition ? latitude : null,
    longitude: hasPosition ? longitude : null,
    altitude: hasPosition ? altitude() : null,
    software: software,
  );
}

/// The camera of a photo as its EXIF tells it: what COLMAP reads to start its camera from (see the top of this file).
/// The rationals are kept as written, numerator and denominator.
class CameraExif {
  const CameraExif({
    this.make,
    this.model,
    this.focalLength,
    this.focalLength35mm,
    this.focalPlaneXResolution,
    this.focalPlaneYResolution,
    this.focalPlaneResolutionUnit,
  });

  /// "Canon", "samsung"
  final String? make;

  /// "Canon EOS REBEL T3", "SM-S926B"
  final String? model;

  /// FocalLength, in millimetres
  final (int, int)? focalLength;

  /// FocalLengthIn35mmFilm, in millimetres
  final int? focalLength35mm;

  /// Pixels of the original a unit of [focalPlaneResolutionUnit] of the sensor holds
  final (int, int)? focalPlaneXResolution;
  final (int, int)? focalPlaneYResolution;

  /// 2 inches, 3 centimetres, 4 millimetres, 5 micrometres
  final int? focalPlaneResolutionUnit;

  /// The focal length in millimetres, null without one
  double? get focalLengthMm {
    final focal = focalLength;
    return focal == null || focal.$2 == 0 ? null : focal.$1 / focal.$2;
  }

  /// "Canon EOS REBEL T3 55 mm", "samsung SM-S926B 6.3 mm": the make left out when the model starts with it; null when
  /// the EXIF names no camera
  String? get label {
    final maker = make?.trim() ?? '';
    final camera = model?.trim() ?? '';
    final name = camera.toLowerCase().startsWith(maker.toLowerCase()) ? camera : '$maker $camera'.trim();
    final focal = focalLengthMm;
    final mm = focal == null ? '' : ' ${_millimetres(focal)} mm';
    return name.isEmpty ? (mm.isEmpty ? null : mm.trim()) : '$name$mm';
  }

  /// The same camera with the focal plane resolution of a copy [scale] times the size of the original
  CameraExif scaled(double scale) {
    (int, int)? scaledResolution((int, int)? resolution) => resolution == null || resolution.$2 == 0
        ? null
        : ((resolution.$1 / resolution.$2 * scale * 1000).round(), 1000);
    return CameraExif(
      make: make,
      model: model,
      focalLength: focalLength,
      focalLength35mm: focalLength35mm,
      focalPlaneXResolution: scaledResolution(focalPlaneXResolution),
      focalPlaneYResolution: scaledResolution(focalPlaneYResolution),
      focalPlaneResolutionUnit: focalPlaneResolutionUnit,
    );
  }
}

String _millimetres(double value) {
  final rounded = (value * 10).round() / 10;
  return rounded == rounded.roundToDouble() ? '${rounded.round()}' : '$rounded';
}

/// The camera of [exif], an APP1 payload from "Exif\0\0" on; empty when it has none or cannot be read. A zero focal
/// length or resolution (unknown) is left out.
CameraExif cameraExifOf(Uint8List? exif) {
  final tiff = _Tiff.of(exif);
  if (tiff == null) {
    return const CameraExif();
  }
  final ifd0 = tiff.ifd(tiff.firstIfd);
  final exifIfd = ifd0[_tagExifIfd] == null ? const <int, _Value>{} : tiff.ifd(tiff.integer(ifd0[_tagExifIfd]!));
  (int, int)? rational(int tag) {
    final value = exifIfd[tag];
    final first = value == null ? null : tiff.rawRationals(value).firstOrNull;
    return first == null || first.$1 == 0 || first.$2 == 0 ? null : first;
  }

  int? positive(int tag) {
    final value = exifIfd[tag];
    final number = value == null ? null : tiff.integer(value);
    return number == null || number <= 0 ? null : number;
  }

  return CameraExif(
    make: _blankToNull(ifd0[_tagMake] == null ? null : tiff.text(ifd0[_tagMake]!)),
    model: _blankToNull(ifd0[_tagModel] == null ? null : tiff.text(ifd0[_tagModel]!)),
    focalLength: rational(_tagFocalLength),
    focalLength35mm: positive(_tagFocalLength35mm),
    focalPlaneXResolution: rational(_tagFocalPlaneXResolution),
    focalPlaneYResolution: rational(_tagFocalPlaneYResolution),
    focalPlaneResolutionUnit: positive(_tagFocalPlaneResolutionUnit),
  );
}

/// The APP1 payload of the EXIF of a photo prepared for a splat scene: "Exif\0\0", then little endian TIFF. IFD0
/// holds the orientation 1, [camera]'s make and model and the pointer to the EXIF IFD (version 0232, FocalLength,
/// FocalPlaneXResolution, FocalPlaneYResolution, FocalPlaneResolutionUnit, FocalLengthIn35mmFilm, those it has). No
/// date, no place, no thumbnail: COLMAP needs none of them.
Uint8List splatPhotoExif(CameraExif camera) {
  final exifEntries = <_Entry>[
    _Entry(_tagExifVersion, _typeUndefined, 4, ascii.encode('0232')),
    if (camera.focalLength case final focal?) _Entry.rationals(_tagFocalLength, [focal]),
    if (camera.focalPlaneXResolution case final x?) _Entry.rationals(_tagFocalPlaneXResolution, [x]),
    if (camera.focalPlaneYResolution case final y?) _Entry.rationals(_tagFocalPlaneYResolution, [y]),
    if (camera.focalPlaneResolutionUnit case final unit?) _Entry.short(_tagFocalPlaneResolutionUnit, unit),
    if (camera.focalLength35mm case final focal?) _Entry.short(_tagFocalLength35mm, math.min(focal, 0xFFFF)),
  ];
  List<_Entry> ifd0(int exifAt) => [
    if (camera.make case final make?) _Entry.ascii(_tagMake, make),
    if (camera.model case final model?) _Entry.ascii(_tagModel, model),
    _Entry.short(_tagOrientation, 1),
    _Entry.long(_tagExifIfd, exifAt),
  ];
  final exifAt = 8 + _ifdSize(ifd0(0));
  final tiff = BytesBuilder(copy: false)
    ..add(const [0x49, 0x49, 0x2A, 0x00]) // "II*\0", little endian
    ..add(_u32(8))
    ..add(_ifd(ifd0(exifAt), 8))
    ..add(_ifd(exifEntries, exifAt));
  return Uint8List.fromList([..._exifHeader, ...tiff.takeBytes()]);
}

String? _blankToNull(String? text) => text == null || text.trim().isEmpty ? null : text;

/// Degrees, minutes and seconds of [value] as rationals, the seconds to a ten thousandth
List<(int, int)> _degreesMinutesSeconds(double value) {
  final total = (value.abs() * 3600 * 10000).round();
  final degrees = total ~/ (3600 * 10000);
  final minutes = total % (3600 * 10000) ~/ (60 * 10000);
  final seconds = total % (60 * 10000);
  return [(degrees, 1), (minutes, 1), (seconds, 10000)];
}

class _Entry {
  const _Entry(this.tag, this.type, this.count, this.value);

  _Entry.ascii(int tag, String text) : this(tag, _typeAscii, _asciiOf(text).length, _asciiOf(text));

  _Entry.short(int tag, int value) : this(tag, _typeShort, 1, [value & 0xFF, value >> 8 & 0xFF]);

  _Entry.long(int tag, int value) : this(tag, _typeLong, 1, _u32(value));

  _Entry.rationals(int tag, List<(int, int)> values)
    : this(tag, _typeRational, values.length, [
        for (final (numerator, denominator) in values) ...[..._u32(numerator), ..._u32(denominator)],
      ]);

  final int tag;
  final int type;
  final int count;
  final List<int> value;

  /// Bytes after the IFD for a value that does not fit the four bytes of its entry, kept even
  int get outside => value.length <= 4 ? 0 : value.length + value.length % 2;

  /// The text as EXIF writes it: printable ASCII and a NUL; anything else becomes "?"
  static List<int> _asciiOf(String text) => [
    for (final unit in text.codeUnits) unit >= 0x20 && unit < 0x7F ? unit : 0x3F,
    0,
  ];
}

int _ifdSize(List<_Entry> entries) =>
    2 + 12 * entries.length + 4 + entries.fold(0, (size, entry) => size + entry.outside);

/// An IFD that starts at [at] in the TIFF, its long values right after it, next IFD 0
Uint8List _ifd(List<_Entry> entries, int at) {
  final sorted = [...entries]..sort((a, b) => a.tag.compareTo(b.tag));
  final head = BytesBuilder(copy: false)..add([sorted.length & 0xFF, sorted.length >> 8]);
  final data = BytesBuilder(copy: false);
  var dataAt = at + 2 + 12 * sorted.length + 4;
  for (final entry in sorted) {
    head
      ..add([entry.tag & 0xFF, entry.tag >> 8, entry.type, 0])
      ..add(_u32(entry.count));
    if (entry.value.length <= 4) {
      head.add([...entry.value, ...List.filled(4 - entry.value.length, 0)]);
    } else {
      head.add(_u32(dataAt));
      data.add(entry.value);
      if (entry.value.length.isOdd) {
        data.addByte(0);
      }
      dataAt += entry.outside;
    }
  }
  head.add(_u32(0));
  return Uint8List.fromList([...head.takeBytes(), ...data.takeBytes()]);
}

List<int> _u32(int value) => [value & 0xFF, value >> 8 & 0xFF, value >> 16 & 0xFF, value >> 24 & 0xFF];

/// A value of an IFD entry: its type, count and where its bytes are in the TIFF
class _Value {
  const _Value(this.type, this.count, this.offset);

  final int type;
  final int count;
  final int offset;
}

/// A TIFF structure read with checks on every offset
class _Tiff {
  _Tiff(this.data, this.bigEndian, this.firstIfd);

  /// The TIFF of [exif], an APP1 payload from "Exif\0\0" on; null when it is not one
  static _Tiff? of(Uint8List? exif) {
    if (exif == null || exif.length < 14) {
      return null;
    }
    for (var index = 0; index < _exifHeader.length; index++) {
      if (exif[index] != _exifHeader[index]) {
        return null;
      }
    }
    final data = ByteData.sublistView(exif, _exifHeader.length);
    final order = data.getUint16(0);
    if (order != 0x4949 && order != 0x4D4D) {
      return null;
    }
    final tiff = _Tiff(data, order == 0x4D4D, 0);
    if (tiff._u16(2) != 42) {
      return null;
    }
    return _Tiff(data, tiff.bigEndian, tiff._u32(4));
  }

  final ByteData data;
  final bool bigEndian;
  final int firstIfd;

  Endian get _endian => bigEndian ? Endian.big : Endian.little;

  int _u16(int at) => data.getUint16(at, _endian);
  int _u32(int at) => data.getUint32(at, _endian);

  /// The entries of the IFD at [at] by tag; empty when it runs past the end
  Map<int, _Value> ifd(int at) {
    if (at <= 0 || at + 2 > data.lengthInBytes) {
      return const {};
    }
    final count = _u16(at);
    if (at + 2 + 12 * count > data.lengthInBytes) {
      return const {};
    }
    final entries = <int, _Value>{};
    for (var index = 0; index < count; index++) {
      final entry = at + 2 + 12 * index;
      final type = _u16(entry + 2);
      final valueCount = _u32(entry + 4);
      final size = _typeSize(type) * valueCount;
      final offset = size <= 4 ? entry + 8 : _u32(entry + 8);
      if (size == 0 || offset + size > data.lengthInBytes) {
        continue;
      }
      entries[_u16(entry)] = _Value(type, valueCount, offset);
    }
    return entries;
  }

  int integer(_Value value) => switch (value.type) {
    _typeByte || _typeUndefined => data.getUint8(value.offset),
    _typeShort => _u16(value.offset),
    _typeLong => _u32(value.offset),
    _ => 0,
  };

  String? text(_Value value) {
    if (value.type != _typeAscii) {
      return null;
    }
    final bytes = Uint8List.sublistView(data, value.offset, value.offset + value.count);
    final end = bytes.indexOf(0);
    return latin1.decode(end < 0 ? bytes : Uint8List.sublistView(bytes, 0, end)).trim();
  }

  /// The rationals of [value] as written, numerator and denominator
  List<(int, int)> rawRationals(_Value value) {
    if (value.type != _typeRational) {
      return const [];
    }
    return [
      for (var index = 0; index < value.count; index++)
        (_u32(value.offset + 8 * index), _u32(value.offset + 8 * index + 4)),
    ];
  }

  /// The rationals of [value], null for a zero denominator
  List<double?> rationals(_Value value) {
    if (value.type != _typeRational) {
      return const [];
    }
    return [
      for (var index = 0; index < value.count; index++)
        _u32(value.offset + 8 * index + 4) == 0
            ? null
            : _u32(value.offset + 8 * index) / _u32(value.offset + 8 * index + 4),
    ];
  }

  static int _typeSize(int type) => switch (type) {
    _typeByte || _typeAscii || _typeUndefined || 6 => 1,
    _typeShort || 8 => 2,
    _typeLong || 9 || 11 => 4,
    _typeRational || 10 || 12 => 8,
    _ => 0,
  };
}
