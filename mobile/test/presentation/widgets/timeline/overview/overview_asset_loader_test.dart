// The reads behind the thumbnails of the months and the years: the requests of one frame merged into one read when
// they are close, over a wider span deeper in the timeline, the most recent first, two reads at a time, a block that
// leaves the screen dropped, a cache by index of the assets asked for that a change of the buckets clears. On the main
// timeline the deep requests go out together in one pass, and as ranges when the pass finds the timeline changed.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_asset_loader.dart';

import '../../../../fixtures/asset.stub.dart';

/// A source of [total] assets whose reads wait until the test completes them
class _Source {
  _Source(int total) : assets = List<BaseAsset>.generate(total, (i) => LocalAssetStub.image1.copyWith(id: 'a$i'));

  final List<BaseAsset> assets;
  final reads = <(int, int)>[];
  final _waiting = <Completer<void>>[];

  Future<List<BaseAsset>> read(int index, int count) async {
    reads.add((index, count));
    final gate = Completer<void>();
    _waiting.add(gate);
    await gate.future;
    return assets.skip(index).take(count).toList();
  }

  int get inFlight => _waiting.where((gate) => !gate.isCompleted).length;

  /// Lets every read waiting so far finish
  Future<void> release() async {
    for (final gate in _waiting.where((gate) => !gate.isCompleted).toList()) {
      gate.complete();
    }
    await pumpEventQueue();
  }
}

