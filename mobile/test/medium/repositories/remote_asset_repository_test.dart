import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late RemoteAssetRepository sut;

  setUp(() {
    ctx = MediumRepositoryContext();
    sut = RemoteAssetRepository(ctx.db);
  });

  tearDown(() async {
    await ctx.dispose();
  });

  group('getByChecksum', () {
    late String userId;

    setUp(() async {
      final user = await ctx.newUser();
      userId = user.id;
      await ctx.newAuthUser(id: userId);
    });

    test('returns all assets when a partner shares the checksum', () async {
      const checksum = 'shared-partner-checksum';
      final mine = await ctx.newRemoteAsset(ownerId: userId, checksum: checksum);
      final partner = await ctx.newUser();
      final theirs = await ctx.newRemoteAsset(ownerId: partner.id, checksum: checksum);

      final result = await sut.getAllDebugForChecksum(checksum);
      final mineResult = result.firstWhere((asset) => asset.id == mine.id);
      final theirResult = result.firstWhere((asset) => asset.id == theirs.id);

      expect(result, isNotEmpty);
      expect(mineResult.id, mine.id);
      expect(mineResult.ownerId, userId);

      expect(theirResult.id, theirs.id);
      expect(theirResult.ownerId, partner.id);
    });

    test('returns partner asset only if there is no matching user asset', () async {
      const checksum = 'partner-only';
      final partner = await ctx.newUser();
      final theirs = await ctx.newRemoteAsset(ownerId: partner.id, checksum: checksum);

      final result = await sut.getAllDebugForChecksum(checksum);

      expect(result.length, 1);
      expect(result[0].id, theirs.id);
    });

    test('returns the current user\'s asset', () async {
      const checksum = 'simple';
      final remote = await ctx.newRemoteAsset(ownerId: userId, checksum: checksum);

      final result = await sut.getAllDebugForChecksum(checksum);

      expect(result.length, 1);
      expect(result[0].id, remote.id);
    });
  });

  group('equirectangularRemoteIds', () {
    late String userId;

    setUp(() async {
      userId = (await ctx.newUser()).id;
    });

    Future<String> newAsset({String? projectionType, bool withExif = true}) async {
      final asset = await ctx.newRemoteAsset(ownerId: userId);
      if (withExif) {
        await ctx.newRemoteExif(assetId: asset.id, projectionType: projectionType);
      }
      return asset.id;
    }

    test('keeps the assets asked for whose exif projection is equirectangular, like the 360° timeline', () async {
      final photo = await newAsset(projectionType: 'EQUIRECTANGULAR');
      final other = await newAsset(projectionType: 'EQUIRECTANGULAR');
      final flat = await newAsset();
      final withoutExif = await newAsset(withExif: false);
      final stereo = await newAsset(projectionType: 'EQUIRECTANGULAR_STEREO');
      final cubemap = await newAsset(projectionType: 'CUBEMAP');

      expect(await sut.equirectangularRemoteIds([photo, flat, withoutExif, stereo, cubemap, 'unknown']), {photo});
      expect(await sut.equirectangularRemoteIds([photo, other]), {photo, other});
      expect(await sut.equirectangularRemoteIds([]), isEmpty);
    });
  });
}
