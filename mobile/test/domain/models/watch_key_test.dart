import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';

import '../../unit/factories/local_asset_factory.dart';
import '../../unit/factories/remote_asset_factory.dart';

void main() {
  group('WatchKey.ofAsset', () {
    test('an asset of the server by its server id, a UUID that no other server has', () {
      final asset = RemoteAssetFactory.create(type: .video);

      expect(WatchKey.ofAsset(asset).key, 'asset:${asset.id}');
      expect(WatchKey.ofAsset(asset).alias, isNull);
    });

    test('an asset uploaded from this device is also found under its id on the device', () {
      final asset = RemoteAssetFactory.create(type: .video, localId: 'local-7');

      expect(WatchKey.ofAsset(asset).key, 'asset:${asset.id}');
      expect(WatchKey.ofAsset(asset).alias, 'local:local-7');
      expect(WatchKey.ofAsset(asset).lookups, ['asset:${asset.id}', 'local:local-7']);
    });

    test('a file of the device or of the library of a computer by its id there', () {
      final asset = LocalAssetFactory.create(id: 'local-7');

      expect(WatchKey.ofAsset(asset).key, 'local:local-7');
      expect(WatchKey.ofAsset(asset).alias, isNull);
    });

    test('the copy of the device already uploaded goes under the server id', () {
      final asset = LocalAssetFactory.create(id: 'local-7', remoteId: 'remote-7');

      expect(WatchKey.ofAsset(asset).key, 'asset:remote-7');
      expect(WatchKey.ofAsset(asset).alias, 'local:local-7');
    });
  });

  group('WatchKey.ofEntry', () {
    final modified = DateTime.utc(2026, 7, 14, 10, 30);

    test('a file of a share by its share and its path, with a fingerprint that finds it once renamed', () {
      final entry = NetworkEntry(
        sourceId: 'nas',
        path: '/Films/Le film.mkv',
        isDirectory: false,
        size: 4200000000,
        modified: modified,
      );

      final key = WatchKey.ofEntry(entry);

      expect(key.key, 'share:nas:/Films/Le film.mkv');
      expect(key.fingerprint, 'fp:nas:4200000000:${modified.millisecondsSinceEpoch}');
      expect(key.alias, isNull);
    });

    test('no fingerprint without a size and a date', () {
      const entry = NetworkEntry(sourceId: 'dlna', path: '/0/12/film.mp4', isDirectory: false);

      expect(WatchKey.ofEntry(entry).fingerprint, isNull);
    });

    test('a file of a drone card or of a picked folder by its name and size, as the uploads know it', () {
      final entry = NetworkEntry(
        sourceId: '${NetworkEntry.importSourcePrefix}abc',
        path: '/DCIM/DJI_001/DJI_20261021143000_0001_D.MP4',
        isDirectory: false,
        size: 1234,
        modified: modified,
      );

      expect(WatchKey.ofEntry(entry).key, 'import:${UploadRecordStore.keyOf(entry)}');
      expect(WatchKey.ofEntry(entry).fingerprint, isNull);
    });
  });

  test('two keys of the same media are equal', () {
    expect(const WatchKey('asset:a', alias: 'local:b'), const WatchKey('asset:a', alias: 'local:b'));
    expect(const WatchKey('asset:a').hashCode, const WatchKey('asset:a').hashCode);
    expect(const WatchKey('asset:a'), isNot(const WatchKey('asset:a', alias: 'local:b')));
  });
}
