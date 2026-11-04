import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/services/splat_photo/jpeg_walk.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_tail.dart';

import 'splat_photo_fixtures.dart';

/// The scene of a splat photo, read back (plan of 3 November 2026, section 5.2): every fixture of
/// splat_photo_contract_v1.json gives the verdict the fixture script gave it
void main() {
  final contract = splatPhotoContract();
  final fixtures = contract['fixtures'] as Map<String, dynamic>;

  /// What the reader of the app gives for [bytes]: notCarrier without a packet, else the check of its scene
  Future<(String, SplatPhotoTailCheck?)> verdictOf(Uint8List bytes, {CountingReader? reader}) async {
    final xmp = SplatPhotoXmp.findIn(
      bytes.length > splatPhotoHeadBytes ? bytes.sublist(0, splatPhotoHeadBytes) : bytes,
    );
    if (xmp == null) {
      return ('notCarrier', null);
    }
    final check = await checkSplatPhotoTail((reader ?? CountingReader(bytes)).call, fileLength: bytes.length, xmp: xmp);
    return (check.problem?.name ?? 'ok', check);
  }

  test('the contract lists every case of the plan', () {
    expect(contract['formatVersion'], 1);
    expect(
      fixtures.keys,
      containsAll(<String>[
        'ok_v2.jpg', 'ok_v4.jpg', 'ok_exiftool.jpg', 'bad_sum.jpg', 'cut_tail.jpg', 'trailer.jpg', //
        'reencoded_with_xmp.jpg', 'reencoded_plain.jpg', 'huge_claim.jpg', 'newer_format.jpg', 'newer_payload.jpg',
        'ply_payload.jpg', 'head_mismatch.jpg', 'png_with_packet.png',
      ]),
    );
  });

  for (final entry in fixtures.entries) {
    final wanted = entry.value as Map<String, dynamic>;
    test('${entry.key}: ${wanted['verdict']}', () async {
      final bytes = splatPhotoFixture(entry.key);
      expect(bytes.length, wanted['bytes']);
      final (verdict, check) = await verdictOf(bytes);
      expect(verdict, wanted['verdict']);
      final packet = wanted['packet'] as Map<String, dynamic>?;
      if (packet != null) {
        final xmp = SplatPhotoXmp.findIn(bytes)!;
        expect(xmp.formatVersion, packet['formatVersion']);
        expect(xmp.splatFormat, packet['splatFormat']);
        expect(xmp.splatLength, packet['splatLength']);
        expect(xmp.splatSha256, packet['splatSha256']);
        expect(xmp.splatName, packet['splatName']);
      }
      final head = wanted['head'] as Map<String, dynamic>?;
      if (head != null) {
        expect(
          check!.head,
          SplatHead(
            format: SplatFormat.spz,
            formatVersion: head['version'] as int,
            gaussians: head['gaussians'] as int,
            shDegree: head['shDegree'] as int,
          ),
        );
        expect(check.headMatches, wanted['headMatches']);
      }
    });
  }

  test('a packet whose scene would be 3,000,000,000 bytes reads nothing past the head', () async {
    final bytes = splatPhotoFixture('huge_claim.jpg');
    final reader = CountingReader(bytes, limit: 1 << 20);
    final (verdict, _) = await verdictOf(bytes, reader: reader);
    expect(verdict, 'missing');
    expect(reader.reads, 0);
  });

  test('a packet past the first 128 KiB is not found (a 200 KB comment in front of it)', () {
    final bytes = splatPhotoFixture('ok_v2.jpg');
    final comments = BytesBuilder(copy: false);
    for (var i = 0; i < 4; i++) {
      comments.add([0xFF, 0xFE, 0xC3, 0x52]);
      comments.add(Uint8List(0xC352 - 2));
    }
    final late =
        (BytesBuilder(copy: false)
              ..add(bytes.sublist(0, 2))
              ..add(comments.takeBytes())
              ..add(bytes.sublist(2)))
            .takeBytes();
    expect(late.length, greaterThan(200000));
    expect(SplatPhotoXmp.findIn(late), isNull);
    expect(walkJpeg(late).segments.first.marker, jpegCom);
  });

  test('a file shorter than its scene is lost, told by its size alone', () {
    final xmp = SplatPhotoXmp.findIn(splatPhotoFixture('ok_v2.jpg'))!;
    expect(splatPhotoProblemOf(xmp, fileLength: 900), SplatPhotoProblem.lost);
    expect(splatPhotoProblemOf(xmp, fileLength: 916), SplatPhotoProblem.lost);
    expect(splatPhotoProblemOf(xmp, fileLength: 917), isNull);
    expect(splatPhotoProblemOf(xmp), isNull);
  });

  test('the first bytes of each SPZ version', () {
    expect(startsAsSpz(splatFixture('axes_v1.spz'), 1), isTrue);
    expect(startsAsSpz(splatFixture('axes_v2.spz'), 2), isTrue);
    expect(startsAsSpz(splatFixture('axes_v3.spz'), 3), isTrue);
    expect(startsAsSpz(splatFixture('axes_v4.spz'), 4), isTrue);
    expect(startsAsSpz(splatFixture('axes_v4.spz'), 2), isFalse);
    expect(startsAsSpz(splatFixture('axes_v2.spz'), 4), isFalse);
    expect(startsAsSpz(splatFixture('axes_v2.spz'), 5), isFalse);
  });

  test('the sum read in chunks gives the same verdict', () async {
    final bytes = splatPhotoFixture('ok_v2.jpg');
    final xmp = SplatPhotoXmp.findIn(bytes)!;
    final reader = CountingReader(bytes);
    final check = await checkSplatPhotoTail(reader.call, fileLength: bytes.length, xmp: xmp, chunk: 100);
    expect(check.isOk, isTrue);
    expect(reader.largest, lessThanOrEqualTo(913));
    expect(reader.reads, 1 + 10);
  });
}
