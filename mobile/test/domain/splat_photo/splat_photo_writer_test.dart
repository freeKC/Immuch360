import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/services/splat_photo/jpeg_walk.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_exif.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_tail.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_writer.dart';

import 'splat_photo_fixtures.dart';

/// The writer of the splat photos (plan of 3 November 2026, sections 2.2 and 6.3, lot L1)
void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('splat_photo_writer'));
  tearDown(() => dir.delete(recursive: true));

  /// The splat photo of [spz] and [poster] with the facts of [meta], written in memory through [writeSplatPhoto]
  Future<Uint8List> write(Uint8List spz, Uint8List poster, SplatPhotoMeta meta, {int chunk = splatPhotoChunk}) async {
    final out = BytesBuilder(copy: false);
    await writeSplatPhoto(
      read: (offset, length) async => Uint8List.sublistView(spz, offset, math.min(spz.length, offset + length)),
      length: spz.length,
      posterJpeg: poster,
      meta: meta,
      sink: out.add,
      chunk: chunk,
    );
    return out.takeBytes();
  }

  group('byte for byte the files of make_splat_photo_fixtures.py', () {
    final writer = splatPhotoContract()['writer'] as Map<String, dynamic>;
    for (final entry in writer.entries) {
      test('${entry.key} gives ${entry.value}', () async {
        final [poster, spz] = entry.key.split(' + ');
        final golden = entry.value as String;
        final bytes = await write(splatFixture(spz), splatPhotoFixture(poster), fixtureMeta(golden));
        expect(bytes, splatPhotoFixture(golden));
      });
    }

    test('the file writer gives the same file, with its SHA-1 and length, and leaves no .part', () async {
      final spz = File('${dir.path}/axes_v2.spz')..writeAsBytesSync(splatFixture('axes_v2.spz'));
      final out = File('${dir.path}/axes_v2_splat.jpg');
      final written = await writeSplatPhotoFile(
        spz: spz,
        posterJpeg: splatPhotoFixture('poster.jpg'),
        meta: fixtureMeta('ok_v2.jpg'),
        out: out,
      );
      final golden = splatPhotoFixture('ok_v2.jpg');
      expect(out.readAsBytesSync(), golden);
      expect(written.length, golden.length);
      expect(written.sha1, sha1.convert(golden).toString());
      expect(written.xmp.splatLength, 913);
      expect(written.headLength, golden.length - 913);
      expect(File('${out.path}.part').existsSync(), isFalse);
    });

    test('in an isolate too', () async {
      final spz = File('${dir.path}/axes_v4.spz')..writeAsBytesSync(splatFixture('axes_v4.spz'));
      final out = File('${dir.path}/axes_v4_splat.jpg');
      final steps = <double>[];
      final written = await writeSplatPhotoFileInIsolate(
        spz: spz,
        posterJpeg: splatPhotoFixture('poster.jpg'),
        meta: fixtureMeta('ok_v4.jpg'),
        out: out,
        onProgress: steps.add,
      );
      expect(out.readAsBytesSync(), splatPhotoFixture('ok_v4.jpg'));
      expect(written.sha1, sha1.convert(splatPhotoFixture('ok_v4.jpg')).toString());
      expect(written.xmp.splatUp, 'yUp');
      expect(steps.last, 1.0);
    });
  });

  group('the cleaning of the poster', () {
    test('drops the motion photo, the Ultra HDR parts, every other APP and anything after the EOI', () async {
      for (final name in ['poster_motion.jpg', 'poster_ultrahdr.jpg']) {
        final bytes = await write(splatFixture('axes_v2.spz'), splatPhotoFixture(name), fixtureMeta('ok_v2.jpg'));
        final text = latin1.decode(bytes);
        for (final word in ['GCamera', 'Container', 'MotionPhoto', 'MPF\x00', 'ftypmp42', 'a comment']) {
          expect(text, isNot(contains(word)), reason: '$word in $name');
        }
        final layout = walkJpeg(bytes);
        expect(layout.end, bytes.length - 913, reason: name);
        expect(layout.segments.where((segment) => segment.marker == jpegApp1).length, 2);
      }
    });

    test('keeps the order SOI, APP0, EXIF, packet, ICC, then the rest', () {
      final poster = _withIcc(splatPhotoFixture('poster.jpg'), 500 * 1024);
      final cleaned = cleanSplatPoster(poster);
      expect(cleaned.icc.length, (500 * 1024 / 65519).ceil());
      final head = splatPhotoHeadOf(
        poster: cleaned,
        xmp: const SplatPhotoXmp(splatName: 'a.spz'),
        meta: fixtureMeta('ok_v2.jpg'),
      );
      final markers = walkJpeg(head).segments.map((segment) => segment.marker).toList();
      expect(markers.take(3 + cleaned.icc.length), [
        jpegApp0,
        jpegApp1,
        jpegApp1,
        for (var i = 0; i < cleaned.icc.length; i++) jpegApp2,
      ]);
    });

    test('the packet ends before byte 65,536 even with a 500 KB ICC profile in front of it in the poster', () async {
      final poster = _withIcc(splatPhotoFixture('poster.jpg'), 500 * 1024);
      final bytes = await write(splatFixture('axes_v2.spz'), poster, fixtureMeta('ok_v2.jpg'));
      final end = latin1.decode(bytes.sublist(0, 70000)).indexOf('<?xpacket end="w"?>');
      expect(end, greaterThan(0));
      expect(end, lessThan(splatPhotoPacketWithin));
      expect(SplatPhotoXmp.findIn(bytes)!.splatLength, 913);
    });

    test('an ICC profile that is not RGB goes', () {
      final cleaned = cleanSplatPoster(_withIcc(splatPhotoFixture('poster.jpg'), 3000, space: 'GRAY'));
      expect(cleaned.icc, isEmpty);
    });

    test('refuses a square or a 2:1 frame, a poster above 1 MiB, and what is no JPEG', () {
      Matcher refused(SplatPhotoWriteProblem problem) =>
          throwsA(isA<SplatPhotoWriteException>().having((error) => error.problem, 'problem', problem));
      expect(
        () => cleanSplatPoster(splatPhotoFixture('poster_square.jpg')),
        refused(SplatPhotoWriteProblem.posterShape),
      );
      expect(() => cleanSplatPoster(splatPhotoFixture('poster_2to1.jpg')), refused(SplatPhotoWriteProblem.posterShape));
      expect(
        () => cleanSplatPoster(_withIcc(splatPhotoFixture('poster.jpg'), 1100 * 1024)),
        refused(SplatPhotoWriteProblem.posterTooLarge),
      );
      expect(
        () => cleanSplatPoster(splatPhotoFixture('png_with_packet.png')),
        refused(SplatPhotoWriteProblem.posterNotJpeg),
      );
      expect(
        () => cleanSplatPoster(Uint8List.sublistView(splatPhotoFixture('poster.jpg'), 0, 300)),
        refused(SplatPhotoWriteProblem.posterNotJpeg),
      );
    });

    test('the shape rule: 1.25 to 1.85, either way, 2,048 px at most', () {
      expect(isSplatPosterShape(1600, 1067), isTrue);
      expect(isSplatPosterShape(1067, 1600), isTrue);
      expect(isSplatPosterShape(1600, 1200), isTrue);
      expect(isSplatPosterShape(1600, 900), isTrue);
      expect(isSplatPosterShape(1600, 1600), isFalse);
      expect(isSplatPosterShape(1600, 800), isFalse);
      expect(isSplatPosterShape(3000, 2000), isFalse);
    });
  });

  group('the scene', () {
    test('a file that is no SPZ, or too short, is refused before anything is written', () async {
      final meta = fixtureMeta('ok_v2.jpg');
      final poster = splatPhotoFixture('poster.jpg');
      await expectLater(
        write(splatFixture('sh3.ply'), poster, meta),
        throwsA(isA<SplatPhotoWriteException>().having((e) => e.problem, 'problem', SplatPhotoWriteProblem.notSpz)),
      );
      await expectLater(
        write(Uint8List(16), poster, meta),
        throwsA(isA<SplatPhotoWriteException>().having((e) => e.problem, 'problem', SplatPhotoWriteProblem.spzSize)),
      );
    });

    test('21 MB written with reads and writes of 1 MiB at most, never the scene whole in memory', () async {
      final spz = Uint8List(21 * 1000 * 1000)..setAll(0, splatFixture('axes_v2.spz'));
      final reader = CountingReader(spz, limit: splatPhotoChunk);
      var largestWrite = 0;
      var written = 0;
      final digest = _Sink();
      final input = sha1.startChunkedConversion(digest);
      final (xmp, headLength, hex) = await writeSplatPhoto(
        read: reader.call,
        length: spz.length,
        posterJpeg: splatPhotoFixture('poster.jpg'),
        meta: fixtureMeta('ok_v2.jpg'),
        sink: (bytes) {
          largestWrite = math.max(largestWrite, bytes.length);
          written += bytes.length;
          input.add(bytes);
        },
      );
      expect(reader.largest, splatPhotoChunk);
      expect(largestWrite, lessThanOrEqualTo(splatPhotoChunk));
      expect(written, headLength + spz.length);
      input.close();
      expect(hex, digest.value.toString());
      expect(xmp.splatLength, spz.length);
      // Two passes, then the head of the SPZ once
      expect(reader.total, 2 * spz.length + math.min(65536, spz.length));
      // The poster and our segments: the head's room above the poster
      expect(headLength - splatPhotoFixture('poster.jpg').length, lessThan(2 * splatPhotoPadding + 2048));
    });

    test('a scene that changes between the passes is refused', () async {
      final spz = splatFixture('axes_v2.spz');
      // The head, the first pass, then the second pass, which finds another last byte
      var reads = 0;
      await expectLater(
        writeSplatPhoto(
          read: (offset, length) async {
            final bytes = Uint8List.fromList(spz.sublist(offset, math.min(spz.length, offset + length)));
            if (++reads == 3) {
              bytes[bytes.length - 1] ^= 1;
            }
            return bytes;
          },
          length: spz.length,
          posterJpeg: splatPhotoFixture('poster.jpg'),
          meta: fixtureMeta('ok_v2.jpg'),
          sink: (_) {},
        ),
        throwsA(isA<SplatPhotoWriteException>().having((e) => e.problem, 'problem', SplatPhotoWriteProblem.changed)),
      );
      expect(reads, 3);
    });

    test('a cancel leaves no .part, in the isolate or not', () async {
      final spz = File('${dir.path}/big.spz')
        ..writeAsBytesSync(Uint8List(32 << 20)..setAll(0, splatFixture('axes_v2.spz')));
      final out = File('${dir.path}/big_splat.jpg');
      var reads = 0;
      await expectLater(
        writeSplatPhotoFile(
          spz: spz,
          posterJpeg: splatPhotoFixture('poster.jpg'),
          meta: fixtureMeta('ok_v2.jpg'),
          out: out,
          cancelled: () => ++reads > 10,
        ),
        throwsA(isA<SplatPhotoWriteException>().having((e) => e.problem, 'problem', SplatPhotoWriteProblem.cancelled)),
      );
      expect(File('${out.path}.part').existsSync(), isFalse);
      expect(out.existsSync(), isFalse);

      final cancel = Completer<void>();
      final job = writeSplatPhotoFileInIsolate(
        spz: spz,
        posterJpeg: splatPhotoFixture('poster.jpg'),
        meta: fixtureMeta('ok_v2.jpg'),
        out: out,
        onProgress: (_) {
          if (!cancel.isCompleted) {
            cancel.complete();
          }
        },
        cancel: cancel.future,
      );
      await expectLater(
        job,
        throwsA(isA<SplatPhotoWriteException>().having((e) => e.problem, 'problem', SplatPhotoWriteProblem.cancelled)),
      );
      expect(File('${out.path}.part').existsSync(), isFalse);
      expect(out.existsSync(), isFalse);
    });

    test('a written file reads back: packet, place, head and sum', () async {
      final bytes = splatPhotoFixture('ok_v4.jpg');
      final xmp = SplatPhotoXmp.findIn(bytes)!;
      final check = await checkSplatPhotoTail(CountingReader(bytes).call, fileLength: bytes.length, xmp: xmp);
      expect(check.isOk, isTrue);
      expect(check.headMatches, isTrue);
      expect(check.place!.length, splatFixture('axes_v4.spz').length);
    });
  });

  group('the EXIF', () {
    test('the date, its offset and the place, with the padding of Windows in IFD0', () {
      final exif = splatPhotoExif(
        width: 1600,
        height: 1067,
        software: 'Immuch360 3.3.0',
        taken: const SplatPhotoDate(2026, 11, 3, 16, 53, 0, offsetMinutes: 60),
        latitude: -33.8568,
        longitude: 151.2153,
      );
      final text = latin1.decode(exif);
      expect(text, startsWith('Exif\x00\x00II*\x00'));
      expect(text, contains('2026:11:03 16:53:00\x00'));
      expect(text, contains('+01:00\x00'));
      expect(text, contains('Immuch360 3.3.0\x00'));
      expect(text, contains('S\x00'));
      expect(text, contains('E\x00'));
      expect(exif.length, greaterThan(splatPhotoPadding));
      expect(text, contains('\x1C\xEA\x00\x00\x00\x08'));
      expect(exif.length, lessThan(splatPhotoPadding + 600));
    });

    test('the dates of the packet and of the upload', () {
      const date = SplatPhotoDate(2026, 7, 14, 9, 30, 15, offsetMinutes: -240);
      expect(date.iso, '2026-07-14T09:30:15-04:00');
      expect(date.exif, '2026:07:14 09:30:15');
      expect(date.utc, DateTime.utc(2026, 7, 14, 13, 30, 15));
      expect(SplatPhotoDate.of(DateTime.utc(2026, 1, 2, 3, 4, 5)).iso, '2026-01-02T03:04:05+00:00');
    });
  });
}

/// [jpeg] with an ICC profile of [length] bytes in APP2 chunks after its APP0, of the colour space [space]
Uint8List _withIcc(Uint8List jpeg, int length, {String space = 'RGB '}) {
  final profile = Uint8List(length)..setAll(16, ascii.encode(space));
  const most = 65519;
  final count = (length / most).ceil();
  final chunks = BytesBuilder(copy: false);
  for (var i = 0; i < count; i++) {
    final part = profile.sublist(i * most, math.min(length, (i + 1) * most));
    final size = 2 + 12 + 2 + part.length;
    chunks
      ..add([0xFF, 0xE2, size >> 8, size & 0xFF])
      ..add(ascii.encode('ICC_PROFILE\x00'))
      ..add([i + 1, count])
      ..add(part);
  }
  final app0 = walkJpeg(jpeg).segments.first;
  return (BytesBuilder(copy: false)
        ..add(jpeg.sublist(0, app0.end))
        ..add(chunks.takeBytes())
        ..add(jpeg.sublist(app0.end)))
      .takeBytes();
}

class _Sink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