void main() {
  test('the requests of one frame that fall close together go out as one read', () async {
    final source = _Source(5000);
    final loader = OverviewAssetLoader(source.read);
    final got = <int, List<String>>{};
    for (final index in [0, 6, 12, 40]) {
      loader.request(index, 6, (assets) => got[index] = assets.map((a) => (a as LocalAsset).id).toList());
    }
    await pumpEventQueue();
    expect(source.reads, [(0, 46)]);

    await source.release();
    expect(got[0], ['a0', 'a1', 'a2', 'a3', 'a4', 'a5']);
    expect(got[40], ['a40', 'a41', 'a42', 'a43', 'a44', 'a45']);
    expect(loader.cached(6, 6)?.length, 6, reason: 'kept in the cache');
  });

  test('requests far apart go out the most recent first, two at a time', () async {
    final source = _Source(10000);
    final loader = OverviewAssetLoader(source.read);
    for (final index in [0, 2000, 4000, 6000]) {
      loader.request(index, 1, (_) {});
    }
    await pumpEventQueue();
    expect(source.reads, [(6000, 1), (4000, 1)], reason: 'the latest blocks on screen first');
    expect(source.inFlight, 2);

    await source.release();
    expect(source.reads, [(6000, 1), (4000, 1), (2000, 1), (0, 1)]);
    await source.release();
    expect(source.inFlight, 0);
  });

  test('a block that leaves the screen before its read goes out is dropped', () async {
    final source = _Source(10000);
    final loader = OverviewAssetLoader(source.read);
    loader.request(0, 1, (_) {});
    loader.request(3000, 1, (_) {});
    final gone = loader.request(6000, 1, (_) => fail('cancelled'));
    gone.cancel();
    await pumpEventQueue();
    expect(source.reads, [(3000, 1), (0, 1)]);
    expect(gone.isCancelled, isTrue);
    await source.release();
  });

  test('a cancelled request in a read already out does not hear back', () async {
    final source = _Source(100);
    final loader = OverviewAssetLoader(source.read);
    var heard = false;
    final request = loader.request(0, 3, (_) => heard = true);
    await pumpEventQueue();
    request.cancel();
    await source.release();
    expect(heard, isFalse);
    expect(loader.cached(0, 3), isNotNull, reason: 'what was read stays for the next block');
  });

  test('what the cache holds needs no read, the end of the timeline gives fewer', () async {
    final source = _Source(10);
    final loader = OverviewAssetLoader(source.read);
    List<BaseAsset>? got;
    loader.request(8, 6, (assets) => got = assets);
    await pumpEventQueue();
    await source.release();
    expect(got, hasLength(2));
    expect(loader.cached(8, 2), hasLength(2));
    expect(loader.cached(8, 3), isNull);
  });

  test('a change of the buckets clears the cache and drops the reads under way', () async {
    final source = _Source(100);
    final loader = OverviewAssetLoader(source.read);
    var heard = false;
    loader.request(0, 3, (_) => heard = true);
    await pumpEventQueue();
    final before = loader.generation;
    loader.clear();
    expect(loader.generation, isNot(before));
    await source.release();
    expect(heard, isFalse, reason: 'the indexes point at other assets now');
    expect(loader.cached(0, 3), isNull);
  });

  test('the cache keeps its capacity, the oldest read leaving first', () async {
    final source = _Source(100);
    final loader = OverviewAssetLoader(source.read, capacity: 10);
    loader.request(0, 8, (_) {});
    await pumpEventQueue();
    await source.release();
    loader.request(50, 8, (_) {});
    await pumpEventQueue();
    await source.release();
    expect(loader.cached(50, 8), isNotNull);
    expect(loader.cached(0, 1), isNull);
    expect(loader.cached(6, 2), isNotNull);
  });

  test('the cache keeps the assets asked for, not those read on the way between two requests', () async {
    final source = _Source(5000);
    final loader = OverviewAssetLoader(source.read);
    loader.request(0, 1, (_) {});
    loader.request(300, 1, (_) {});
    await pumpEventQueue();
    expect(source.reads, [(0, 301)]);
    await source.release();
    expect(loader.cached(300, 1), isNotNull);
    expect(loader.cached(150, 1), isNull, reason: 'read on the way, asked for by no block');
  });

  test('deeper in the timeline one read covers a wider span', () async {
    final source = _Source(60000);
    final loader = OverviewAssetLoader(source.read);
    for (final index in [0, 1000, 40000, 43000]) {
      loader.request(index, 1, (_) {});
    }
    await pumpEventQueue();
    // At 40,000 a read of its own steps through as many assets as the 3,000 read for nothing in between
    expect(source.reads, [(40000, 3001), (1000, 1)], reason: '1,000 apart near the top: two reads');
    await source.release();
    expect(source.reads.last, (0, 1));
    await source.release();
  });

  group('the main timeline', () {
    String idOf(BaseAsset asset) => (asset as LocalAsset).id;

    test('the deep requests go out together in one pass, those near the top as ranges', () async {
      final source = _Source(60000);
      final passes = <List<int>>[];
      final loader = OverviewAssetLoader(
        source.read,
        indexedSource: (indexes) async {
          passes.add(indexes);
          return {
            for (final index in indexes)
              if (index < source.assets.length) index: source.assets[index],
          };
        },
      );
      final got = <int, List<String>>{};
      for (final index in [0, 300, 20000, 40000, 40300, 59998]) {
        loader.request(index, 3, (assets) => got[index] = assets.map(idOf).toList());
      }
      await pumpEventQueue();
      expect(passes, hasLength(1));
      expect(passes.single, [20000, 20001, 20002, 40000, 40001, 40002, 40300, 40301, 40302, 59998, 59999, 60000]);
      expect(source.reads, [(0, 303)]);
      await source.release();
      expect(got[40300], ['a40300', 'a40301', 'a40302']);
      expect(got[59998], ['a59998', 'a59999'], reason: 'fewer at the end of the timeline');
      expect(got[300], ['a300', 'a301', 'a302']);
      expect(loader.cached(40000, 3), isNotNull);
      expect(loader.indexedReads, 1);
    });

    test('a pass that finds the timeline changed gives way to a read of the range', () async {
      final source = _Source(60000);
      var passes = 0;
      final loader = OverviewAssetLoader(
        source.read,
        indexedSource: (_) async {
          passes++;
          return null;
        },
      );
      List<String>? got;
      loader.request(40000, 2, (assets) => got = assets.map(idOf).toList());
      await pumpEventQueue();
      expect(passes, 1);
      expect(source.reads, [(40000, 2)]);
      await source.release();
      expect(got, ['a40000', 'a40001']);
      expect(passes, 1, reason: 'no second pass for the same request');
    });

    test('a pass under way when the buckets change does not answer', () async {
      final source = _Source(60000);
      final gate = Completer<void>();
      final loader = OverviewAssetLoader(
        source.read,
        indexedSource: (indexes) async {
          await gate.future;
          return {for (final index in indexes) index: source.assets[index]};
        },
      );
      var heard = false;
      loader.request(40000, 1, (_) => heard = true);
      await pumpEventQueue();
      loader.clear();
      gate.complete();
      await pumpEventQueue();
      expect(heard, isFalse);
      expect(loader.cached(40000, 1), isNull);
    });
  });

  test('a disposed loader reads nothing', () async {
    final source = _Source(100);
    final loader = OverviewAssetLoader(source.read)..dispose();
    final request = loader.request(0, 3, (_) => fail('disposed'));
    await pumpEventQueue();
    expect(source.reads, isEmpty);
    expect(request.isCancelled, isTrue);
  });
}
