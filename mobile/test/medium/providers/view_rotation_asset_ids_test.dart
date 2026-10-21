// The query that tells which turned assets the database still holds, on the server or on this device, before the
// rotations of the others are forgotten (see ViewRotations).

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/providers/asset_viewer/view_rotation.provider.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;

  setUp(() {
    ctx = MediumRepositoryContext();
  });

  tearDown(() async {
    await ctx.dispose();
  });

  test('cannot tell while the database holds no asset of a server', () async {
    final local = await ctx.newLocalAsset();
    expect(await existingAssetIds(ctx.db, {local.id, 'gone'}), isNull);
  });

  test('finds the assets of the server and of the device among the ids, past a chunk of 500', () async {
    final user = await ctx.newUser();
    final remote = await ctx.newRemoteAsset(ownerId: user.id);
    final local = await ctx.newLocalAsset();
    final ids = {remote.id, local.id, for (var index = 0; index < 600; index++) 'gone-$index'};
    expect(await existingAssetIds(ctx.db, ids), {remote.id, local.id});
  });
}
