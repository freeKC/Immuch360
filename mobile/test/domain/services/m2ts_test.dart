import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/m2ts.dart';

import 'm2ts_fixtures.dart';

void main() {
  final ts = tsPackets(40);
  final m2ts = m2tsOf(ts);

  group('isM2tsHead', () {
    test('a sync byte after the timestamp of each packet', () {
      expect(isM2tsHead(m2ts), isTrue);
    });

    test('not a TS with 188 byte packets, nor another file, nor a head too short to tell', () {
      expect(isM2tsHead(ts), isFalse);
      expect(isM2tsHead(Uint8List(m2tsSniffLength)), isFalse);
      expect(isM2tsHead(Uint8List.sublistView(m2ts, 0, m2tsSniffLength - 1)), isFalse);
      final broken = Uint8List.fromList(m2ts)..[4 + 3 * m2tsPacketSize] = 0;
      expect(isM2tsHead(broken), isFalse, reason: 'a sync byte missing');
    });
  });

  test('mayBeM2ts: the names and types of transport streams', () {
    expect(mayBeM2ts('m2ts', 'video/mp2t'), isTrue);
    expect(mayBeM2ts('mts', 'application/octet-stream'), isTrue);
    expect(mayBeM2ts('mkv', 'video/vnd.dlna.mpeg-tts'), isTrue);
    expect(mayBeM2ts('mp4', 'video/mp4'), isFalse);
    expect(mayBeM2ts('mkv', 'video/x-matroska'), isFalse);
  });

  test('the size of the TS, an incomplete last packet left out', () {
    expect(tsSizeOfM2ts(m2ts.length), ts.length);
    expect(tsSizeOfM2ts(m2ts.length + 100), ts.length);
    expect(tsSizeOfM2ts(100), 0);
  });

  test('the bytes of the file to read for a range of the TS: whole packets, within the file', () {
    expect(m2tsFileRange(0, 188, m2ts.length), (start: 0, end: 192));
    expect(m2tsFileRange(10, 20, m2ts.length), (start: 0, end: 192));
    expect(m2tsFileRange(187, 189, m2ts.length), (start: 0, end: 384));
    expect(m2tsFileRange(188, 376, m2ts.length), (start: 192, end: 384));
    expect(m2tsFileRange(ts.length - 1, ts.length, m2ts.length + 50), (start: m2ts.length - 192, end: m2ts.length));
  });

  group('M2tsToTs', () {
    Uint8List convert(int start, int end, List<int> chunkSizes) {
      final range = m2tsFileRange(start, end, m2ts.length);
      final toTs = M2tsToTs(skip: start % tsPacketSize, length: end - start);
      final out = BytesBuilder();
      var at = range.start;
      var i = 0;
      while (at < range.end) {
        final size = min(chunkSizes[i++ % chunkSizes.length], range.end - at);
        out.add(toTs.convert(Uint8List.sublistView(m2ts, at, at + size)));
        at += size;
      }
      expect(toTs.isDone, isTrue);
      return out.takeBytes();
    }

    test('the whole file, in one chunk or in chunks that split the packets anywhere', () {
      expect(convert(0, ts.length, [m2ts.length]), ts);
      expect(convert(0, ts.length, [1]), ts);
      expect(convert(0, ts.length, [3, 190, 500, 2, 1000]), ts);
    });

    test('any range, cut inside the packets', () {
      final random = Random(28);
      for (var i = 0; i < 300; i++) {
        final start = random.nextInt(ts.length);
        final end = start + 1 + random.nextInt(ts.length - start);
        final chunks = [1 + random.nextInt(700), 1 + random.nextInt(50)];
        expect(convert(start, end, chunks), ts.sublist(start, end), reason: '$start-$end in chunks of $chunks');
      }
    });

    test('nothing more once the length was given', () {
      final toTs = M2tsToTs(skip: 0, length: 10);
      expect(toTs.convert(Uint8List.sublistView(m2ts, 0, 192)), ts.sublist(0, 10));
      expect(toTs.convert(Uint8List.sublistView(m2ts, 192, 384)), isEmpty);
    });
  });
}
