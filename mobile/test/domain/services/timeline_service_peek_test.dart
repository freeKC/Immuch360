// peekAssets: the months and years of the timeline read their thumbnails from all over the library without moving
// the buffer of the grid. A range the buffer holds needs no query; any other is one query and the buffer stays.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';

import '../../fixtures/asset.stub.dart';

void main() {
  late List<BaseAsset> assets;
  late List<(int, int)> queries;
  late TimelineService service;

  setUp(() async {
    assets = List<BaseAsset>.generate(5000, (i) => LocalAssetStub.image1.copyWith(id: 'a$i'));
    queries = [];
    service = TimelineService((
      assetSource: (index, count) async {
        queries.add((index, count));
        return assets.sublist(index, math.min(index + count, assets.length));
      },
      bucketSource: () => Stream.value([TimeBucket(date: DateTime(2025), assetCount: assets.length)]),
      origin: TimelineOrigin.main,
    ));
    // The buckets come, then the first buffer: 1024 assets from the start
    await pumpEventQueue();
    expect(queries, [(0, 1024)]);
    queries.clear();
  });

  tearDown(() => service.dispose());

  String idOf(BaseAsset asset) => (asset as LocalAsset).id;

  test('a range the buffer holds needs no query', () async {
    expect(service.hasRange(0, 1024), isTrue);
    final peeked = await service.peekAssets(10, 6);
    expect(peeked.map(idOf), ['a10', 'a11', 'a12', 'a13', 'a14', 'a15']);
    expect(queries, isEmpty);
  });

  test('another range is one query of that range, and the buffer stays where it was', () async {
    final peeked = await service.peekAssets(3000, 6);
    expect(peeked.map(idOf), ['a3000', 'a3001', 'a3002', 'a3003', 'a3004', 'a3005']);
    expect(queries, [(3000, 6)]);
    expect(service.hasRange(0, 1024), isTrue, reason: 'the grid keeps its buffer');
    expect(service.hasRange(3000, 6), isFalse);
    expect(idOf(service.getAssets(0, 1).single), 'a0');
  });

  test('the end of the timeline gives fewer, nothing asked gives nothing', () async {
    expect(await service.peekAssets(4998, 6), hasLength(2));
    expect(await service.peekAssets(0, 0), isEmpty);
    expect(await service.peekAssets(-1, 3), isEmpty);
    expect(queries, [(4998, 6)]);
  });
}
