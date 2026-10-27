// The versions of a photo of the folder library and the original of a version, as the details of the viewer list
// them (design-final 2026-10-26, section 4.2): found by the sum of the original in every folder, still linked once
// moved, gone with the scan that sees them deleted, greyed on a drive that is not connected, and by the folder and the
// name when the sum of the original is not known yet.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/library/versions.provider.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/desktop/library/placeholder_check.dart';
import 'package:immich_mobile/domain/models/ai_immersive/derived_file_rule.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:path/path.dart' as p;

import '../../library/library_fixtures.dart';
import '../../library/library_test_support.dart';
import '../fakes/fake_immersive_engine.dart';
import 'version_fixtures.dart';

void main() {
  late TestLibrary fixture;
  late Uint8List original;
  late String photos;
  late String photosRoot;

  setUp(() {
    fixture = TestLibrary();
    fixture.probe.mounts[fixture.files.path] = 'win-0000beef';
    original = jpegBytes(width: 40, height: 30);
    photos = p.join(fixture.files.path, 'Photos');
    fixture
      ..write('Photos/salon.jpg', original)
      ..write('Photos/salon_3D_LRF_Full_SBS.jpg', fakeSbsJpeg(xmp: versionXmp(original)))
      // A second version, with other settings, in another folder of the library
      ..write('Photos/3D/salon_3D_LRF_Full_SBS (1).jpg', fakeSbsJpeg(xmp: versionXmp(original, quarterTurns: 1)))
      // Close names, and the version of another photo: none of them is a version of salon.jpg
      ..write('Photos/salon2.jpg', jpegBytes(width: 41, height: 30))
      ..write(
        'Photos/salon2_3D_LRF_Full_SBS.jpg',
        fakeSbsJpeg(xmp: versionXmp(jpegBytes(width: 4, height: 3), name: 'salon2.jpg')),
      )
      // Another tool's side by side photo
      ..write('Photos/salon_LRF_Full_SBS.jpg', jpegBytes(width: 80, height: 30));
    photosRoot = fixture.library().addRoot(photos).id;
  });
  tearDown(() => fixture.dispose());

  String idOf(String relative, {String? root}) => fixture.ids.file(root ?? photosRoot, relative);

  /// The sum of the file [relative], as the hashing of the backup keeps it in the index
  void hash(String relative, List<int> bytes) {
    final index = fixture.index();
    final file = index.file(idOf(relative))!;
    index.storeChecksums([(id: file.id, checksum: sha1Base64(bytes), size: file.size, modifiedMs: file.modifiedMs)]);
  }

  PhotoVersionsFinder finder({List<String>? reads}) => PhotoVersionsFinder(
    fixture.library(),
    readHead: (path) {
      reads?.add(p.basename(path));
      return readFileHead(path);
    },
  );

  group('the versions of an original', () {
    test('are found by its sum in every folder of the library, and say what they are', () async {
      await fixture.scan();
      hash('salon.jpg', original);
      final reads = <String>[];

      final found = await finder(reads: reads).find(idOf('salon.jpg'));

      expect(found.isVersion, isFalse);
      expect(found.versions.map((version) => version.path), [
        p.join(photos, '3D', 'salon_3D_LRF_Full_SBS (1).jpg'),
        p.join(photos, 'salon_3D_LRF_Full_SBS.jpg'),
      ]);
      expect(found.versions.every((version) => version.isEstimatedRelief && version.available), isTrue);
      expect(found.versions.first.asset.id, idOf('3D/salon_3D_LRF_Full_SBS (1).jpg'));
      expect(found.versions.first.asset.isImage, isTrue);
      // The index knows them: no file is read
      expect(reads, isEmpty);
    });

    test('are found by the sum the local tables give when the index has none', () async {
      await fixture.scan();

      final found = await finder().find(idOf('salon.jpg'), checksum: sha1Base64(original));

      expect(found.versions, hasLength(2));
    });

    test('a version moved to another folder, renamed, stays linked', () async {
      await fixture.scan();
      hash('salon.jpg', original);
      final moved = Directory(p.join(photos, 'Elsewhere'))..createSync();
      File(p.join(photos, 'salon_3D_LRF_Full_SBS.jpg')).renameSync(p.join(moved.path, 'living room 3D.jpg'));
      await fixture.scan();

      final found = await finder().find(idOf('salon.jpg'));

      expect(
        found.versions.map((version) => version.path),
        containsAll([
          p.join(photos, 'Elsewhere', 'living room 3D.jpg'),
          p.join(photos, '3D', 'salon_3D_LRF_Full_SBS (1).jpg'),
        ]),
      );
      expect(found.versions, hasLength(2));
    });

    test('a version deleted leaves the list with the scan that sees it gone', () async {
      await fixture.scan();
      hash('salon.jpg', original);
      File(p.join(photos, '3D', 'salon_3D_LRF_Full_SBS (1).jpg')).deleteSync();

      // Until the next scan, the index still has it
      expect((await finder().find(idOf('salon.jpg'))).versions, hasLength(2));
      await fixture.scan();

      final found = await finder().find(idOf('salon.jpg'));
      expect(found.versions.map((version) => version.name), ['salon_3D_LRF_Full_SBS.jpg']);
    });

    test('a version on a drive that is not connected is listed, greyed, after those that can be opened', () async {
      final drive = Directory(p.join(fixture.dir.path, 'E'))..createSync();
      fixture.probe.mounts[drive.path] = 'win-1a2b3c4d';
      fixture.write('Backup/salon_3D_LRF_Full_SBS.jpg', fakeSbsJpeg(xmp: versionXmp(original)), base: drive);
      final driveRoot = fixture.library().addRoot(p.join(drive.path, 'Backup')).id;
      await fixture.scan();
      hash('salon.jpg', original);
      drive.renameSync(p.join(fixture.dir.path, 'unplugged'));
      fixture.probe.mounts.remove(drive.path);
      await fixture.scan();

      final found = await finder().find(idOf('salon.jpg'));

      expect(found.versions, hasLength(3));
      final unplugged = found.versions.last;
      expect(unplugged.asset.id, fixture.ids.file(driveRoot, 'salon_3D_LRF_Full_SBS.jpg'));
      expect((unplugged.available, unplugged.isEstimatedRelief), (false, true));
      expect(found.versions.take(2).every((version) => version.available), isTrue);
    });

    test('without the sum of the original, those of its folder named after it whose XMP names it', () async {
      // A third and a fourth version beside it, one made from another salon.jpg of the same name but another size
      fixture
        ..write('Photos/salon_3D_LRF_Full_SBS (2).jpg', fakeSbsJpeg(xmp: versionXmp(original, quarterTurns: 2)))
        ..write('Photos/salon_3D_LRF_Full_SBS (3).jpg', fakeSbsJpeg(xmp: versionXmp([...original, 0])));
      await fixture.scan();
      final reads = <String>[];

      final found = await finder(reads: reads).find(idOf('salon.jpg'));

      // The one in 3D/ needs the sum; the close names are never read
      expect(found.versions.map((version) => version.name), [
        'salon_3D_LRF_Full_SBS (2).jpg',
        'salon_3D_LRF_Full_SBS.jpg',
      ]);
      expect(
        reads,
        unorderedEquals([
          'salon_3D_LRF_Full_SBS (2).jpg',
          'salon_3D_LRF_Full_SBS (3).jpg',
          'salon_3D_LRF_Full_SBS.jpg',
        ]),
      );
    });

    test('of every kind are found by its sum, each with its kind, wherever it is', () async {
      final panorama = panoramaVersionXmp(original);
      fixture
        ..write('Photos/salon_scene3D.jpg', versionFileOf(sceneVersionXmp(original)))
        ..write('Photos/Panoramas/salon_360.jpg', versionFileOf(panorama))
        ..write(
          'Photos/Panoramas/salon_360_3D.jpg',
          versionFileOf(stereoPanoramaVersionXmp(original, parent: panorama)),
        );
      await fixture.scan();
      hash('salon.jpg', original);
      final reads = <String>[];

      final found = await finder(reads: reads).find(idOf('salon.jpg'));

      expect(
        {for (final version in found.versions) version.name: (version.kind, version.origin)},
        {
          'salon_3D_LRF_Full_SBS.jpg': (ImmersiveKind.stereoPhoto, IndexedOrigin.estimated),
          'salon_3D_LRF_Full_SBS (1).jpg': (ImmersiveKind.stereoPhoto, IndexedOrigin.estimated),
          'salon_scene3D.jpg': (ImmersiveKind.volumetricScene, IndexedOrigin.reconstructed),
          'salon_360.jpg': (ImmersiveKind.panorama360, IndexedOrigin.generated),
          'salon_360_3D.jpg': (ImmersiveKind.stereoPanorama360, IndexedOrigin.generated),
        },
      );
      expect(reads, isEmpty);
    });

    test('without the sum, those beside it named with the suffix of each kind whose XMP names it', () async {
      final panorama = panoramaVersionXmp(original);
      fixture
        ..write('Photos/salon_scene3D.jpg', versionFileOf(sceneVersionXmp(original)))
        ..write('Photos/salon_360.jpg', versionFileOf(panorama))
        ..write('Photos/salon_360_3D.jpg', versionFileOf(stereoPanoramaVersionXmp(original, parent: panorama)))
        // A version of another photo of the same name and another size, and a close name that costs no read
        ..write('Photos/salon_scene3D (1).jpg', versionFileOf(sceneVersionXmp([...original, 0])))
        ..write('Photos/salon_3600.jpg', versionFileOf(panoramaVersionXmp(original)));
      await fixture.scan();
      final reads = <String>[];

      final found = await finder(reads: reads).find(idOf('salon.jpg'));

      expect(
        {for (final version in found.versions) version.name: version.kind},
        {
          'salon_3D_LRF_Full_SBS.jpg': ImmersiveKind.stereoPhoto,
          'salon_scene3D.jpg': ImmersiveKind.volumetricScene,
          'salon_360.jpg': ImmersiveKind.panorama360,
          'salon_360_3D.jpg': ImmersiveKind.stereoPanorama360,
        },
      );
      expect(reads, isNot(contains('salon_3600.jpg')));
      expect(reads, contains('salon_scene3D (1).jpg'));
    });

    test('without the sum, eight neighbours at most are read', () async {
      for (var i = 1; i <= maxDerivedCandidates + 2; i++) {
        fixture.write('Photos/salon_3D_LRF_Full_SBS ($i).jpg', fakeSbsJpeg(xmp: versionXmp(original)));
      }
      File(p.join(photos, '3D', 'salon_3D_LRF_Full_SBS (1).jpg')).deleteSync();
      await fixture.scan();
      final reads = <String>[];

      final found = await finder(reads: reads).find(idOf('salon.jpg'));

      expect(reads, hasLength(maxDerivedCandidates));
      expect(found.versions, hasLength(maxDerivedCandidates));
    });

    test('an original changed after it was hashed no longer lists the versions of its old sum', () async {
      await fixture.scan();
      hash('salon.jpg', original);
      expect((await finder().find(idOf('salon.jpg'))).versions, hasLength(2));

      // Retouched: the index keeps the old sum, which no longer says what the file is
      fixture.write('Photos/salon.jpg', [...jpegBytes(width: 64, height: 48), 0]);
      await fixture.scan();

      expect((await finder().find(idOf('salon.jpg'))).versions, isEmpty);
    });

    test('a photo without versions, a video and a file the library does not have show nothing', () async {
      fixture.write('Photos/clip.mp4', [0, 0, 0, 0]);
      await fixture.scan();
      hash('salon2.jpg', jpegBytes(width: 41, height: 30));

      expect((await finder().find(idOf('salon2.jpg'))).versions, isEmpty);
      expect((await finder().find(idOf('salon_LRF_Full_SBS.jpg'))).isVersion, isFalse);
      expect((await finder().find(idOf('clip.mp4'))).versions, isEmpty);
      expect((await finder().find('f0000')).versions, isEmpty);
    });
  });

  group('the original of a version', () {
    test('is found by its sum, wherever it is, and the version says what it is', () async {
      final moved = Directory(p.join(photos, 'Originals'))..createSync();
      await fixture.scan();
      File(p.join(photos, 'salon.jpg')).renameSync(p.join(moved.path, 'salon.jpg'));
      await fixture.scan();
      hash('Originals/salon.jpg', original);
      final reads = <String>[];

      final found = await finder(reads: reads).find(idOf('3D/salon_3D_LRF_Full_SBS (1).jpg'));

      expect(found.isVersion, isTrue);
      expect(found.self!.isEstimatedRelief, isTrue);
      expect(found.original!.path, p.join(photos, 'Originals', 'salon.jpg'));
      expect(found.original!.available, isTrue);
      expect(reads, isEmpty);
    });

    test('of a scene or a panorama is found the same way, and the version says what it is', () async {
      fixture
        ..write('Photos/salon_scene3D.jpg', versionFileOf(sceneVersionXmp(original)))
        ..write('Photos/Panoramas/salon_360.jpg', versionFileOf(panoramaVersionXmp(original)));
      await fixture.scan();

      final scene = await finder().find(idOf('salon_scene3D.jpg'));
      expect((scene.self!.kind, scene.self!.origin), (ImmersiveKind.volumetricScene, IndexedOrigin.reconstructed));
      expect(scene.original!.name, 'salon.jpg', reason: 'beside it: by the name and the size its XMP gives');

      final away = await finder().find(idOf('Panoramas/salon_360.jpg'));
      expect(
        (away.self!.kind, away.original),
        (ImmersiveKind.panorama360, null),
        reason: 'away from it: the sum is needed',
      );
      hash('salon.jpg', original);
      expect((await finder().find(idOf('Panoramas/salon_360.jpg'))).original!.name, 'salon.jpg');
    });

    test('is found by the name and the size its XMP gives, in its folder, when its sum is not known', () async {
      await fixture.scan();

      final found = await finder().find(idOf('salon_3D_LRF_Full_SBS.jpg'));

      expect(found.original!.name, 'salon.jpg');
      expect(found.original!.asset.id, idOf('salon.jpg'));
      // Not beside it: the sum is needed
      expect((await finder().find(idOf('3D/salon_3D_LRF_Full_SBS (1).jpg'))).original, isNull);
    });

    test('is not found once changed, deleted, or when another file took its name', () async {
      await fixture.scan();
      // Another photo under its name, of the same size: by the name and the size alone it passes for the original, as
      // the rule says; once hashed, the sums tell them apart
      final sameSize = jpegBytes(width: 41, height: 30);
      expect(sameSize.length, original.length);
      fixture.write('Photos/salon.jpg', sameSize);
      await fixture.scan();
      expect((await finder().find(idOf('salon_3D_LRF_Full_SBS.jpg'))).original?.name, 'salon.jpg');
      hash('salon.jpg', sameSize);
      expect((await finder().find(idOf('salon_3D_LRF_Full_SBS.jpg'))).original, isNull);

      // Of another size, it is never taken for the original
      fixture.write('Photos/salon.jpg', [...jpegBytes(width: 64, height: 48), 0]);
      await fixture.scan();
      expect((await finder().find(idOf('salon_3D_LRF_Full_SBS.jpg'))).original, isNull);

      File(p.join(photos, 'salon.jpg')).deleteSync();
      await fixture.scan();
      final found = await finder().find(idOf('salon_3D_LRF_Full_SBS.jpg'));
      expect((found.isVersion, found.original), (true, null));
    });

    test('is not found by a sum its original no longer has', () async {
      await fixture.scan();
      hash('salon.jpg', original);
      expect((await finder().find(idOf('3D/salon_3D_LRF_Full_SBS (1).jpg'))).original?.name, 'salon.jpg');

      fixture.write('Photos/salon.jpg', [...jpegBytes(width: 64, height: 48), 0]);
      await fixture.scan();

      final found = await finder().find(idOf('3D/salon_3D_LRF_Full_SBS (1).jpg'));
      expect((found.isVersion, found.original), (true, null));
    });

    test('a version of a newer format and one of an unknown origin are versions all the same', () async {
      final newer = versionXmp(original).toXml().replaceFirst('FormatVersion="1"', 'FormatVersion="2"');
      final other = versionXmp(original).toXml().replaceFirst('Origin="EstimatedDepth"', 'Origin="TwoViews"');
      fixture
        ..write('Photos/salon_3D_LRF_Full_SBS (4).jpg', jpegBytes(width: 16, height: 6, xmp: newer))
        ..write('Photos/salon_3D_LRF_Full_SBS (5).jpg', jpegBytes(width: 16, height: 6, xmp: other));
      await fixture.scan();
      hash('salon.jpg', original);

      final versions = (await finder().find(idOf('salon.jpg'))).versions;
      expect(versions, hasLength(4));
      final byName = {for (final version in versions) version.name: version};
      expect(byName['salon_3D_LRF_Full_SBS (4).jpg']!.isEstimatedRelief, isTrue);
      expect(byName['salon_3D_LRF_Full_SBS (5).jpg']!.origin, IndexedOrigin.other);
      expect(byName['salon_3D_LRF_Full_SBS (5).jpg']!.isEstimatedRelief, isFalse);
      final ofOther = await finder().find(idOf('salon_3D_LRF_Full_SBS (5).jpg'));
      expect((ofOther.self!.isEstimatedRelief, ofOther.original!.name), (false, 'salon.jpg'));
    });
  });

  group('the provider', () {
    test('asks nothing for an asset outside the library or a video, and the finder for a photo of it', () async {
      await fixture.scan();
      hash('salon.jpg', original);
      final container = ProviderContainer(
        overrides: [photoVersionsFinderProvider.overrideWith((ref) async => finder())],
      );
      addTearDown(container.dispose);
      LocalAsset local(String id, {AssetType type = AssetType.image}) => LocalAsset(
        id: id,
        name: 'salon.jpg',
        type: type,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        playbackStyle: AssetPlaybackStyle.image,
        isEdited: false,
      );

      final photo = await container.read(photoVersionsProvider(local(idOf('salon.jpg'))).future);
      expect(photo.versions, hasLength(2));
      final video = await container.read(photoVersionsProvider(local(idOf('salon.jpg'), type: AssetType.video)).future);
      expect(video.versions, isEmpty);
      final remote = RemoteAsset(
        id: 'r1',
        name: 'salon.jpg',
        ownerId: 'u1',
        checksum: sha1Base64(original),
        type: AssetType.image,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        isEdited: false,
      );
      expect((await container.read(photoVersionsProvider(remote).future)).versions, isEmpty);
    });

    test('a neighbour kept online only is never read, so never downloaded by the details', () async {
      await fixture.scan();
      final reads = <String>[];
      final finder = PhotoVersionsFinder(
        fixture.library(),
        readHead: (path) {
          reads.add(p.basename(path));
          return readFileHead(path);
        },
        // OneDrive freed its space after the last scan
        attributes: (path) => p.basename(path) == 'salon_3D_LRF_Full_SBS.jpg' ? fileAttributeRecallOnDataAccess : 0,
      );

      final found = await finder.find(idOf('salon.jpg'));

      expect(reads, isNot(contains('salon_3D_LRF_Full_SBS.jpg')));
      expect(found.versions, isEmpty);
    });

    test('a neighbour that cannot be read costs only itself', () async {
      fixture.write('Photos/salon_3D_LRF_Full_SBS (2).jpg', fakeSbsJpeg(xmp: versionXmp(original)));
      await fixture.scan();
      final throwing = PhotoVersionsFinder(
        fixture.library(),
        readHead: (path) async => p.basename(path) == 'salon_3D_LRF_Full_SBS (2).jpg'
            ? throw const FileSystemException('held')
            : readFileHead(path),
      );

      final found = await throwing.find(idOf('salon.jpg'));
      expect(found.versions.map((version) => version.name), ['salon_3D_LRF_Full_SBS.jpg']);
    });
  });
}
