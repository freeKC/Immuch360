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

import 'package:flutter/foundation.dart' show visibleForTesting;
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
  return DjiSrtScanner().addText(text, isLast: complete);
}

/// The blocks of an .SRT file as its text comes, in pieces (see [readDjiSrtFix]): each block is parsed once, when the
/// blank line after it has come, so that reading a long file without a fix costs its length, not the square of it.
/// Only the text after the last complete block is kept between two pieces.
class DjiSrtScanner {
  /// The text kept between two pieces when no blank line came for this long: a file that is not made of blocks is
  /// then taken line by line, so that its text is not scanned again at each piece
  static const maxCarry = 64 * 1024;

  final _decoded = StringBuffer();
  late final _decoder = const Utf8Decoder(
    allowMalformed: true,
  ).startChunkedConversion(StringConversionSink.fromStringSink(_decoded));

  /// The text after the last complete block, line ends already made \n
  String _carry = '';
  bool _started = false;
  bool _finished = false;
  int _ambiguous = 0;

  /// The blocks parsed so far, for the tests that bound the work
  @visibleForTesting
  int blocksParsed = 0;

  /// Adds the next [bytes] of the file, UTF-8 (a character cut between two pieces is put back together); gives the
  /// first fix of the blocks complete so far, null when none. [isLast] tells that the file ends there.
  DjiSrtFix? addBytes(List<int> bytes, {bool isLast = false}) {
    _decoder.add(bytes);
    if (isLast) {
      _decoder.close();
    }
    final text = _decoded.toString();
    _decoded.clear();
    return addText(text, isLast: isLast);
  }

  /// Adds the next [text] of the file, see [addBytes]
  DjiSrtFix? addText(String text, {bool isLast = false}) {
    if (_finished) {
      return null;
    }
    var piece = text;
    if (!_started && piece.isNotEmpty) {
      _started = true;
      if (piece.startsWith('\uFEFF')) {
        piece = piece.substring(1);
      }
    }
    var normalized = '$_carry$piece';
    // A \r at the end of a piece may be the first half of a \r\n: kept raw until the next piece
    var heldReturn = false;
    if (!isLast && normalized.endsWith('\r')) {
      normalized = normalized.substring(0, normalized.length - 1);
      heldReturn = true;
    }
    normalized = normalized.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    var start = 0;
    for (final blankLine in _blankLine.allMatches(normalized)) {
      final fix = _parseBlock(normalized.substring(start, blankLine.start));
      start = blankLine.end;
      if (fix != null) {
        return _found(fix);
      }
    }
    var carry = normalized.substring(start);
    if (carry.length > maxCarry) {
      final newline = carry.lastIndexOf('\n');
      if (newline > 0) {
        final fix = _parseBlock(carry.substring(0, newline));
        carry = carry.substring(newline + 1);
        if (fix != null) {
          return _found(fix);
        }
      }
    }
    _carry = heldReturn ? '$carry\r' : carry;
    if (isLast) {
      return finish();
    }
    return null;
  }

  /// The file ended: its last block, cut or not, is parsed too. Null when no block held a fix.
  DjiSrtFix? finish() {
    if (_finished) {
      return null;
    }
    _finished = true;
    final last = _carry.replaceAll('\r', '\n');
    _carry = '';
    final fix = last.trim().isEmpty ? null : _parseBlock(last);
    if (fix == null && _ambiguous > 0) {
      _log.info(
        '$_ambiguous GPS(a, b) positions with no value beyond 90: the order of latitude and longitude is unknown',
      );
    }
    return fix;
  }

  DjiSrtFix _found(DjiSrtFix fix) {
    _finished = true;
    _carry = '';
    return fix;
  }

  /// The fix of one block, null when it holds none
  DjiSrtFix? _parseBlock(String block) {
    blocksParsed++;
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
            _ambiguous++;
          }
        }
      }
    }
    if (lat == null || lon == null || _isZero(lat, lon) || lat.abs() > 90 || lon.abs() > 180) {
      return null;
    }
    return (latitude: lat, longitude: lon, localTime: _parseLocalTime(plain));
  }
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
Future<DjiSrtFix?> readDjiSrtFix(ByteRangeReader read, int length, {@visibleForTesting DjiSrtScanner? scanner}) async {
  scanner ??= DjiSrtScanner();
  var offset = 0;
  var window = djiSrtFirstWindow;
  while (offset < length) {
    final chunk = await read(offset, math.min(window, length - offset));
    if (chunk.isEmpty) {
      break;
    }
    offset += chunk.length;
    // Each block is parsed once, as soon as the blank line after it came (see DjiSrtScanner)
    final fix = scanner.addBytes(chunk, isLast: offset >= length);
    if (fix != null) {
      return fix;
    }
    window = djiSrtWindowStep;
  }
  return scanner.finish();
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
