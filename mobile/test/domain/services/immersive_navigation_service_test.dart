import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/immersive_navigation.service.dart';

import '../../unit/factories/local_asset_factory.dart';
import '../../unit/factories/remote_asset_factory.dart';

/// A timeline of [length] items named by their index, whose lookups and checks are recorded
class _FakeTimeline {
  _FakeTimeline(this.length, {this._capable = const {}, this._missing = const {}});

  final int length;
  final Set<int> _capable;
  final Set<int> _missing;

  /// The (start, count) of every lookup
  final lookups = <(int, int)>[];

  /// The items of every capability check, in the order they were given
  final checks = <List<int>>[];

  Future<List<int?>> lookup(int start, int count) async {
    lookups.add((start, count));
    return [
      for (var index = start; index < start + count && index < length; index++)
        if (_missing.contains(index)) null else index,
    ];
  }

  Future<List<bool>> isCapable(List<int> items) async {
    checks.add(items);
    return [for (final item in items) _capable.contains(item)];
  }

  Future<ImmersiveCandidate<int>?> find(int index, int step, {int? limit, int chunkSize = 4}) =>
      findAdjacentImmersive<int>(
        index: index,
        step: step,
        length: length,
        lookup: lookup,
        isCapable: isCapable,
        limit: limit ?? immersiveTimelineSearchLimit,
        chunkSize: chunkSize,
      );
}

