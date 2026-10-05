import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/apple_spatial/heic_stereo_probe.dart';

import '../../../test_utils/heif_builder.dart';

void main() {
  group('probeHeicStereoPair on the sample head', () {
    // The ftyp and meta boxes of an Apple ImageIO spatial photo, MIT licensed (see the note next to the file)
    final sample = File('test/fixtures/apple_spatial/udibr_fisheye_0S9A9186_head.bin').readAsBytesSync();

    test('finds both eyes, the pitm field, the size, the disparity and the field of view', () async {
      final reader = RecordingReader(sample);
      final pair = await probeHeicStereoPair(reader.call);

      expect(pair, isNotNull);
      expect(pair!.primaryItemId, 37);
      expect(pair.leftItemId, 37);
      expect(pair.rightItemId, 74);
      expect(pair.pitmIdOffset, 129);
      expect(pair.pitmIdBytes, 2);
      expect(pair.width, 3072);
      expect(pair.height, 3072);
      expect(pair.rotation, 0);
      expect(pair.disparityAdjustment, -1000);
      expect(pair.horizontalFovDegrees, closeTo(59.98, 0.01));
      expect(pair.unknownProperties, isEmpty);
      // The meta box is in the head: one read
      expect(reader.reads, [(0, heicStereoHeadLength)]);
    });

    test('the pitm field holds the primary item id where the pair says', () async {
      final pair = (await probeHeicStereoPair(RecordingReader(sample).call))!;

      expect(sample[pair.pitmIdOffset] << 8 | sample[pair.pitmIdOffset + 1], pair.primaryItemId);
    });

    test('gives the JSON of the immersive viewer', () async {
      final pair = (await probeHeicStereoPair(RecordingReader(sample).call))!;

      expect(jsonDecode(pair.toImmersiveJson()), {
        'kind': 'heicStereoPair',
        'version': 1,
        'primaryItemId': 37,
        'leftItemId': 37,
        'rightItemId': 74,
        'pitmIdOffset': 129,
        'pitmIdBytes': 2,
        'width': 3072,
        'height': 3072,
        'rotation': 0,
        'disparityAdjustment': -1000,
        'horizontalFovDeg': 59.98,
      });
      final restored = HeicStereoPair.fromImmersiveMap(jsonDecode(pair.toImmersiveJson()));
      expect(restored?.leftItemId, 37);
      expect(restored?.rightItemId, 74);
      expect(restored?.disparityAdjustment, -1000);
      expect(restored?.horizontalFovDegrees, 59.98);
    });
  });

  group('probeHeicStereoPair on synthetic files', () {
    Future<HeicStereoPair?> probe(Uint8List bytes) => probeHeicStereoPair(RecordingReader(bytes).call);

    test('a pair as Apple writes it', () async {
      final pair = await probe(spatialPhotoBuilder().build());

      expect(pair?.leftItemId, 10);
      expect(pair?.rightItemId, 20);
      expect(pair?.primaryItemId, 10);
      expect(pair?.width, 3072);
      expect(pair?.disparityAdjustment, -1000);
      expect(pair?.horizontalFovDegrees, closeTo(59.98, 0.01));
    });

    test('no grpl gives null', () async {
      final builder = spatialPhotoBuilder();
      final bytes = HeifBuilder(
        items: builder.items,
        properties: builder.properties,
        primaryItemId: builder.primaryItemId,
      ).build();

      expect(await probe(bytes), isNull);
    });

    test('a ster group with one entity gives null', () async {
      final builder = spatialPhotoBuilder();
      final bytes = HeifBuilder(
        items: builder.items,
        properties: builder.properties,
        groups: const [
          HeifGroup('ster', 30, [10]),
        ],
        primaryItemId: 10,
      ).build();

      expect(await probe(bytes), isNull);
    });

    test('a ster group pointing at a hidden tile is still a pair: hidden does not matter', () async {
      final bytes = HeifBuilder(
        items: const [
          HeifItem(1, 'hvc1', hidden: true, properties: [1]),
          HeifItem(2, 'hvc1', hidden: true, properties: [1]),
        ],
        properties: [heifIspe(512, 512)],
        groups: const [
          HeifGroup('ster', 3, [1, 2]),
        ],
      ).build();

      final pair = await probe(bytes);
      expect(pair?.leftItemId, 1);
      expect(pair?.rightItemId, 2);
      expect(pair?.width, 512);
      expect(pair?.disparityAdjustment, isNull);
      expect(pair?.horizontalFovDegrees, isNull);
    });

    test('a pitm of version 1 has a 4 byte id at the right offset', () async {
      final builder = spatialPhotoBuilder(pitmVersion: 1);
      final bytes = builder.build();

      final pair = await probe(bytes);
      expect(pair?.pitmIdBytes, 4);
      expect(pair?.pitmIdOffset, builder.pitmIdOffset);
      expect(ByteData.sublistView(bytes).getUint32(pair!.pitmIdOffset), 10);
    });

    test('a pitm of version 0 has a 2 byte id at the right offset', () async {
      final builder = spatialPhotoBuilder();
      final bytes = builder.build();

      final pair = await probe(bytes);
      expect(pair?.pitmIdBytes, 2);
      expect(pair?.pitmIdOffset, builder.pitmIdOffset);
      expect(ByteData.sublistView(bytes).getUint16(pair!.pitmIdOffset), 10);
    });

    test('reads iinf and infe of both versions and ipma of both versions and widths', () async {
      for (final (iinf, infe, ipma, flags) in [(0, 2, 0, 0), (1, 3, 1, 1), (0, 3, 0, 1), (1, 2, 1, 0)]) {
        final pair = await probe(
          spatialPhotoBuilder(iinfVersion: iinf, infeVersion: infe, ipmaVersion: ipma, ipmaFlags: flags).build(),
        );

        final reason = 'iinf $iinf, infe $infe, ipma $ipma flags $flags';
        expect(pair?.leftItemId, 10, reason: reason);
        expect(pair?.rightItemId, 20, reason: reason);
        expect(pair?.width, 3072, reason: reason);
        expect(pair?.disparityAdjustment, -1000, reason: reason);
      }
    });

    test('a meta box past 64 KiB is read once more, exactly its range', () async {
      final builder = spatialPhotoBuilder(metaPadding: 80 * 1024);
      final bytes = builder.build();
      final reader = RecordingReader(bytes);

      final pair = await probeHeicStereoPair(reader.call);
      expect(pair?.rightItemId, 20);
      expect(reader.reads, [(0, heicStereoHeadLength), (builder.metaOffset, builder.metaLength)]);
    });

    test('a meta box longer than allowed gives null', () async {
      final bytes = spatialPhotoBuilder(metaPadding: 80 * 1024).build();

      expect(await probeHeicStereoPair(RecordingReader(bytes).call, maxMetaLength: 64 * 1024), isNull);
    });

    test('a meta box after a large box is found by its header', () async {
      final builder = spatialPhotoBuilder();
      final bytes = HeifBuilder(
        items: builder.items,
        properties: builder.properties,
        groups: builder.groups,
        primaryItemId: 10,
        leadingBoxes: [heifBox('free', List.filled(70 * 1024, 0))],
      ).build();

      final pair = await probe(bytes);
      expect(pair?.rightItemId, 20);
      expect(ByteData.sublistView(bytes).getUint16(pair!.pitmIdOffset), 10);
    });

    test('a meta box with a 64 bit size', () async {
      final builder = spatialPhotoBuilder(largeMetaSize: true);
      final bytes = builder.build();

      final pair = await probe(bytes);
      expect(pair?.rightItemId, 20);
      expect(pair?.pitmIdOffset, builder.pitmIdOffset);
      expect(ByteData.sublistView(bytes).getUint16(pair!.pitmIdOffset), 10);
    });

    test('an altr group stands for its first picture, a gain map skipped', () async {
      final bytes = HeifBuilder(
        items: const [
          HeifItem(1, 'grid', properties: [1]),
          HeifItem(2, 'tmap', properties: [1]),
          HeifItem(3, 'grid', properties: [1]),
        ],
        properties: [heifIspe(4032, 3024)],
        groups: const [
          HeifGroup('altr', 40, [2, 3]),
          HeifGroup('ster', 41, [1, 40]),
        ],
      ).build();

      final pair = await probe(bytes);
      expect(pair?.leftItemId, 1);
      expect(pair?.rightItemId, 3);
      expect(pair?.width, 4032);
      expect(pair?.height, 3024);
    });

    test('a disparity out of range gives no disparity', () async {
      final pair = await probe(spatialPhotoBuilder(disparity: 20000).build());

      expect(pair, isNotNull);
      expect(pair!.disparityAdjustment, isNull);
    });

    test('the disparity of the left eye stands when the group has none', () async {
      final builder = spatialPhotoBuilder(disparity: 250);
      final bytes = HeifBuilder(
        items: builder.items,
        properties: builder.properties,
        groups: const [
          HeifGroup('ster', 30, [10, 20]),
        ],
        primaryItemId: 10,
      ).build();

      expect((await probe(bytes))?.disparityAdjustment, 250);
    });

    test('the rotation of the left eye', () async {
      expect((await probe(spatialPhotoBuilder(rotation: 3).build()))?.rotation, 3);
    });

    test('eye properties it does not know are listed for the logs', () async {
      final pair = await probe(
        spatialPhotoBuilder(
          extraEyeProperties: [
            heifBox('abcd', [1, 2]),
            heifUuidBox('00112233-4455-6677-8899-aabbccddeeff', [0]),
          ],
        ).build(),
      );

      expect(pair?.unknownProperties, ['abcd', '00112233-4455-6677-8899-aabbccddeeff']);
    });

    test('an eye without ispe gives null', () async {
      final bytes = HeifBuilder(
        items: const [
          HeifItem(1, 'hvc1', properties: [1]),
          HeifItem(2, 'hvc1', properties: [1]),
        ],
        properties: [heifIrot(0)],
        groups: const [
          HeifGroup('ster', 3, [1, 2]),
        ],
      ).build();

      expect(await probe(bytes), isNull);
    });

    test('an eye that is no picture gives null', () async {
      final bytes = HeifBuilder(
        items: const [
          HeifItem(1, 'hvc1', properties: [1]),
          HeifItem(2, 'Exif', properties: [1]),
        ],
        properties: [heifIspe(512, 512)],
        groups: const [
          HeifGroup('ster', 3, [1, 2]),
        ],
      ).build();

      expect(await probe(bytes), isNull);
    });

    test('a file that is no HEIF gives null', () async {
      final mp4 = HeifBuilder(
        items: spatialPhotoBuilder().items,
        properties: spatialPhotoBuilder().properties,
        groups: spatialPhotoBuilder().groups,
        majorBrand: 'isom',
        compatibleBrands: const ['isom', 'mp42'],
      ).build();

      expect(await probe(mp4), isNull);
      expect(await probe(Uint8List.fromList([0xff, 0xd8, 0xff, 0xe1, 0, 16, ...List.filled(64, 0)])), isNull);
      expect(await probe(Uint8List(0)), isNull);
    });

    test('a truncated meta box gives null, it never throws', () async {
      final builder = spatialPhotoBuilder();
      final bytes = builder.build();
      final metaEnd = builder.metaOffset + builder.metaLength;
      for (var length = 0; length < metaEnd; length += 7) {
        expect(await probe(Uint8List.sublistView(bytes, 0, length)), isNull, reason: 'cut at $length');
      }
      // A meta box past the head, cut by the end of the file
      final long = spatialPhotoBuilder(metaPadding: 80 * 1024);
      final longBytes = long.build();
      expect(await probe(Uint8List.sublistView(longBytes, 0, long.metaOffset + long.metaLength - 10)), isNull);
    });

    test('damaged sizes inside the meta box never throw', () async {
      final bytes = spatialPhotoBuilder().build();
      for (var offset = 40; offset < 200; offset++) {
        final damaged = Uint8List.fromList(bytes)..[offset] = 0xff;
        await expectLater(probe(damaged), completes, reason: 'byte $offset');
      }
    });
  });

  group('HeicStereoPair.fromImmersiveMap', () {
    test('ignores another kind or version', () {
      expect(HeicStereoPair.fromImmersiveMap({'kind': 'other', 'version': 1}), isNull);
      expect(HeicStereoPair.fromImmersiveMap({'kind': 'heicStereoPair', 'version': 2}), isNull);
      expect(HeicStereoPair.fromImmersiveMap('not a map'), isNull);
    });

    test('leaves out the unknown fields', () {
      const pair = HeicStereoPair(
        primaryItemId: 1,
        leftItemId: 1,
        rightItemId: 2,
        pitmIdOffset: 100,
        pitmIdBytes: 2,
        width: 10,
        height: 20,
      );

      final map = pair.toImmersiveMap();
      expect(map.containsKey('disparityAdjustment'), isFalse);
      expect(map.containsKey('horizontalFovDeg'), isFalse);
      expect(HeicStereoPair.fromImmersiveMap(map), pair);
    });
  });
}
