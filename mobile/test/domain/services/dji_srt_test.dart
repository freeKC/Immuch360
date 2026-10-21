import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/dji_srt.dart';

// Synthetic .SRT texts in the formats of DJI drones, at invented positions

/// Neo 2 style blocks, one per frame: [fixes] positions in order
String _neo2(List<(double, double)> fixes, {String newline = '\n'}) {
  final blocks = <String>[];
  for (final (index, (lat, lon)) in fixes.indexed) {
    blocks.add(
      [
        '${index + 1}',
        '00:00:00,${(index * 33).toString().padLeft(3, '0')} --> 00:00:00,${((index + 1) * 33).toString().padLeft(3, '0')}',
        '<font size="28">FrameCnt: ${index + 1}, DiffTime: 33ms',
        '2026-10-21 14:31:0${index % 10}.${(index * 33 % 1000).toString().padLeft(3, '0')}',
        '[iso: 100] [shutter: 1/1000.0] [fnum: 1.8] [ev: 0] [color_md: default] [focal_len: 24.00] '
            '[latitude: ${lat.toStringAsFixed(6)}] [longitude: ${lon.toStringAsFixed(6)}] '
            '[rel_alt: 12.300 abs_alt: 512.700] [ct: 5300] </font>',
      ].join(newline),
    );
  }
  return '${blocks.join('$newline$newline')}$newline';
}

ByteRangeReaderCounted _reader(Uint8List bytes) => ByteRangeReaderCounted(bytes);

class ByteRangeReaderCounted {
  ByteRangeReaderCounted(this.bytes);

  final Uint8List bytes;
  final reads = <(int, int)>[];

  Future<Uint8List> read(int offset, int length) async {
    reads.add((offset, length));
    final start = math.min(offset, bytes.length);
    return Uint8List.sublistView(bytes, start, math.min(bytes.length, start + length));
  }
}

