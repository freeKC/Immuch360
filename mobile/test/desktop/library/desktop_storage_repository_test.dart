import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/desktop/library/desktop_storage_repository.dart';
import 'package:immich_mobile/desktop/platform/desktop_permission_api.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/platform/permission_api.g.dart';
import 'package:path/path.dart' as p;

import 'library_fixtures.dart';
import 'library_test_support.dart';

LocalAsset _asset(String id, String name, AssetType type) => LocalAsset(
  id: id,
  name: name,
  type: type,
  createdAt: DateTime(2024),
  updatedAt: DateTime(2024),
  playbackStyle: AssetPlaybackStyle.unknown,
  isEdited: false,
);

void main() {
  late TestLibrary fixture;
  late String rootId;
  late DesktopStorageRepository storage;

  setUp(() async {
    fixture = TestLibrary();
    fixture.probe.mounts[fixture.files.path] = 'win-0000beef';
    fixture
      ..write('Photos/IMG_1.jpg', jpegBytes(width: 40, height: 30))
      ..write('Photos/VID_2.mp4', mp4Bytes(width: 16, height: 9, durationMs: 61500));
    final library = fixture.library();
    rootId = library.addRoot(p.join(fixture.files.path, 'Photos')).id;
    await library.scan();
    storage = DesktopStorageRepository(library: () async => library, attributes: (path) => fixture.attributes[path]);
  });
  tearDown(() => fixture.dispose());

  test('the file of a local asset is the file of the library, read in place', () async {
    final id = fixture.ids.file(rootId, 'IMG_1.jpg');
    final file = await storage.getFileForAsset(id);
    expect(file!.path, p.join(fixture.files.path, 'Photos', 'IMG_1.jpg'));
    expect(await storage.isAssetAvailableLocally(id), isTrue);
    expect(await storage.getFileForAsset('f0'), isNull);
  });

  test('uploads get an AssetEntity built in Dart: type, size, duration in seconds, name, dates', () async {
    final id = fixture.ids.file(rootId, 'VID_2.mp4');
    final entity = await storage.getAssetEntityForAsset(_asset(id, 'VID_2.mp4', AssetType.video));
    expect(entity, isNotNull);
    expect(entity!.id, id);
    expect(entity.typeInt, 2);
    expect((entity.width, entity.height), (16, 9));
    expect(entity.duration, 61);
    expect(entity.title, 'VID_2.mp4');
    expect(entity.mimeType, 'video/mp4');
    expect(entity.isLivePhoto, isFalse);
    expect(await storage.getMotionFileForAsset(_asset(id, 'VID_2.mp4', AssetType.video)), isNull);
  });

  test(
    'a file the cloud client emptied since the scan, or gone, has no file: the upload says it is not found',
    () async {
      final id = fixture.ids.file(rootId, 'IMG_1.jpg');
      fixture.attributes[p.join(fixture.files.path, 'Photos', 'IMG_1.jpg')] = 0x400000;
      expect(await storage.getFileForAsset(id), isNull);
      expect(await storage.getAssetEntityForAsset(_asset(id, 'IMG_1.jpg', AssetType.image)), isNull);

      fixture.attributes.clear();
      fixture.files.deleteSync(recursive: true);
      expect(await storage.isAssetAvailableLocally(id), isFalse);
    },
  );

  test('nothing comes from a cloud: no iCloud on a computer', () async {
    expect(await storage.loadFileFromCloud(fixture.ids.file(rootId, 'IMG_1.jpg')), isNull);
  });

  group('the photo permission of a computer', () {
    test('denied until a folder is chosen, which shows the way to the folders page; nothing else asked', () async {
      var folders = false;
      final permissions = DesktopPermissionRepository(PermissionApi(), hasFolders: () async => folders);
      expect(await permissions.getStatus(DevicePermission.photos), DevicePermissionStatus.denied);
      expect(await permissions.request(DevicePermission.videos), DevicePermissionStatus.denied);
      expect(await permissions.getStatus(DevicePermission.mediaLocation), DevicePermissionStatus.granted);

      folders = true;
      expect(await permissions.getStatus(DevicePermission.photos), DevicePermissionStatus.granted);
      expect(await permissions.request(DevicePermission.photos), DevicePermissionStatus.granted);
    });

    test('an index that cannot be read leads to the folders page too', () async {
      final permissions = DesktopPermissionRepository(PermissionApi(), hasFolders: () async => throw StateError('no'));
      expect(await permissions.getStatus(DevicePermission.photos), DevicePermissionStatus.denied);
    });
  });
}
