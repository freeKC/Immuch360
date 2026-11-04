// What the tests of the splat photos share: the fixtures of .github/desktop/ai/make_splat_photo_fixtures.py, their
// contract, and readers that count what they read.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_exif.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_writer.dart';

const splatPhotoFixtures = 'test/fixtures/splat_photo';

Uint8List splatPhotoFixture(String name) => File('$splatPhotoFixtures/$name').readAsBytesSync();

Uint8List splatFixture(String name) => File('test/fixtures/splat/$name').readAsBytesSync();

/// splat_photo_contract_v1.json
Map<String, dynamic> splatPhotoContract() =>
    jsonDecode(File('$splatPhotoFixtures/splat_photo_contract_v1.json').readAsStringSync()) as Map<String, dynamic>;

/// The facts the fixture script gave the writer for [name] (ok_v2.jpg, ok_v4.jpg)
SplatPhotoMeta fixtureMeta(String name) {
  final meta = (splatPhotoContract()['meta'] as Map<String, dynamic>)[name] as Map<String, dynamic>;
  final iso = meta['date'] as String;
  final sign = iso[19] == '-' ? -1 : 1;
  final date = SplatPhotoDate(
    int.parse(iso.substring(0, 4)),
    int.parse(iso.substring(5, 7)),
    int.parse(iso.substring(8, 10)),
    int.parse(iso.substring(11, 13)),
    int.parse(iso.substring(14, 16)),
    int.parse(iso.substring(17, 19)),
    offsetMinutes: sign * (int.parse(iso.substring(20, 22)) * 60 + int.parse(iso.substring(23, 25))),
  );
  return SplatPhotoMeta(
    name: meta['name'] as String,
    date: date,
    software: meta['software'] as String,
    creatorTool: meta['creatorTool'] as String,
    description: meta['description'] as String?,
    up: meta['up'] as String?,
    poster: SplatPosterKind.fromXmp(meta['poster'] as String?),
    latitude: (meta['latitude'] as num?)?.toDouble(),
    longitude: (meta['longitude'] as num?)?.toDouble(),
  );
}

/// A reader of [bytes] that counts its reads and the most bytes asked at once, and throws past [limit] bytes asked
class CountingReader {
  CountingReader(this.bytes, {this.limit});

  final Uint8List bytes;
  final int? limit;
  int reads = 0;
  int largest = 0;
  int total = 0;

  Future<Uint8List> call(int offset, int length) async {
    reads++;
    largest = math.max(largest, length);
    total += length;
    if (limit != null && length > limit!) {
      throw StateError('$length bytes asked at once');
    }
    if (offset >= bytes.length) {
      return Uint8List(0);
    }
    return Uint8List.sublistView(bytes, offset, math.min(bytes.length, offset + length));
  }
}
