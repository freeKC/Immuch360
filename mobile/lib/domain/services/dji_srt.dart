// The place of a DJI drone video from the .SRT file the drone writes beside it ("Video Subtitles" on in DJI Fly):
// one subtitle block per frame, with the camera settings and the position of the aircraft. The Neo 2 keeps the
// position of its videos nowhere else that the Immich server reads (ExifTool does not decode its timed metadata), so
// the app places such a video on the map through the Immich API after its upload (see VideoLocationService).
//
// Formats met in the files of DJI drones:
//   [latitude: 45.123456] [longitude: 6.123456]     Neo 2, Mini 3 and 4, Air 3, Mavic 3 (decimal degrees)
//   [latitude : 45.123456] [longtitude : 6.123456]   older drones, with that misspelling
//   GPS(6.1234,45.1234,15)                          Phantom and Mavic Pro, longitude first on some models and
//                                                   latitude first on others: taken only when one value is beyond 90
// Blocks are separated by blank lines; the coordinates may sit inside <font> tags. The first fix that is not 0,0 is the
// position of the aircraft when the recording started, which is what the asset gets.
//
// Pure Dart: the caller reads the bytes, from a share or from a drone plugged into the phone.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:logging/logging.dart';

final _log = Logger('DjiSrt');

/// A position of the aircraft in an .SRT file: decimal degrees, and the local date and time of the block when it has
/// one (the drone writes the time of its clock, without a time zone)
typedef DjiSrtFix = ({double latitude, double longitude, DateTime? localTime});

const _number = r'([-+]?\d+(?:\.\d+)?)';
final _latitude = RegExp('latitude\\s*:\\s*$_number', caseSensitive: false);
final _longitude = RegExp('longt?itude\\s*:\\s*$_number', caseSensitive: false);
final _legacyGps = RegExp('GPS\\s*\\(\\s*$_number\\s*,\\s*$_number', caseSensitive: false);
final _tag = RegExp(r'<[^>]*>');
final _blankLine = RegExp(r'\n[ \t]*\n');
// 2026-05-27 13:14:22.911, or 2021-03-04 10:11:12,345,678 on older drones
final _localTime = RegExp(r'(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:[.,](\d{1,3}))?');

/// Smallest change of a coordinate that is not 0: an aircraft without a fix writes 0,0
const _zero = 1e-6;

/// The first position in [text], the text of an .SRT file of a DJI drone (see the formats above), that is a real fix:
/// within range and not 0,0. Null when it has none (no GPS fix during the flight, indoors, Video Subtitles written
/// without a position). When [complete] is false, [text] is the head of a longer file: its last block may be cut, and
/// is left out.
DjiSrtFix? parseDjiSrtFix(String text, {bool complete = true}) {
  var normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (normalized.startsWith('\uFEFF')) {
    normalized = normalized.substring(1);
  }
  var blocks = normalized.split(_blankLine);
  if (!complete && blocks.isNotEmpty) {
    blocks = blocks.sublist(0, blocks.length - 1);
  }
  var ambiguous = 0;
  for (final block in blocks) {
    final plain = block.replaceAll(_tag, ' ');
    final latitude = _latitude.firstMatch(plain);
    final longitude = _longitude.firstMatch(plain);
    double? lat;
    double? lon;
    if (latitude != null && longitude != null) {
      lat = double.tryParse(latitude.group(1)!);
      lon = double.tryParse(longitude.group(1)!);
    } else {
      final gps = _legacyGps.firstMatch(plain);
      if (gps != null) {
        final first = double.tryParse(gps.group(1)!);
        final second = double.tryParse(gps.group(2)!);
        if (first != null && second != null && !_isZero(first, second)) {
          // Only a value beyond 90 tells which one is the longitude
          if (first.abs() > 90 && second.abs() <= 90) {
            (lat, lon) = (second, first);
          } else if (second.abs() > 90 && first.abs() <= 90) {
            (lat, lon) = (first, second);
          } else {
            ambiguous++;
          }
        }
      }
    }
    if (lat == null || lon == null || _isZero(lat, lon) || lat.abs() > 90 || lon.abs() > 180) {
      continue;
    }
    return (latitude: lat, longitude: lon, localTime: _parseLocalTime(plain));
  }
  if (ambiguous > 0) {
    _log.info('$ambiguous GPS(a, b) positions with no value beyond 90: the order of latitude and longitude is unknown');
  }
  return null;
}

bool _isZero(double a, double b) => a.abs() < _zero && b.abs() < _zero;

DateTime? _parseLocalTime(String block) {
  final match = _localTime.firstMatch(block);
  if (match == null) {
    return null;
  }
  int part(int group) => int.parse(match.group(group)!);
  final millis = match.group(7);
  final time = DateTime(
    part(1),
    part(2),
    part(3),
    part(4),
    part(5),
    part(6),
    millis == null ? 0 : int.parse(millis.padRight(3, '0')),
  );
  // A date the clock of the drone made up (never set) is no date
  return time.year < 2010 ? null : time;
}

/// Bytes of the first read of [readDjiSrtFix]: a few hundred blocks, enough when the aircraft had its fix at the start
const djiSrtFirstWindow = 64 * 1024;

/// Bytes read at each step after the first one
const djiSrtWindowStep = 256 * 1024;

/// The first fix of the .SRT file of [length] bytes that [read] reads (see [parseDjiSrtFix]): its head first, then
/// more of it in steps until a fix is found or the file ends, so that the file of a ten minute flight (a few MB) is
/// rarely read whole. Errors of [read] are not caught.
Future<DjiSrtFix?> readDjiSrtFix(ByteRangeReader read, int length) async {
  final bytes = BytesBuilder(copy: false);
  var offset = 0;
  var window = djiSrtFirstWindow;
  while (offset < length) {
    final chunk = await read(offset, math.min(window, length - offset));
    if (chunk.isEmpty) {
      break;
    }
    bytes.add(chunk);
    offset += chunk.length;
    final complete = offset >= length;
    // A character cut at the end of the window only touches the last block, which is left out until complete
    final fix = parseDjiSrtFix(utf8.decode(bytes.toBytes(), allowMalformed: true), complete: complete);
    if (fix != null) {
      return fix;
    }
    window = djiSrtWindowStep;
  }
  return null;
}

final _srtName = RegExp(r'\.srt$', caseSensitive: false);

/// The name of the .SRT file of the video named [videoName] among [names] (the files of its folder): the same name
/// with .SRT instead of its extension, case aside ("DJI_20260621125142_0017_D.MP4" and
/// "DJI_20260621125142_0017_D.SRT"). Null when there is none.
String? djiSrtNameFor(String videoName, Iterable<String> names) {
  final dot = videoName.lastIndexOf('.');
  final stem = (dot < 0 ? videoName : videoName.substring(0, dot)).toLowerCase();
  for (final name in names) {
    if (_srtName.hasMatch(name) && name.substring(0, name.length - 4).toLowerCase() == stem) {
      return name;
    }
  }
  return null;
}