void main() {
  group('findAdjacentImmersive', () {
    test('finds the nearest capable item forwards, checking a chunk at once', () async {
      final timeline = _FakeTimeline(20, capable: {2, 7, 9});

      final found = await timeline.find(2, 1);

      expect(found, (index: 7, item: 7));
      expect(timeline.lookups, [(3, 4), (7, 4)]);
      expect(timeline.checks, [
        [3, 4, 5, 6],
        [7, 8, 9, 10],
      ]);
    });

    test('finds the nearest capable item backwards, the nearest first in each chunk', () async {
      final timeline = _FakeTimeline(20, capable: {1, 3, 12});

      final found = await timeline.find(12, -1);

      expect(found, (index: 3, item: 3));
      expect(timeline.lookups, [(8, 4), (4, 4), (0, 4)]);
      expect(timeline.checks, [
        [11, 10, 9, 8],
        [7, 6, 5, 4],
        [3, 2, 1, 0],
      ]);
    });

    test('only the sign of the step counts', () async {
      final timeline = _FakeTimeline(10, capable: {4, 6});

      expect(await timeline.find(5, 3), (index: 6, item: 6));
      expect(await timeline.find(5, -7), (index: 4, item: 4));
      expect(await timeline.find(5, 0), isNull);
    });

    test('stops at the ends of the list', () async {
      final timeline = _FakeTimeline(10, capable: {0, 9});

      expect(await timeline.find(9, 1), isNull);
      expect(await timeline.find(0, -1), isNull);
      expect(timeline.lookups, isEmpty);

      expect(await timeline.find(6, 1, chunkSize: 32), (index: 9, item: 9));
      expect(timeline.lookups.last, (7, 3), reason: 'never past the last item');
    });

    test('gives up past the limit, without looking further', () async {
      final timeline = _FakeTimeline(1000, capable: {450});

      expect(await timeline.find(0, 1, chunkSize: 32), isNull);
      final looked = timeline.lookups.fold<int>(0, (total, lookup) => total + lookup.$2);
      expect(looked, immersiveTimelineSearchLimit);
      expect(timeline.lookups.last.$1 + timeline.lookups.last.$2 - 1, immersiveTimelineSearchLimit);
      expect(timeline.checks.every((chunk) => chunk.length <= 32), isTrue);

      expect(await timeline.find(100, 1, chunkSize: 32), (index: 450, item: 450));
      expect(await timeline.find(800, -1, chunkSize: 32, limit: 349), isNull, reason: '350 items away');
      expect(await timeline.find(800, -1, chunkSize: 32, limit: 350), (index: 450, item: 450));
    });

    test('skips the items the lookup does not give', () async {
      final timeline = _FakeTimeline(10, capable: {3, 4}, missing: {3});

      expect(await timeline.find(1, 1), (index: 4, item: 4));
      expect(timeline.checks.first, [2, 4, 5]);
    });

    test('starts from the end of a list that shrank, going backwards', () async {
      final timeline = _FakeTimeline(5, capable: {4});

      expect(await timeline.find(12, -1), (index: 4, item: 4));
      expect(await timeline.find(12, 1), isNull);
    });

    test('stops once cancelled', () async {
      final timeline = _FakeTimeline(100, capable: {90});
      var cancelled = false;

      final found = await findAdjacentImmersive<int>(
        index: 0,
        step: 1,
        length: 100,
        lookup: (start, count) {
          // The viewer closes while the first chunk loads
          cancelled = true;
          return timeline.lookup(start, count);
        },
        isCapable: timeline.isCapable,
        isCancelled: () => cancelled,
      );

      expect(found, isNull);
      expect(timeline.lookups, hasLength(1));
      expect(timeline.checks, isEmpty);
    });
  });

  group('findAdjacentImmersiveInFolder', () {
    final files = ['a.jpg', 'b.mp4', 'c.jpg', 'd.jpg', 'e.mp4'];

    test('checks the files one by one, nearest first, and stops at the first capable one', () async {
      final checked = <String>[];
      Future<bool> is360(String name) async {
        checked.add(name);
        return name == 'd.jpg' || name == 'e.mp4';
      }

      expect(await findAdjacentImmersiveInFolder(items: files, index: 0, step: 1, isCapable: is360), (
        index: 3,
        item: 'd.jpg',
      ));
      expect(checked, ['b.mp4', 'c.jpg', 'd.jpg']);

      checked.clear();
      expect(await findAdjacentImmersiveInFolder(items: files, index: 3, step: -1, isCapable: is360), isNull);
      expect(checked, ['c.jpg', 'b.mp4', 'a.jpg']);
    });

    test('reads at most the folder limit', () async {
      final many = [for (var index = 0; index < 200; index++) 'IMG_$index.jpg'];
      var checks = 0;
      Future<bool> is360(String name) async {
        checks++;
        return name == 'IMG_120.jpg';
      }

      expect(await findAdjacentImmersiveInFolder(items: many, index: 10, step: 1, isCapable: is360), isNull);
      expect(checks, immersiveFolderSearchLimit);

      checks = 0;
      expect(await findAdjacentImmersiveInFolder(items: many, index: 100, step: 1, isCapable: is360), (
        index: 120,
        item: 'IMG_120.jpg',
      ));
      expect(checks, 20);
    });

    test('has no previous or next for a file alone', () async {
      Future<bool> any(String _) async => true;

      expect(await findAdjacentImmersiveInFolder(items: ['a.jpg'], index: 0, step: 1, isCapable: any), isNull);
      expect(await findAdjacentImmersiveInFolder(items: ['a.jpg'], index: 0, step: -1, isCapable: any), isNull);
    });
  });

  group('isImmersiveCandidate', () {
    bool candidate(
      BaseAsset asset, {
      bool all360 = false,
      Set<String> forced = const {},
      Set<String> localIds = const {},
      Set<String> equirectangularIds = const {},
    }) => isImmersiveCandidate(
      asset,
      all360: all360,
      forced: forced,
      localIds: localIds,
      equirectangularIds: equirectangularIds,
    );

    test('takes every photo and video of the 360° timeline', () {
      expect(candidate(RemoteAssetFactory.create(), all360: true), isTrue);
      expect(candidate(RemoteAssetFactory.create(type: .video), all360: true), isTrue);
      expect(candidate(RemoteAssetFactory.create(type: .audio), all360: true), isFalse);
    });

    test('elsewhere, takes the assets forced, found on the device or flagged by the server', () {
      final remote = RemoteAssetFactory.create(id: 'remote-1', localId: 'local-1');
      final local = LocalAssetFactory.create(id: 'local-2');

      expect(candidate(remote), isFalse);
      expect(candidate(remote, forced: {'remote-1'}), isTrue);
      expect(candidate(remote, forced: {'local-1'}), isTrue, reason: 'chosen before the upload');
      expect(candidate(remote, localIds: {'local-1'}), isTrue);
      expect(candidate(remote, equirectangularIds: {'remote-1'}), isTrue);
      expect(candidate(local, forced: {'local-2'}), isTrue);
      expect(candidate(local, localIds: {'local-2'}), isTrue);
      expect(candidate(local, equirectangularIds: {'local-2'}), isFalse, reason: 'no server id');
    });
  });
}
