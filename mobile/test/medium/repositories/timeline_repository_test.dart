import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late TimelineRepository sut;

  setUpAll(() async {
    await initializeDateFormatting();
  });

  setUp(() {
    ctx = MediumRepositoryContext();
    sut = TimelineRepository(ctx.db);
  });

  tearDown(() async {
    await ctx.dispose();
  });

  group('remoteAlbum assets', () {
    test('no duplicate assets when identical checksum appears in multiple local asset rows', () async {
      // Regression check for #23273: a LEFT OUTER JOIN on checksum would fan out and create duplicates
      // happens when same photo exists in multiple albums on device
      final user = await ctx.newUser();
      const checksum = 'yolo';
      final album = await ctx.newRemoteAlbum(ownerId: user.id);
      final remoteAsset = await ctx.newRemoteAsset(ownerId: user.id, checksum: checksum);
      await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: remoteAsset.id);

      final localAsset1 = await ctx.newLocalAsset(checksum: checksum);
      final localAsset2 = await ctx.newLocalAsset(checksum: checksum);

      final query = sut.remoteAlbum(album.id, .day);

      final buckets = await query.bucketSource().first;
      expect(buckets, hasLength(1));
      expect(buckets.single.assetCount, 1);

      final assets = await query.assetSource(0, 10);
      expect(assets, hasLength(1));
      expect((assets.first as RemoteAsset).id, remoteAsset.id);
      expect([localAsset1.id, localAsset2.id], contains((assets.first as RemoteAsset).localId));
    });

    test('orders shifted album assets in both directions and keeps normal asset order (#28852)', () async {
      final user = await ctx.newUser();
      final descendingAlbum = await ctx.newRemoteAlbum(ownerId: user.id, order: .desc);
      final ascendingAlbum = await ctx.newRemoteAlbum(ownerId: user.id, order: .asc);
      final shiftedLater = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2024, 9, 2, 12),
        localDateTime: DateTime.utc(2024, 9, 3, 12),
      );
      final shiftedEarlier = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2024, 9, 3, 12),
        localDateTime: DateTime.utc(2024, 9, 2, 12),
      );
      final normalLater = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2024, 9, 4, 14),
        localDateTime: DateTime.utc(2024, 9, 4, 14),
      );
      final normalEarlier = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2024, 9, 4, 12),
        localDateTime: DateTime.utc(2024, 9, 4, 12),
      );
      final seeded = [shiftedLater, shiftedEarlier, normalLater, normalEarlier];
      for (final asset in seeded) {
        await ctx.newRemoteAlbumAsset(albumId: descendingAlbum.id, assetId: asset.id);
        await ctx.newRemoteAlbumAsset(albumId: ascendingAlbum.id, assetId: asset.id);
      }

      final descending = sut.remoteAlbum(descendingAlbum.id, .day);
      final ascending = sut.remoteAlbum(ascendingAlbum.id, .day);

      final buckets = await descending.bucketSource().first;
      expect(buckets, hasLength(3));
      expect(buckets.map((bucket) => bucket.assetCount), [2, 1, 1]);

      final descendingAssets = await descending.assetSource(0, 10);
      expect(descendingAssets.map((asset) => (asset as RemoteAsset).id), [
        normalLater.id,
        normalEarlier.id,
        shiftedLater.id,
        shiftedEarlier.id,
      ]);

      final ascendingAssets = await ascending.assetSource(0, 10);
      expect(ascendingAssets.map((asset) => (asset as RemoteAsset).id), [
        shiftedEarlier.id,
        shiftedLater.id,
        normalEarlier.id,
        normalLater.id,
      ]);
    });
  });

  group('person assets', () {
    test('does not duplicate an asset that has multiple face records for the same person', () async {
      // Regression check for #26723: an INNER JOIN between remote_asset_entity and asset_face_entity
      // fanned out one asset into N rows when N face records pointed at the same (asset, person) pair
      final user = await ctx.newUser();
      final asset = await ctx.newRemoteAsset(ownerId: user.id);

      final person = await ctx.newPerson(ownerId: user.id);
      await ctx.newFace(assetId: asset.id, personId: person.id);
      await ctx.newFace(assetId: asset.id, personId: person.id);

      final query = sut.person([user.id], person.id, .day);

      final buckets = await query.bucketSource().first;
      expect(buckets, hasLength(1));
      expect(buckets.single.assetCount, 1);

      final assets = await query.assetSource(0, 10);
      expect(assets, hasLength(1));
      expect((assets.first as RemoteAsset).id, asset.id);
    });

    test('orders shifted person assets by effective date (#28852)', () async {
      final user = await ctx.newUser();
      final person = await ctx.newPerson(ownerId: user.id);
      final shiftedLater = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2024, 9, 2, 12),
        localDateTime: DateTime.utc(2024, 9, 3, 12),
      );
      final shiftedEarlier = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2024, 9, 3, 12),
        localDateTime: DateTime.utc(2024, 9, 2, 12),
      );
      await ctx.newFace(assetId: shiftedLater.id, personId: person.id);
      await ctx.newFace(assetId: shiftedEarlier.id, personId: person.id);

      final query = sut.person([user.id], person.id, .day);

      final buckets = await query.bucketSource().first;
      expect(buckets, hasLength(2));

      final assets = await query.assetSource(0, 10);
      expect(assets.map((asset) => (asset as RemoteAsset).id), [shiftedLater.id, shiftedEarlier.id]);
    });
  });

  group('live photos', () {
    test('remote-only live photo contains livePhotoVideoId and is marked as a motion photo', () async {
      final user = await ctx.newUser();
      final asset = await ctx.newRemoteAsset(ownerId: user.id, livePhotoVideoId: 'motion-photo-1');

      final assets = await sut.main([user.id], .day).assetSource(0, 10);

      expect(assets, hasLength(1));
      final remote = assets.single as RemoteAsset;
      expect(remote.id, asset.id);
      expect(remote.livePhotoVideoId, 'motion-photo-1');
      expect(remote.isMotionPhoto, isTrue);
      expect(remote.localId, isNull);
    });

    test('merged live photo resolves localId and is marked as a motion photo', () async {
      final user = await ctx.newUser();
      const checksum = 'shared-live-photo-checksum';
      final asset = await ctx.newRemoteAsset(ownerId: user.id, checksum: checksum, livePhotoVideoId: 'motion-photo-2');
      final local = await ctx.newLocalAsset(checksum: checksum);

      final assets = await sut.main([user.id], .day).assetSource(0, 10);

      expect(assets, hasLength(1));
      final remote = assets.single as RemoteAsset;
      expect(remote.id, asset.id);
      expect(remote.livePhotoVideoId, 'motion-photo-2');
      expect(remote.isMotionPhoto, isTrue);
      expect(remote.localId, local.id);
    });
  });

  group('panorama360 assets', () {
    late String userId;

    setUp(() async {
      userId = (await ctx.newUser()).id;
    });

    Future<RemoteAssetEntityData> newAsset({
      String? projectionType,
      bool withExif = true,
      String? ownerId,
      AssetType type = .image,
      AssetVisibility visibility = .timeline,
      DateTime? createdAt,
      DateTime? deletedAt,
      String? checksum,
      String? stackId,
    }) async {
      final asset = await ctx.newRemoteAsset(
        ownerId: ownerId ?? userId,
        type: type,
        visibility: visibility,
        createdAt: createdAt,
        deletedAt: deletedAt,
        checksum: checksum,
        stackId: stackId,
      );
      if (withExif) {
        await ctx.newRemoteExif(assetId: asset.id, projectionType: projectionType);
      }
      return asset;
    }

    Future<List<String>> listedIds([GroupAssetsBy groupBy = .day]) async {
      final assets = await sut.panorama360(userId, groupBy).assetSource(0, 100);
      return assets.map((asset) => (asset as RemoteAsset).id).toList();
    }

    Future<int> bucketTotal([GroupAssetsBy groupBy = .day]) async {
      final buckets = await sut.panorama360(userId, groupBy).bucketSource().first;
      return buckets.fold<int>(0, (total, bucket) => total + bucket.assetCount);
    }

    test('lists equirectangular photos and videos and nothing else', () async {
      final photo = await newAsset(projectionType: 'EQUIRECTANGULAR');
      final video = await newAsset(projectionType: 'EQUIRECTANGULAR', type: .video);
      await newAsset();
      await newAsset(withExif: false);
      await newAsset(projectionType: 'CUBEMAP');
      await newAsset(projectionType: 'EQUIRECTANGULAR_STEREO');
      await newAsset(projectionType: 'NONE', type: .video);

      expect(await listedIds(), unorderedEquals([photo.id, video.id]));
      expect(await bucketTotal(), 2);
      expect(await listedIds(.month), unorderedEquals([photo.id, video.id]));
      expect(await bucketTotal(.month), 2);
      expect(await listedIds(.none), unorderedEquals([photo.id, video.id]));
      expect(await bucketTotal(.none), 2);

      final assets = await sut.panorama360(userId, .day).assetSource(0, 100);
      expect(assets.firstWhere((asset) => (asset as RemoteAsset).id == video.id).isVideo, isTrue);
      expect(sut.panorama360(userId, .day).origin, TimelineOrigin.panorama360);
    });

    test('keeps archived assets and leaves out trashed, locked and other users assets', () async {
      final other = await ctx.newUser();
      final archived = await newAsset(projectionType: 'EQUIRECTANGULAR', visibility: .archive);
      await newAsset(projectionType: 'EQUIRECTANGULAR', deletedAt: DateTime.utc(2024, 9, 5));
      await newAsset(projectionType: 'EQUIRECTANGULAR', visibility: .locked);
      await newAsset(projectionType: 'EQUIRECTANGULAR', visibility: .hidden);
      await newAsset(projectionType: 'EQUIRECTANGULAR', ownerId: other.id);

      expect(await listedIds(), [archived.id]);
      expect(await bucketTotal(), 1);
    });

    test('lists the newest first, one bucket per day', () async {
      final oldest = await newAsset(projectionType: 'EQUIRECTANGULAR', createdAt: DateTime.utc(2024, 9, 1, 12));
      final newest = await newAsset(projectionType: 'EQUIRECTANGULAR', createdAt: DateTime.utc(2024, 9, 3, 12));
      final middle = await newAsset(
        projectionType: 'EQUIRECTANGULAR',
        type: .video,
        createdAt: DateTime.utc(2024, 9, 2, 12),
      );

      expect(await listedIds(), [newest.id, middle.id, oldest.id]);

      final buckets = await sut.panorama360(userId, .day).bucketSource().first;
      expect(buckets.map((bucket) => bucket.assetCount), [1, 1, 1]);
      final dates = buckets.map((bucket) => (bucket as TimeBucket).date).toList();
      expect(dates, [...dates]..sort((a, b) => b.compareTo(a)));
    });

    test('shows only the primary asset of a stack', () async {
      final primary = await newAsset(projectionType: 'EQUIRECTANGULAR', stackId: 'stack-1');
      await newAsset(projectionType: 'EQUIRECTANGULAR', stackId: 'stack-1');
      await ctx.newStack(id: 'stack-1', ownerId: userId, primaryAssetId: primary.id);

      expect(await listedIds(), [primary.id]);
      expect(await bucketTotal(), 1);
    });

    test('resolves the copy on the device without listing the asset twice', () async {
      const checksum = 'panorama-checksum';
      final asset = await newAsset(projectionType: 'EQUIRECTANGULAR', type: .video, checksum: checksum);
      final local1 = await ctx.newLocalAsset(checksum: checksum);
      final local2 = await ctx.newLocalAsset(checksum: checksum);

      final assets = await sut.panorama360(userId, .day).assetSource(0, 100);

      expect(assets, hasLength(1));
      final remote = assets.single as RemoteAsset;
      expect(remote.id, asset.id);
      expect([local1.id, local2.id], contains(remote.localId));
    });

    test('updates the buckets when the exif of an asset arrives after the asset', () async {
      final asset = await newAsset(withExif: false);
      final buckets = sut.panorama360(userId, .day).bucketSource();

      final expectation = expectLater(
        buckets.map((list) => list.fold<int>(0, (total, bucket) => total + bucket.assetCount)),
        emitsInOrder([0, 1]),
      );
      await Future<void>.delayed(Duration.zero);
      await ctx.newRemoteExif(assetId: asset.id, projectionType: 'EQUIRECTANGULAR');

      await expectation;
    });
  });

  group('localAlbum assets', () {
    late String userId;
    late String otherUserId;

    setUp(() async {
      final user = await ctx.newUser();
      userId = user.id;
      await ctx.newAuthUser(id: userId);
      final other = await ctx.newUser();
      otherUserId = other.id;
    });

    test('does not duplicate assets when a partner shares the checksum', () async {
      const checksum = 'shared-partner-checksum';
      final album = await ctx.newLocalAlbum();
      final local = await ctx.newLocalAsset(checksum: checksum);
      await ctx.newLocalAlbumAsset(albumId: album.id, assetId: local.id);
      final myRemote = await ctx.newRemoteAsset(ownerId: userId, checksum: checksum);
      await ctx.newRemoteAsset(ownerId: otherUserId, checksum: checksum);

      final assets = await sut.localAlbum(album.id, .day).assetSource(0, 10);

      expect(assets, hasLength(1));
      final asset = assets.single as LocalAsset;
      expect(asset.id, local.id);
      // Must resolve the current user's remote id
      expect(asset.remoteId, myRemote.id);
    });

    test('bucket count ignores a partner sharing the checksum', () async {
      const checksum = 'shared-partner-checksum';
      final album = await ctx.newLocalAlbum();
      final local = await ctx.newLocalAsset(checksum: checksum);
      await ctx.newLocalAlbumAsset(albumId: album.id, assetId: local.id);
      await ctx.newRemoteAsset(ownerId: userId, checksum: checksum);
      await ctx.newRemoteAsset(ownerId: otherUserId, checksum: checksum);

      final buckets = await sut.localAlbum(album.id, .day).bucketSource().first;

      expect(buckets, hasLength(1));
      expect(buckets.single.assetCount, 1);
    });
  });
}
