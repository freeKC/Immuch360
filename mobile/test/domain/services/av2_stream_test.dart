// The reader of AV2 files (lot AD1 of store/m2/av2-2026-11-02/plan-2026-11-02.md): the fixtures of lot AD0
// (test/fixtures/av2, FIXTURES.md), whose units, packets and access points fixtures.json lists as the script of AD0 read
// them and checked them by decoding; the AV1 sample and random bytes refused; the cut and the damaged files. The six
// streams of the measure of 2 November (private clips, never committed) are read when IMMUCH360_AV2_STREAMS names
// their folder: as many units as the decoders gave frames, the key frames of WorldCup at 0, 60 and 120.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/av2_stream.dart';
import 'package:path/path.dart' as p;

const _fixtures = 'test/fixtures/av2';

Uint8List _fixture(String name) => File(p.join(_fixtures, name)).readAsBytesSync();

final Map<String, Object?> _expected =
    (jsonDecode(File(p.join(_fixtures, 'fixtures.json')).readAsStringSync()) as Map<String, Object?>)['files']!
        as Map<String, Object?>;

Map<String, Object?> _entry(String name) => _expected[name]! as Map<String, Object?>;

/// Reads [bytes] as a local file does, recording each read
Av2ByteReader _reader(Uint8List bytes, [List<(int, int)>? reads]) => (offset, length) async {
  reads?.add((offset, length));
  if (offset >= bytes.length) {
    return Uint8List(0);
  }
  return Uint8List.sublistView(bytes, offset, math.min(bytes.length, offset + length));
};

Future<Av2Index> _index(Uint8List bytes, {int? window, List<(int, int)>? reads}) => window == null
    ? indexAv2Stream(_reader(bytes, reads), bytes.length)
    : indexAv2Stream(_reader(bytes, reads), bytes.length, window: window);

/// The units of fixtures.json for the file [name], as the index gives them
List<Av2Unit> _expectedUnits(String name, {bool wholeOnly = true}) {
  final index = _entry(name)['index']! as Map<String, Object?>;
  return [
    for (final unit in (index['units']! as List).cast<Map<String, Object?>>())
      if (!wholeOnly || unit['complete'] == true)
        Av2Unit(
          index: unit['index']! as int,
          offset: unit['offset']! as int,
          length: unit['size']! as int,
          obuTypes: (unit['obu_types']! as List).cast<int>(),
          packet: unit['packet'] as int?,
        ),
  ];
}

List<Av2Packet> _expectedPackets(String name) {
  final index = _entry(name)['index']! as Map<String, Object?>;
  return [
    for (final packet in (index['packets']! as List).cast<Map<String, Object?>>())
      Av2Packet(
        offset: packet['offset']! as int,
        size: packet['size']! as int,
        pts: packet['pts']! as int,
        complete: packet['complete']! as bool,
      ),
  ];
}

/// An IVF header of [fourcc]
Uint8List _ivfHeader(String fourcc, {int headerLength = 32}) {
  final bytes = ByteData(32)
    ..setUint8(0, 0x44)
    ..setUint8(1, 0x4b)
    ..setUint8(2, 0x49)
    ..setUint8(3, 0x46)
    ..setUint16(6, headerLength, Endian.little)
    ..setUint16(12, 256, Endian.little)
    ..setUint16(14, 144, Endian.little)
    ..setUint32(16, 30, Endian.little)
    ..setUint32(20, 1, Endian.little)
    ..setUint32(24, 2, Endian.little);
  final list = bytes.buffer.asUint8List();
  list.setAll(8, ascii.encode(fourcc));
  return list;
}

