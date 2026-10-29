// The versions of a photo of a share, found among its neighbours by the name, the SourceName and the SourceSize of
// their XMP (design-final 2026-10-26, sections 3.8 and 4.2), each kind kept by its probe (design-final 2026-10-27,
// section 8.4, point 5).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/derived_file_rule.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/ai_immersive/share_versions.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

import 'stereo_photo_fixtures.dart';

void main() {
  const originalSize = 4182311;

  NetworkEntry file(String path, {int size = 1000, DateTime? modified}) => NetworkEntry(
    sourceId: 'nas',
    path: path,
    isDirectory: false,
    size: size,
    modified: modified ?? DateTime.utc(2026, 10, 27),
  );

  final original = file('/Photos/salon.jpg', size: originalSize);

  late Map<String, Uint8List> files;
  late List<String> reads;

  setUp(() {
    files = {};
    reads = [];
  });

  ByteRangeReader readerOf(NetworkEntry entry) => (offset, length) async {
    reads.add(entry.path);
    final bytes = files[entry.path];
    if (bytes == null) {
      throw StateError('${entry.path} cannot be read');
    }
    return Uint8List.sublistView(bytes, offset, (offset + length).clamp(0, bytes.length));
  };

  /// One of ours, made from [sourceName] of [sourceSize] bytes
  Uint8List version({String sourceName = 'salon.jpg', int sourceSize = originalSize}) => jpegFile(
    width: 8000,
    height: 3000,
    xmp: ourXmp(sourceName: sourceName, sourceSize: sourceSize),
  );

  test('finds the version a computer saved next to the original, and how to show it', () async {
    files['/Photos/salon_3D_LRF_Full_SBS.jpg'] = version();
    final neighbours = [original, file('/Photos/cuisine.jpg'), file('/Photos/salon_3D_LRF_Full_SBS.jpg')];

    final versions = await findShareVersions(original, neighbours, readerOf: readerOf);

    expect(versions.map((v) => v.entry.path), ['/Photos/salon_3D_LRF_Full_SBS.jpg']);
    expect(versions.single.kind, ImmersiveKind.stereoPhoto);
    final photo = versions.single.photo!;
    expect(photo.isEstimatedRelief, isTrue);
    expect(photo.request?.toJson(), {
      'kind': 'sbsPhoto',
      'version': 1,
      'layout': 'leftRight',
      'eyes': 'full',
      'origin': 'estimatedDepth',
      'leftEye': 'original',
    });
    expect(reads, ['/Photos/salon_3D_LRF_Full_SBS.jpg'], reason: 'the other neighbours are not read');
  });

  test('takes neither a version of another original nor one whose size differs', () async {
    files['/Photos/salon_3D_LRF_Full_SBS.jpg'] = version(sourceSize: originalSize + 1);
    files['/Photos/salon_3D_LRF_Full_SBS (1).jpg'] = version(sourceName: 'salon2.jpg');
    files['/Photos/salon2_3D_LRF_Full_SBS.jpg'] = version(sourceName: 'salon2.jpg');
    final neighbours = [
      original,
      file('/Photos/salon2.jpg', size: originalSize),
      for (final path in files.keys) file(path),
    ];

    expect(await findShareVersions(original, neighbours, readerOf: readerOf), isEmpty);
    expect(reads, isNot(contains('/Photos/salon2_3D_LRF_Full_SBS.jpg')), reason: 'its name is not one of salon.jpg');
  });

  test('a side by side file of another tool under the same name is no version', () async {
    files['/Photos/salon_3D_LRF_Full_SBS.png'] = pngFile(width: 8000, height: 3000);

    final versions = await findShareVersions(original, [
      original,
      file('/Photos/salon_3D_LRF_Full_SBS.png'),
    ], readerOf: readerOf);

    expect(versions, isEmpty);
  });

  test('a file beside a version that copies its XMP, a sidecar, is no version: only pictures are', () async {
    // digiKam writes salon_3D_LRF_Full_SBS.jpg.xmp, with our XMP kept, after the version
    files['/Photos/salon_3D_LRF_Full_SBS.jpg'] = version();
    files['/Photos/salon_3D_LRF_Full_SBS.jpg.xmp'] = Uint8List.fromList(utf8.encode(ourXmp().toXml()));
    final neighbours = [
      original,
      file('/Photos/salon_3D_LRF_Full_SBS.jpg', modified: DateTime.utc(2026, 10, 27, 10)),
      file('/Photos/salon_3D_LRF_Full_SBS.jpg.xmp', modified: DateTime.utc(2026, 10, 27, 11)),
    ];

    final versions = await findShareVersions(original, neighbours, readerOf: readerOf);

    expect(versions.map((v) => v.entry.name), ['salon_3D_LRF_Full_SBS.jpg']);
    expect(reads, isNot(contains('/Photos/salon_3D_LRF_Full_SBS.jpg.xmp')));
  });

  test('reads eight neighbours at most, 128 KiB each', () async {
    final lengths = <int>[];
    final names = [for (var i = 1; i <= maxDerivedCandidates + 2; i++) '/Photos/salon_3D_LRF_Full_SBS ($i).jpg'];
    for (final name in names) {
      files[name] = version();
    }

    final versions = await findShareVersions(
      original,
      [original, for (final name in names) file(name)],
      readerOf: (entry) => (offset, length) {
        lengths.add(length);
        return readerOf(entry)(offset, length);
      },
    );

    expect(reads, names.take(maxDerivedCandidates));
    expect(versions, hasLength(maxDerivedCandidates));
    expect(maxDerivedCandidates, 8);
    expect(lengths, everyElement(shareVersionHeadLength));
    expect(shareVersionHeadLength, 128 * 1024);
  });

  test('with more versions than it reads, reads the newest: the cap comes after the order by date', () async {
    // Listed in the order of the names, where the plain name comes after (1) to (8): it is the newest
    const cap = maxDerivedCandidates;
    final names = [for (var i = 1; i <= cap; i++) 'salon_3D_LRF_Full_SBS ($i).jpg', 'salon_3D_LRF_Full_SBS.jpg'];
    for (final name in names) {
      files['/Photos/$name'] = version();
    }
    final neighbours = [
      original,
      for (var i = 0; i < cap; i++) file('/Photos/${names[i]}', modified: DateTime.utc(2026, 10, i + 1)),
      file('/Photos/${names[cap]}', modified: DateTime.utc(2026, 10, 27)),
    ];

    final versions = await findShareVersions(original, neighbours, readerOf: readerOf);

    expect(versions.first.entry.name, 'salon_3D_LRF_Full_SBS.jpg');
    expect(versions, hasLength(cap));
    expect(reads, isNot(contains('/Photos/salon_3D_LRF_Full_SBS (1).jpg')), reason: 'the oldest is the one left');
  });

  test('looks in the folder of the original only', () async {
    files['/Other/salon_3D_LRF_Full_SBS.jpg'] = version();

    expect(
      await findShareVersions(original, [original, file('/Other/salon_3D_LRF_Full_SBS.jpg')], readerOf: readerOf),
      isEmpty,
    );
    expect(reads, isEmpty);
  });

  test('skips a neighbour that cannot be read, keeps the others, the newest first', () async {
    files['/Photos/salon_3D_LRF_Full_SBS (1).jpg'] = version();
    files['/Photos/salon_3D_LRF_Full_SBS (2).jpg'] = version();
    final neighbours = [
      original,
      file('/Photos/salon_3D_LRF_Full_SBS.jpg'),
      file('/Photos/salon_3D_LRF_Full_SBS (1).jpg', modified: DateTime.utc(2026, 10, 1)),
      file('/Photos/salon_3D_LRF_Full_SBS (2).jpg', modified: DateTime.utc(2026, 10, 20)),
    ];

    final versions = await findShareVersions(original, neighbours, readerOf: readerOf);

    expect(reads, hasLength(3));
    expect(versions.map((v) => v.entry.name), ['salon_3D_LRF_Full_SBS (2).jpg', 'salon_3D_LRF_Full_SBS (1).jpg']);
  });

  test('reads nothing in a folder of ordinary photos, nor for an original of unknown size', () async {
    final neighbours = [original, file('/Photos/cuisine.jpg'), file('/Photos/salon2.jpg')];
    expect(await findShareVersions(original, neighbours, readerOf: readerOf), isEmpty);

    files['/Photos/salon_3D_LRF_Full_SBS.jpg'] = version();
    const unsized = NetworkEntry(sourceId: 'nas', path: '/Photos/salon.jpg', isDirectory: false);
    expect(
      await findShareVersions(unsized, [unsized, file('/Photos/salon_3D_LRF_Full_SBS.jpg')], readerOf: readerOf),
      isEmpty,
    );
    expect(reads, isEmpty);
  });

  test('a version in half width, eyes swapped, says so to the viewer', () async {
    files['/Photos/salon_3D_LRF_Full_SBS.jpg'] = jpegFile(
      width: 4000,
      height: 3000,
      xmp: ourXmp(eyes: StereoEyes.half, eyeOrder: EyeOrder.rightLeft),
    );

    final versions = await findShareVersions(original, [
      original,
      file('/Photos/salon_3D_LRF_Full_SBS.jpg'),
    ], readerOf: readerOf);

    expect(versions.single.photo!.request?.toJson()['eyes'], 'half');
    expect(versions.single.photo!.request?.toJson()['layout'], 'rightLeft');
  });

  group('of every kind', () {
    String sample(String name) => File('test/fixtures/ai_immersive/xmp_v1_${name}_sample.xmp').readAsStringSync();

    test('finds a 3D scene, a panorama and its 3D version beside the original, each kept by its probe', () async {
      files['/Photos/salon_3D_LRF_Full_SBS.jpg'] = version();
      files['/Photos/salon_scene3D.jpg'] = jpegFile(width: 2048, height: 1536, xmpText: sample('scene'));
      files['/Photos/salon_360.jpg'] = jpegFile(width: 8192, height: 4096, xmpText: sample('panorama'));
      files['/Photos/salon_360_3D.jpg'] = jpegFile(width: 4096, height: 4096, xmpText: sample('stereo_panorama'));
      final neighbours = [
        original,
        file('/Photos/cuisine.jpg'),
        for (final (index, path) in files.keys.indexed) file(path, modified: DateTime.utc(2026, 10, 20 + index)),
      ];

      final versions = await findShareVersions(original, neighbours, readerOf: readerOf);

      expect(versions.map((v) => (v.entry.name, v.kind)), [
        ('salon_360_3D.jpg', ImmersiveKind.stereoPanorama360),
        ('salon_360.jpg', ImmersiveKind.panorama360),
        ('salon_scene3D.jpg', ImmersiveKind.volumetricScene),
        ('salon_3D_LRF_Full_SBS.jpg', ImmersiveKind.stereoPhoto),
      ]);
      // Each with its packet as its kind reads it; only the 3D photo is two eyes side by side
      final byKind = {for (final v in versions) v.kind: v};
      expect(byKind[ImmersiveKind.volumetricScene]!.xmp, ImmersiveXmp.parse(sample('scene')));
      expect((byKind[ImmersiveKind.volumetricScene]!.xmp as SceneXmp).request, isNotNull);
      expect(byKind[ImmersiveKind.panorama360]!.xmp, isA<PanoramaXmp>());
      expect(byKind[ImmersiveKind.stereoPanorama360]!.xmp, isA<StereoPanoramaXmp>());
      expect(versions.where((v) => v.photo != null).map((v) => v.entry.name), ['salon_3D_LRF_Full_SBS.jpg']);
      expect(reads, isNot(contains('/Photos/cuisine.jpg')));
    });

    test('the 3D version of a 360° photo whose name says pano is "_3D" after its name', () async {
      final pano = file('/Photos/PANO_0001.jpg', size: originalSize);
      files['/Photos/PANO_0001_3D.jpg'] = jpegFile(
        width: 4096,
        height: 4096,
        xmpText: sample('stereo_panorama').replaceFirst('SourceName="salon.jpg"', 'SourceName="PANO_0001.jpg"'),
      );

      final versions = await findShareVersions(pano, [pano, file('/Photos/PANO_0001_3D.jpg')], readerOf: readerOf);

      expect(versions.map((v) => (v.entry.name, v.kind)), [('PANO_0001_3D.jpg', ImmersiveKind.stereoPanorama360)]);
    });

    test('a panorama the 360° rules do not take, and a 3D panorama not stacked, are not kept', () async {
      final withoutGPano = sample('panorama').replaceAll(RegExp(r'\s*GPano:ProjectionType="[^"]*"'), '');
      files['/Photos/salon_360.jpg'] = jpegFile(width: 8192, height: 4096, xmpText: withoutGPano);
      files['/Photos/salon_360_3D.jpg'] = jpegFile(width: 8192, height: 4096, xmpText: sample('stereo_panorama'));
      final neighbours = [original, for (final path in files.keys) file(path)];

      expect(await findShareVersions(original, neighbours, readerOf: readerOf), isEmpty);
      expect(reads, hasLength(2), reason: 'both read, neither recognised');
    });

    test('a scene of another original, or of a newer format, by the rule and as the viewer needs it', () async {
      files['/Photos/salon_scene3D.jpg'] = jpegFile(
        width: 2048,
        height: 1536,
        xmpText: sample('scene').replaceFirst('SourceSize="4182311"', 'SourceSize="12"'),
      );
      files['/Photos/salon_scene3D (1).jpg'] = jpegFile(
        width: 2048,
        height: 1536,
        xmpText: sample('scene').replaceFirst('Immuch360:FormatVersion="1"', 'Immuch360:FormatVersion="2"'),
      );
      final neighbours = [original, for (final path in files.keys) file(path)];

      final versions = await findShareVersions(original, neighbours, readerOf: readerOf);

      // Kept, so that the viewer can say it was made by a newer version
      expect(versions.map((v) => v.entry.name), ['salon_scene3D (1).jpg']);
      expect((versions.single.xmp as SceneXmp).request, isNull);
    });
  });

  test('the folder of a share path', () {
    expect(shareFolderOf('/Photos/2026/salon.jpg'), '/Photos/2026');
    expect(shareFolderOf('/salon.jpg'), '/');
  });
}
