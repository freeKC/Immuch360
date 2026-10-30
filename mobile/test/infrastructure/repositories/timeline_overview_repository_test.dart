// The one-pass reads of the months and the years of the main timeline give, at each index, the asset that mergedAsset
// (the reads of the grid) gives there: the same users, stacks, hidden and deleted assets, device albums selected and
// excluded, backed up photos and those of the device alone. A change of mergedAsset that the one pass does not follow
// shows here.

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline_overview.repository.dart';

import '../../medium/repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late String me;
  late String partner;
  late TimelineOverviewRepository repository;

  setUp(() async {
    ctx = MediumRepositoryContext();
    me = (await ctx.newUser()).id;
    partner = (await ctx.newUser()).id;
    repository = TimelineOverviewRepository(ctx.db);
  });

  tearDown(() => ctx.dispose());

  /// A library of every kind, each asset at its own minute so that the order has no ties
  Future<void> seed() async {
    final stranger = (await ctx.newUser()).id;
    var minute = 0;
    DateTime next() => DateTime.utc(2026, 10, 20, 12).subtract(Duration(minutes: 997 * minute++));

    for (var i = 0; i < 30; i++) {
      await ctx.newRemoteAsset(id: 'mine$i', ownerId: me, checksum: 'sum-mine$i', createdAt: next());
    }
    await ctx.newRemoteAsset(id: 'deleted', ownerId: me, createdAt: next(), deletedAt: DateTime.utc(2026));
    await ctx.newRemoteAsset(id: 'archived', ownerId: me, createdAt: next(), visibility: AssetVisibility.archive);
    await ctx.newRemoteAsset(id: 'hidden', ownerId: me, createdAt: next(), visibility: AssetVisibility.hidden);
    // Shown on another day than it was taken
    await ctx.newRemoteAsset(id: 'moved', ownerId: me, createdAt: next(), localDateTime: DateTime.utc(2027, 3, 4, 12));
    // A stack shows its primary asset only
    await ctx.newRemoteAsset(id: 'primary', ownerId: me, createdAt: next());
    final stack = await ctx.newStack(ownerId: me, primaryAssetId: 'primary');
    await (ctx.db.update(
      ctx.db.remoteAssetEntity,
    )..where((row) => row.id.equals('primary'))).write(RemoteAssetEntityCompanion(stackId: Value(stack.id)));
    for (var i = 0; i < 2; i++) {
      await ctx.newRemoteAsset(id: 'stacked$i', ownerId: me, createdAt: next(), stackId: stack.id);
    }
    for (var i = 0; i < 5; i++) {
      await ctx.newRemoteAsset(id: 'partner$i', ownerId: partner, createdAt: next());
    }
    for (var i = 0; i < 3; i++) {
      await ctx.newRemoteAsset(id: 'stranger$i', ownerId: stranger, checksum: 'sum-stranger$i', createdAt: next());
    }

    await ctx.newLocalAlbum(id: 'selected', backupSelection: BackupSelection.selected);
    await ctx.newLocalAlbum(id: 'excluded', backupSelection: BackupSelection.excluded);
    await ctx.newLocalAlbum(id: 'other', backupSelection: BackupSelection.none);
    Future<void> local(String id, List<String> albums, {String? checksum}) async {
      await ctx.newLocalAsset(id: id, checksum: checksum, createdAt: next());
      for (final album in albums) {
        await ctx.newLocalAlbumAsset(albumId: album, assetId: id);
      }
    }

    for (var i = 0; i < 5; i++) {
      // Backed up: the remote asset shows, with this one as its local copy
      await local('backedUp$i', ['selected'], checksum: 'sum-mine${i * 3}');
    }
    for (var i = 0; i < 6; i++) {
      await local('deviceOnly$i', ['selected']);
    }
    await local('excludedToo', ['selected', 'excluded']);
    await local('notSelected', ['other']);
    // The same photo as a stranger's: on this device alone as far as the timeline goes
    await local('likeStranger', ['selected'], checksum: 'sum-stranger1');
  }

  test('each index holds the asset the reads of the grid give there', () async {
    await seed();
    final users = [me, partner];
    final grid = await ctx.db.mergedAssetDrift.mergedAsset(userIds: users, limit: (_) => Limit(1000, 0)).get();
    expect(grid.length, greaterThan(40));

    final indexes = [for (var i = 0; i < grid.length + 3; i++) i];
    final read = await repository.mergedAssetsAt(users, indexes);
    expect(read.total, grid.length);
    expect(read.assets.keys.toList()..sort(), [for (var i = 0; i < grid.length; i++) i], reason: 'none past the end');
    for (var i = 0; i < grid.length; i++) {
      final row = grid[i];
      final asset = read.assets[i]!;
      if (row.remoteId != null) {
        expect(asset, isA<RemoteAsset>(), reason: 'index $i');
        expect((asset as RemoteAsset).id, row.remoteId, reason: 'index $i');
        expect(asset.localId, row.localId, reason: 'the local copy at index $i');
      } else {
        expect(asset, isA<LocalAsset>(), reason: 'index $i');
        expect((asset as LocalAsset).id, row.localId, reason: 'index $i');
      }
    }
    final ids = read.assets.values.map((asset) => asset is RemoteAsset ? asset.id : (asset as LocalAsset).id).toSet();
    expect(ids, containsAll(['moved', 'primary', 'partner0', 'deviceOnly0', 'likeStranger']));
    expect(ids, isNot(contains('deleted')));
    expect(ids, isNot(contains('stacked0')));
    expect(ids, isNot(contains('stranger0')));
    expect(ids, isNot(contains('excludedToo')));
    expect(ids, isNot(contains('backedUp0')), reason: 'its remote asset shows instead');
  });

  test('some indexes only, and the total of the whole timeline', () async {
    await seed();
    final users = [me, partner];
    final grid = await ctx.db.mergedAssetDrift.mergedAsset(userIds: users, limit: (_) => Limit(1000, 0)).get();
    final read = await repository.mergedAssetsAt(users, [7, 3, 40]);
    expect(read.total, grid.length);
    expect(read.assets.keys.toSet(), {3, 7, 40}, reason: 'not the first row read for the total');
    String idOf(BaseAsset asset) => asset is RemoteAsset ? asset.id : (asset as LocalAsset).id;
    expect(idOf(read.assets[40]!), grid[40].remoteId ?? grid[40].localId);
  });

  test('an empty timeline, and no index', () async {
    expect((await repository.mergedAssetsAt([me], [0, 1])).total, 0);
    expect((await repository.mergedAssetsAt([me], [0, 1])).assets, isEmpty);
    expect((await repository.mergedAssetsAt([me], const [])).assets, isEmpty);
  });
}