void main() {
  group('parseDjiSrtFix', () {
    test('reads the Neo 2 bracket format, with the local time of the block', () {
      final fix = parseDjiSrtFix(_neo2([(45.123456, 6.654321), (45.123457, 6.654322)]));

      expect(fix?.latitude, 45.123456);
      expect(fix?.longitude, 6.654321);
      expect(fix?.localTime, DateTime(2026, 10, 21, 14, 31, 0));
    });

    test('reads the Mini 4 Pro format and the older misspelt one, spaces around the colon', () {
      const mini4 =
          '1\n00:00:00,000 --> 00:00:00,016\n<font size="28">SrtCnt : 1, DiffTime : 16ms\n'
          '2025-04-02 18:20:31.100\n[iso : 100] [shutter : 1/2000.0] [fnum : 1.7] [ev : 0] [ct : 5600] '
          '[color_md : default] [focal_len : 24.00] [latitude: -33.456789] [longitude: 151.234567] '
          '[rel_alt: 50.000 abs_alt: 80.000] </font>\n';
      const old =
          '1\n00:00:00,000 --> 00:00:01,000\n<font size="36">FrameCnt : 1, DiffTime : 1000ms\n'
          '2021-03-04 10:11:12,345,678\n[iso : 100] [shutter : 1/500.0] [fnum : 280] [ev : 0] [ct : 5600] '
          '[color_md : default] [focal_len : 240] [latitude : 47.111111] [longtitude : 8.222222] '
          '[altitude: 412.100000] </font>\n';

      expect(parseDjiSrtFix(mini4), (
        latitude: -33.456789,
        longitude: 151.234567,
        localTime: DateTime(2025, 4, 2, 18, 20, 31, 100),
      ));
      final older = parseDjiSrtFix(old);
      expect((older?.latitude, older?.longitude), (47.111111, 8.222222));
      expect(older?.localTime, DateTime(2021, 3, 4, 10, 11, 12, 345));
    });

    test('skips the blocks written before the fix, at 0,0', () {
      final fix = parseDjiSrtFix(_neo2([(0, 0), (0, 0), (0, 0), (44.5, 5.25), (44.6, 5.3)]));

      expect((fix?.latitude, fix?.longitude), (44.5, 5.25));
    });

    test('takes the legacy GPS(a, b, c) only when one value beyond 90 tells the order', () {
      String legacy(String gps) =>
          '1\n00:00:00,000 --> 00:00:01,000\nHOME(0,0) 2017.08.05 14:11:51\n$gps BAROMETER:1.9\n';

      final longitudeFirst = parseDjiSrtFix(legacy('GPS(-122.42, 37.77, 15)'));
      final latitudeFirst = parseDjiSrtFix(legacy('GPS(39.9,116.4,69.8)'));

      expect((longitudeFirst?.latitude, longitudeFirst?.longitude), (37.77, -122.42));
      expect((latitudeFirst?.latitude, latitudeFirst?.longitude), (39.9, 116.4));
      expect(parseDjiSrtFix(legacy('GPS(45.1, 6.2, 12)')), isNull, reason: 'both below 90');
      expect(parseDjiSrtFix(legacy('GPS(-3.72, 40.43, 17)')), isNull, reason: 'both below 90');
      expect(parseDjiSrtFix(legacy('GPS (0.0, 0.0, 0)')), isNull, reason: 'no fix');
    });

    test('reads a file with a byte order mark and CRLF line ends', () {
      final fix = parseDjiSrtFix('\uFEFF${_neo2([(0, 0), (43.7, 7.25)], newline: '\r\n')}');

      expect((fix?.latitude, fix?.longitude), (43.7, 7.25));
    });

    test('leaves out a cut last block until the file is complete', () {
      final text = _neo2([(0, 0), (43.7, 7.25)]);
      final cut = text.substring(0, text.indexOf('[longitude') + 15);

      expect(parseDjiSrtFix(cut, complete: false), isNull);
      expect(parseDjiSrtFix(text, complete: false), isNull, reason: 'no blank line after it yet: it may go on');
      expect(parseDjiSrtFix('$text\n', complete: false), isNotNull);
    });

    test('a flight without a position gives null, as a file of something else', () {
      expect(parseDjiSrtFix(_neo2([(0, 0), (0, 0)])), isNull);
      expect(parseDjiSrtFix('1\n00:00:00,000 --> 00:00:01,000\nHello\n'), isNull);
      expect(parseDjiSrtFix(''), isNull);
      // Out of range
      expect(parseDjiSrtFix(_neo2([(95, 6), (45, 200)])), isNull);
    });
  });

  group('readDjiSrtFix', () {
    test('reads the head only when the fix is at the start', () async {
      final bytes = Uint8List.fromList(utf8.encode(_neo2([for (var i = 0; i < 2000; i++) (45.0 + i / 1e5, 6.0)])));
      expect(bytes.length, greaterThan(4 * djiSrtFirstWindow));
      final reader = _reader(bytes);

      final fix = await readDjiSrtFix(reader.read, bytes.length);

      expect((fix?.latitude, fix?.longitude), (45.0, 6.0));
      expect(reader.reads, [(0, djiSrtFirstWindow)]);
    });

    test('reads on in steps until the first fix, and stops there', () async {
      final fixes = [for (var i = 0; i < 2000; i++) i < 600 ? (0.0, 0.0) : (45.5, 6.5)];
      final bytes = Uint8List.fromList(utf8.encode(_neo2(fixes)));
      final reader = _reader(bytes);

      final fix = await readDjiSrtFix(reader.read, bytes.length);

      expect((fix?.latitude, fix?.longitude), (45.5, 6.5));
      expect(reader.reads.first, (0, djiSrtFirstWindow));
      expect(reader.reads.skip(1).every((read) => read.$2 <= djiSrtWindowStep), isTrue);
      final read = reader.reads.fold(0, (sum, read) => sum + read.$2);
      expect(read, lessThan(bytes.length), reason: 'the rest of the file is not read');
    });

    test('reads a file without a fix to its end, and gives null', () async {
      final bytes = Uint8List.fromList(utf8.encode(_neo2([for (var i = 0; i < 800; i++) (0.0, 0.0)])));
      final reader = _reader(bytes);

      expect(await readDjiSrtFix(reader.read, bytes.length), isNull);
      expect(reader.reads.fold(0, (sum, read) => sum + read.$2), greaterThanOrEqualTo(bytes.length));
    });

    test('a fix in the last block of a short file is found', () async {
      final bytes = Uint8List.fromList(utf8.encode(_neo2([(0, 0), (41.9, 12.5)]).trimRight()));
      final reader = _reader(bytes);

      final fix = await readDjiSrtFix(reader.read, bytes.length);

      expect((fix?.latitude, fix?.longitude), (41.9, 12.5));
    });
  });

  test('djiSrtNameFor finds the .SRT of a video by its name, case aside', () {
    const names = ['DJI_20261021143100_0002_D.LRF', 'dji_20261021143100_0002_d.srt', 'DJI_20261021143100_0003_D.SRT'];

    expect(djiSrtNameFor('DJI_20261021143100_0002_D.MP4', names), 'dji_20261021143100_0002_d.srt');
    expect(djiSrtNameFor('DJI_20261021143100_0004_D.MP4', names), isNull);
    expect(djiSrtNameFor('DJI_20261021143100_0002_D.MP4', const []), isNull);
  });
}