void main() {
  group('readAv2Head, the badge from 32 bytes', () {
    test('tells an AV2 IVF by its four characters and reads its header', () {
      for (final name in [
        'av2-256x144-8bit.ivf',
        'av2-256x144-10bit.ivf',
        'av2-256x144-8bit-cut.ivf',
        'av2-256x144-8bit-damaged.ivf',
      ]) {
        final head = readAv2Head(Uint8List.sublistView(_fixture(name), 0, av2HeadLength));

        expect(
          head,
          const Av2Head.ivf(width: 256, height: 144, rate: 30, scale: 1, framesInHeader: 12, headerLength: 32),
          reason: name,
        );
        expect(head!.frameRate, (numerator: 30, denominator: 1), reason: name);
      }
    });

    test('tells a Section 5 stream by its first OBUs: a temporal delimiter, then the sequence header', () {
      for (final name in ['av2-256x144-8bit.obu', 'av2-256x144-10bit.obu']) {
        final bytes = _fixture(name);

        expect(bytes.sublist(0, 4), [0x01, 0x08, 0x18, 0x04], reason: name);
        expect(readAv2Head(Uint8List.sublistView(bytes, 0, av2HeadLength)), const Av2Head.obu(), reason: name);
        // Four bytes are enough: the delimiter and the header of the next OBU
        expect(readAv2Head(Uint8List.sublistView(bytes, 0, 4)), const Av2Head.obu(), reason: name);
        expect(readAv2Head(Uint8List.sublistView(bytes, 0, 3)), isNull, reason: name);
        expect(const Av2Head.obu().frameRate, isNull);
      }
      // A delimiter with the extension byte, then a layer configuration record and the sequence header
      expect(readAv2Head([0x02, 0x88, 0x00, 0x02, 0x40, 0x00, 0x03, 0x04, 0x00, 0x00]), const Av2Head.obu());
    });

    test('refuses AV1 in IVF, VP9 in IVF, AV1 OBUs, random bytes and too few bytes', () {
      expect(readAv2Head(Uint8List.sublistView(_fixture('av1-256x144-8bit.ivf'), 0, av2HeadLength)), isNull);
      expect(readAv2Head(_ivfHeader('VP90')), isNull);
      expect(readAv2Head(_ivfHeader('AV02', headerLength: 16)), isNull);
      // The payload of the first packet of the AV1 sample: its temporal delimiter is 0x12 0x00
      final av1 = _fixture('av1-256x144-8bit.ivf');
      final av1Obus = Uint8List.sublistView(av1, 44, 44 + av2HeadLength);
      expect(av1Obus.sublist(0, 2), [0x12, 0x00]);
      expect(readAv2Head(av1Obus), isNull);
      // A delimiter whose size counts more than its header, and one followed by a tile group before any sequence header
      expect(readAv2Head([0x02, 0x08, 0x00, 0x18, 0x04]), isNull);
      expect(readAv2Head([0x01, 0x08, 0x05, 0x1c, 0, 0, 0, 0]), isNull);
      for (var length = 0; length < 4; length++) {
        expect(readAv2Head(Uint8List.sublistView(_fixture('av2-256x144-8bit.ivf'), 0, length)), isNull);
      }
      expect(readAv2Head(Uint8List.sublistView(_fixture('av2-256x144-8bit.ivf'), 0, 31)), isNull);
      final random = math.Random(20261102);
      for (var i = 0; i < 5000; i++) {
        final bytes = Uint8List.fromList([for (var j = 0; j < av2HeadLength; j++) random.nextInt(256)]);
        expect(readAv2Head(bytes), isNull, reason: bytes.toString());
      }
    });
  });

  group('indexAv2Stream', () {
    test('cuts each fixture into the units of fixtures.json: 12 units, access points 0 and 6', () async {
      for (final name in [
        'av2-256x144-8bit.ivf',
        'av2-256x144-10bit.ivf',
        'av2-256x144-8bit.obu',
        'av2-256x144-10bit.obu',
      ]) {
        final bytes = _fixture(name);
        final index = await _index(bytes);

        expect(index.units, _expectedUnits(name), reason: name);
        expect(index.frameCount, 12, reason: name);
        expect(index.frameCount, _entry(name)['frames'], reason: name);
        expect(index.accessPoints, [0, 6], reason: name);
        expect(index.startsWithAccessPoint, isTrue, reason: name);
        expect(index.end, Av2IndexEnd.complete, reason: name);
        expect(index.endOffset, bytes.length, reason: name);
        expect(index.framesBeforeCut, isNull, reason: name);
        expect(index.hasContentInterpretation, isFalse, reason: name);
        if (name.endsWith('.ivf')) {
          expect(index.packets, _expectedPackets(name), reason: name);
          expect(index.frameRate, (numerator: 30, denominator: 1), reason: name);
          expect(index.frameRateKnown, isTrue, reason: name);
        } else {
          expect(index.packets, isEmpty, reason: name);
          expect(index.frameRate, av2DefaultFrameRate, reason: name);
          expect(index.frameRateKnown, isFalse, reason: name);
        }
      }
    });

    test('several units in one IVF packet, its pts the first frame out, not the frame its first unit codes', () async {
      final index = await _index(_fixture('av2-256x144-8bit.ivf'));

      expect(index.units.map((unit) => unit.packet), [0, 1, 1, 1, 2, 3, 4, 5, 5, 5, 6, 7]);
      expect(index.packets.map((packet) => packet.pts), [0, 1, 3, 4, 6, 7, 9, 10]);
      // An access point sits at its display index: its unit index, and the pts of its packet
      for (final point in index.accessPoints) {
        expect(index.packets[index.units[point].packet!].pts, point);
      }
      expect(index.units.first.obuTypes, [
        Av2ObuType.temporalDelimiter,
        Av2ObuType.sequenceHeader,
        Av2ObuType.closedLoopKey,
      ]);
      expect(index.units[2].obuTypes, [Av2ObuType.temporalDelimiter, Av2ObuType.regularTip]);
    });

    test('a .obu holds the bytes of the units of its .ivf, unit for unit', () async {
      for (final bits in [8, 10]) {
        final ivf = _fixture('av2-256x144-${bits}bit.ivf');
        final obu = _fixture('av2-256x144-${bits}bit.obu');
        final fromIvf = await _index(ivf);
        final fromObu = await _index(obu);

        expect(fromObu.frameCount, fromIvf.frameCount);
        expect(fromObu.accessPoints, fromIvf.accessPoints);
        for (var k = 0; k < fromIvf.frameCount; k++) {
          final a = fromIvf.units[k];
          final b = fromObu.units[k];
          expect(b.obuTypes, a.obuTypes, reason: '$bits bits, unit $k');
          expect(
            obu.sublist(b.offset, b.offset + b.length),
            ivf.sublist(a.offset, a.offset + a.length),
            reason: '$bits bits, unit $k',
          );
        }
        // And nothing else: the units of the .obu cover it end to end
        expect(fromObu.units.fold<int>(0, (sum, unit) => sum + unit.length), obu.length);
      }
    });

    test('the cut file is indexed to its last whole unit', () async {
      final cut = _fixture('av2-256x144-8bit-cut.ivf');
      final index = await _index(cut);
      final entry = _entry('av2-256x144-8bit-cut.ivf');

      expect(index.end, Av2IndexEnd.cut);
      expect(index.frameCount, entry['whole_units']);
      expect(index.frameCount, 8);
      expect(index.units, _expectedUnits('av2-256x144-8bit-cut.ivf'));
      expect(index.accessPoints, [0, 6]);
      expect(index.endOffset, 5236 + 77);
      expect(index.packets, _expectedPackets('av2-256x144-8bit-cut.ivf'));
      expect(index.packets.last.complete, isFalse);
      // The whole units carry frames 0 to 6 and 11: 7 play without a gap
      expect(index.framesBeforeCut, entry['contiguous_frames_from_start']);
      expect(index.framesBeforeCut, 7);
      // The header still says 12 frames, as after an interrupted copy
      expect(index.head.framesInHeader, 12);
    });

    test('the damaged file keeps its container: 12 whole units, access points 0 and 6', () async {
      final index = await _index(_fixture('av2-256x144-8bit-damaged.ivf'));

      expect(index.end, Av2IndexEnd.complete);
      expect(index.units, _expectedUnits('av2-256x144-8bit-damaged.ivf'));
      expect(index.accessPoints, [0, 6]);
    });

    test('a Section 5 stream cut inside an OBU keeps the units before it', () async {
      final obu = _fixture('av2-256x144-8bit.obu');
      final index = await _index(Uint8List.sublistView(obu, 0, obu.length - 3));

      expect(index.end, Av2IndexEnd.cut);
      expect(index.frameCount, 11);
      expect(index.endOffset, 5230);
      expect(index.framesBeforeCut, isNull);
    });

    test(
      'an OBU whose size runs past its whole packet, or a size of 0, is damage: the units before it are kept',
      () async {
        final ivf = _fixture('av2-256x144-8bit.ivf');
        // Unit 1, at 1754 in packet 1: its delimiter (01 08) then its tile group, whose size byte is at 1756
        expect(ivf.sublist(1754, 1756), [0x01, 0x08]);
        final tooLong = Uint8List.fromList(ivf)..[1756] = 0x7f;
        final zero = Uint8List.fromList(ivf)..[1756] = 0x00;

        for (final (bytes, label) in [(tooLong, 'size past the packet'), (zero, 'size 0')]) {
          final index = await _index(bytes);

          expect(index.end, Av2IndexEnd.damaged, reason: label);
          expect(index.frameCount, 1, reason: label);
          expect(index.endOffset, 1742, reason: label);
        }
        // A packet that does not start with a temporal delimiter
        final noDelimiter = Uint8List.fromList(ivf)..[1755] = 0x1c;
        final index = await _index(noDelimiter);
        expect(index.end, Av2IndexEnd.damaged);
        expect(index.frameCount, 1);
      },
    );

    test('refuses AV1 and VP9 in IVF, AV1 OBUs and random bytes', () async {
      await expectLater(
        _index(_fixture('av1-256x144-8bit.ivf')),
        throwsA(
          isA<Av2FormatException>()
              .having((e) => e.reason, 'reason', Av2Refusal.av1)
              .having((e) => e.fourcc, 'fourcc', 'AV01'),
        ),
      );
      await expectLater(
        _index(Uint8List.fromList([..._ivfHeader('VP90'), ...List.filled(40, 0)])),
        throwsA(isA<Av2FormatException>().having((e) => e.reason, 'reason', Av2Refusal.otherCodec)),
      );
      final av1 = _fixture('av1-256x144-8bit.ivf');
      await expectLater(
        _index(Uint8List.sublistView(av1, 44)),
        throwsA(isA<Av2FormatException>().having((e) => e.reason, 'reason', Av2Refusal.notAv2)),
      );
      final random = math.Random(42);
      for (var i = 0; i < 200; i++) {
        final bytes = Uint8List.fromList([for (var j = 0; j < 4096; j++) random.nextInt(256)]);
        await expectLater(_index(bytes), throwsA(isA<Av2FormatException>()));
      }
      await expectLater(_index(Uint8List(0)), throwsA(isA<Av2FormatException>()));
    });

    test('reads the OBU headers only: a small window skips the bytes of the large OBUs', () async {
      final ivf = _fixture('av2-256x144-8bit.ivf');
      final reads = <(int, int)>[];
      final whole = await _index(ivf);
      final windowed = await _index(ivf, window: 64, reads: reads);

      expect(windowed.units, whole.units);
      expect(windowed.packets, whole.packets);
      final read = reads.fold<int>(0, (sum, read) => sum + read.$2);
      expect(read, lessThan(ivf.length ~/ 2), reason: '$reads');
      // The key frames of units 0 and 6 (1 698 and 3 309 bytes) are never read
      expect(reads.any((read) => read.$1 > 100 && read.$1 < 1700), isFalse, reason: '$reads');
    });

    test('the access point before a frame: where a decoder starts to give it', () async {
      final index = await _index(_fixture('av2-256x144-8bit.obu'));

      expect([for (var k = 0; k < 12; k++) index.accessPointBefore(k)], [0, 0, 0, 0, 0, 0, 6, 6, 6, 6, 6, 6]);
    });
  });

  group('the six streams of the measure of 2 November', () {
    final folder = Platform.environment['IMMUCH360_AV2_STREAMS'];

    Future<Av2Index> indexFile(String name) async {
      final file = File(p.join(folder!, name));
      final opened = await file.open();
      try {
        return await indexAv2Stream((offset, length) async {
          await opened.setPosition(offset);
          return opened.read(length);
        }, await file.length());
      } finally {
        await opened.close();
      }
    }

    test('as many units as the decoders gave frames, the access points every two seconds', () async {
      // Frames decoded by avmdec v1.0.0 and dav2d (measure, section 5), and the key frames every 2 s of the encodes
      final streams = {
        'worldcup-1080p30-8b.ivf': (151, [0, 60, 120], (numerator: 30, denominator: 1), 1920, 1080),
        'skater-1080p30-10b.ivf': (150, [0, 60, 120], (numerator: 30, denominator: 1), 1920, 1080),
        'carnaby-1080x1920p60-8b.ivf': (64, [0], (numerator: 60000, denominator: 1001), 1080, 1920),
        'flowersky-2160p30-8b.ivf': (60, [0], (numerator: 30, denominator: 1), 3840, 2160),
        'cosmos-2048x1080p24-10b.ivf': (51, [0, 48], (numerator: 24, denominator: 1), 2048, 1080),
        'cosmos-4096x2160p24-10b.ivf': (51, [0, 48], (numerator: 24, denominator: 1), 4096, 2160),
      };
      for (final MapEntry(key: name, value: (frames, points, rate, width, height)) in streams.entries) {
        final index = await indexFile(name);

        expect(index.end, Av2IndexEnd.complete, reason: name);
        expect(index.frameCount, frames, reason: name);
        expect(index.head.framesInHeader, frames, reason: name);
        expect(index.accessPoints, points, reason: name);
        expect(index.frameRate, rate, reason: name);
        expect((index.head.width, index.head.height), (width, height), reason: name);
        // Each access point at the head of its packet, at the pts of its packet
        for (final point in points) {
          final unit = index.units[point];
          expect(unit.offset, index.packets[unit.packet!].offset + 12, reason: '$name, unit $point');
          expect(index.packets[unit.packet!].pts, point, reason: '$name, unit $point');
        }
      }
      // WorldCup: 82 packets for its 151 frames
      expect((await indexFile('worldcup-1080p30-8b.ivf')).packets, hasLength(82));
    });

    test('the .obu of WorldCup gives the units of its .ivf', () async {
      final ivf = await indexFile('worldcup-1080p30-8b.ivf');
      final obu = await indexFile('worldcup-1080p30-8b.obu');

      expect(obu.frameCount, 151);
      expect(obu.accessPoints, [0, 60, 120]);
      expect([for (final unit in obu.units) unit.length], [for (final unit in ivf.units) unit.length]);
      expect([for (final unit in obu.units) unit.obuTypes], [for (final unit in ivf.units) unit.obuTypes]);
    });
  }, skip: Platform.environment['IMMUCH360_AV2_STREAMS'] == null ? 'no IMMUCH360_AV2_STREAMS (private clips)' : false);
}
