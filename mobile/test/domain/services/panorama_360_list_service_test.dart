import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/panorama_360.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/panorama_360_list.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/infrastructure/repositories/panorama_360.repository.dart';

typedef _RemoteCall = ({String userId, Set<String> forcedKeys, Set<String> deviceIds});
typedef _DeviceCall = ({Set<String> ids, String? userId});

class _FakeRepository implements Panorama360Repository {
  List<Panorama360Entry> remote = [];
  List<Panorama360Entry> device = [];

  /// Thrown by the next reads, when set
  Exception? failure;

  final remoteCalls = <_RemoteCall>[];
  final deviceCalls = <_DeviceCall>[];
  final changes = StreamController<void>.broadcast();

  @override
  Stream<void> watchChanges() => changes.stream;

  Future<void> close() => changes.close();

  @override
  Future<List<Panorama360Entry>> loadRemote({
    required String userId,
    required Set<String> forcedKeys,
    required Set<String> deviceIds,
  }) async {
    remoteCalls.add((userId: userId, forcedKeys: forcedKeys, deviceIds: deviceIds));
    final failure = this.failure;
    if (failure != null) {
      throw failure;
    }
    return remote;
  }

  @override
  Future<List<Panorama360Entry>> loadDevice({required Set<String> ids, String? userId}) async {
    deviceCalls.add((ids: ids, userId: userId));
    final failure = this.failure;
    if (failure != null) {
      throw failure;
    }
    return device;
  }
}

RemoteAsset _remote(String id, {DateTime? createdAt, AssetType type = AssetType.image}) => RemoteAsset(
  id: id,
  name: '$id.jpg',
  ownerId: 'me',
  checksum: 'checksum-$id',
  type: type,
  createdAt: createdAt ?? DateTime(2024, 9, 14, 12),
  updatedAt: DateTime(2024, 9, 14, 12),
  isEdited: false,
);

LocalAsset _local(String id, {DateTime? createdAt}) => LocalAsset(
  id: id,
  name: '$id.jpg',
  checksum: 'checksum-$id',
  type: AssetType.image,
  createdAt: createdAt ?? DateTime(2024, 9, 14, 12),
  updatedAt: DateTime(2024, 9, 14, 12),
  playbackStyle: AssetPlaybackStyle.image,
  isEdited: false,
);

Panorama360Entry _entry(BaseAsset asset, DateTime day) => Panorama360Entry(asset: asset, day: day);

Set<Panorama360Trait> _noTraits(Panorama360Entry entry) => const {};

void main() {
  late _FakeRepository repository;

  final photo = _entry(_remote('a', createdAt: DateTime(2024, 9, 14, 18)), DateTime(2024, 9, 14));
  final video = _entry(_remote('b', type: AssetType.video), DateTime(2024, 9, 14));
  final onDevice = _entry(_local('c', createdAt: DateTime(2024, 9, 12, 12)), DateTime(2024, 9, 12));

  setUp(() {
    repository = _FakeRepository()
      ..remote = [video, photo]
      ..device = [onDevice];
  });

  tearDown(() async {
    await repository.close();
  });

  Panorama360ListService newService() => Panorama360ListService(repository: repository, groupBy: GroupAssetsBy.day);

  List<String> idsOf(Panorama360View view) => [for (final entry in view.entries) entry.asset.id];

  test('reads once the sources and the view are set, and emits the entries and their buckets', () {
    fakeAsync((async) {
      final service = newService();
      final views = <Panorama360View>[];
      service.views.listen(views.add);

      service.setSources(userId: 'me', forcedKeys: {'forced'}, deviceIds: {'found'});
      async.flushMicrotasks();
      expect(repository.remoteCalls, isEmpty, reason: 'read once the current frame is done');
      async.elapse(Duration.zero);

      expect(repository.remoteCalls, hasLength(1));
      final remoteCall = repository.remoteCalls.single;
      expect(remoteCall.userId, 'me');
      expect(remoteCall.forcedKeys, {'forced'});
      expect(remoteCall.deviceIds, {'found', 'forced'}, reason: 'a forced device file counts as found');
      expect(repository.deviceCalls.single.ids, {'found', 'forced'});
      expect(repository.deviceCalls.single.userId, 'me');
      expect(views, isEmpty, reason: 'no view before the filter is known');

      service.setView(filter: const Panorama360Filter(), traitsOf: _noTraits);
      async.flushMicrotasks();

      expect(views, hasLength(1));
      expect(idsOf(views.single), ['a', 'b', 'c']);
      expect(views.single.buckets, [
        TimeBucket(date: DateTime(2024, 9, 14), assetCount: 2),
        TimeBucket(date: DateTime(2024, 9, 12), assetCount: 1),
      ]);
      expect(views.single.facets.total, 3);
      expect(service.latest, views.single);
      unawaited(service.dispose());
    });
  });

  test('applies a new filter from memory, without reading again', () {
    fakeAsync((async) {
      final service = newService();
      final views = <Panorama360View>[];
      service.views.listen(views.add);
      service.setSources(userId: 'me', forcedKeys: const {}, deviceIds: const {});
      service.setView(filter: const Panorama360Filter(), traitsOf: _noTraits);
      async.elapse(Duration.zero);

      service.setView(
        filter: const Panorama360Filter(kinds: {Panorama360Kind.video}),
        traitsOf: _noTraits,
      );
      async.flushMicrotasks();

      expect(views.map(idsOf), [
        ['a', 'b', 'c'],
        ['b'],
      ]);
      expect(views.last.facets.total, 3);
      expect(repository.remoteCalls, hasLength(1));
      expect(repository.deviceCalls, hasLength(1));
      unawaited(service.dispose());
    });
  });

  test('reads again after a change of the forced or found ids, and once per burst of database changes', () {
    fakeAsync((async) {
      final service = newService();
      service.setSources(userId: 'me', forcedKeys: const {}, deviceIds: const {});
      service.setView(filter: const Panorama360Filter(), traitsOf: _noTraits);
      async.elapse(Duration.zero);
      expect(repository.remoteCalls, hasLength(1));

      service.setSources(userId: 'me', forcedKeys: const {}, deviceIds: const {});
      async.elapse(const Duration(seconds: 1));
      expect(repository.remoteCalls, hasLength(1), reason: 'the same sources');

      service.setSources(userId: 'me', forcedKeys: const {'forced'}, deviceIds: const {});
      async.elapse(const Duration(milliseconds: 299));
      expect(repository.remoteCalls, hasLength(1), reason: 'waits for the burst to end');
      async.elapse(const Duration(milliseconds: 1));
      expect(repository.remoteCalls, hasLength(2));
      expect(repository.remoteCalls.last.forcedKeys, {'forced'});

      service.setSources(userId: 'me', forcedKeys: const {'forced'}, deviceIds: const {'found'});
      async.elapse(const Duration(milliseconds: 300));
      expect(repository.remoteCalls, hasLength(3));

      for (var change = 0; change < 5; change++) {
        repository.changes.add(null);
        async.elapse(const Duration(milliseconds: 50));
      }
      expect(repository.remoteCalls, hasLength(3));
      async.elapse(const Duration(milliseconds: 300));
      expect(repository.remoteCalls, hasLength(4));
      expect(repository.deviceCalls, hasLength(4));
      unawaited(service.dispose());
    });
  });

  test('without a server, reads the device only', () {
    fakeAsync((async) {
      final service = newService();
      final views = <Panorama360View>[];
      service.views.listen(views.add);
      service.setSources(forcedKeys: const {'forced'}, deviceIds: const {'found'});
      service.setView(
        filter: const Panorama360Filter(sources: {Panorama360Source.server}),
        traitsOf: _noTraits,
      );
      async.elapse(Duration.zero);

      expect(repository.remoteCalls, isEmpty);
      expect(repository.deviceCalls.single.ids, {'found', 'forced'});
      expect(repository.deviceCalls.single.userId, isNull);
      expect(idsOf(views.single), ['c'], reason: 'the sources do not apply without a server');
      unawaited(service.dispose());
    });
  });

  test('keeps the last list when a read fails', () {
    fakeAsync((async) {
      final service = newService();
      final views = <Panorama360View>[];
      service.views.listen(views.add);
      service.setSources(userId: 'me', forcedKeys: const {}, deviceIds: const {});
      service.setView(filter: const Panorama360Filter(), traitsOf: _noTraits);
      async.elapse(Duration.zero);

      repository.failure = Exception('database closed');
      repository.changes.add(null);
      async.elapse(const Duration(milliseconds: 300));

      expect(repository.remoteCalls, hasLength(2));
      expect(views, hasLength(1));
      expect(idsOf(service.latest!), ['a', 'b', 'c']);

      service.setView(
        filter: const Panorama360Filter(kinds: {Panorama360Kind.photo}),
        traitsOf: _noTraits,
      );
      async.flushMicrotasks();
      expect(idsOf(views.last), ['a', 'c'], reason: 'filtered from the last list read');
      unawaited(service.dispose());
    });
  });

  test('shows an empty list when the first read fails, and the list once a read succeeds', () {
    fakeAsync((async) {
      repository.failure = Exception('database closed');
      final service = newService();
      final views = <Panorama360View>[];
      service.views.listen(views.add);
      service.setSources(userId: 'me', forcedKeys: const {}, deviceIds: const {});
      service.setView(filter: const Panorama360Filter(), traitsOf: _noTraits);
      async.elapse(Duration.zero);

      expect(views.single.entries, isEmpty);

      repository.failure = null;
      repository.changes.add(null);
      async.elapse(const Duration(milliseconds: 300));
      expect(idsOf(views.last), ['a', 'b', 'c']);
      unawaited(service.dispose());
    });
  });

  test('does not emit again when a view change leaves the same entries', () {
    fakeAsync((async) {
      final service = newService();
      final views = <Panorama360View>[];
      service.views.listen(views.add);
      service.setSources(userId: 'me', forcedKeys: const {}, deviceIds: const {});
      service.setView(filter: const Panorama360Filter(), traitsOf: _noTraits);
      async.elapse(Duration.zero);

      // A store saving the progress of a scan gives a new reader, which tells the same
      service.setView(filter: const Panorama360Filter(), traitsOf: (entry) => const {});
      async.flushMicrotasks();
      expect(views, hasLength(1));

      // A database change reads again and always shows the result: a favourite changes no hero tag
      repository.changes.add(null);
      async.elapse(const Duration(milliseconds: 300));
      expect(views, hasLength(2));
      unawaited(service.dispose());
    });
  });

  test('replays the latest view to a late listener', () {
    fakeAsync((async) {
      final service = newService();
      service.setSources(userId: 'me', forcedKeys: const {}, deviceIds: const {});
      service.setView(filter: const Panorama360Filter(), traitsOf: _noTraits);
      async.elapse(Duration.zero);

      final lateViews = <Panorama360View>[];
      service.views.listen(lateViews.add);
      async.flushMicrotasks();
      expect(lateViews, hasLength(1));
      expect(idsOf(lateViews.single), ['a', 'b', 'c']);

      service.setView(
        filter: const Panorama360Filter(kinds: {Panorama360Kind.video}),
        traitsOf: _noTraits,
      );
      async.flushMicrotasks();
      expect(lateViews.map(idsOf), [
        ['a', 'b', 'c'],
        ['b'],
      ]);
      unawaited(service.dispose());
    });
  });

  test('stops reading and emitting once disposed', () {
    fakeAsync((async) {
      final service = newService();
      final views = <Panorama360View>[];
      var done = false;
      service.views.listen(views.add, onDone: () => done = true);
      service.setSources(userId: 'me', forcedKeys: const {}, deviceIds: const {});
      service.setView(filter: const Panorama360Filter(), traitsOf: _noTraits);
      async.elapse(Duration.zero);

      unawaited(service.dispose());
      async.flushMicrotasks();
      repository.changes.add(null);
      service.setSources(userId: 'me', forcedKeys: const {'forced'}, deviceIds: const {});
      async.elapse(const Duration(seconds: 1));

      expect(done, isTrue);
      expect(views, hasLength(1));
      expect(repository.remoteCalls, hasLength(1));
    });
  });

  test('gives the timeline the entries of the latest view, page by page', () {
    fakeAsync((async) {
      final service = newService();
      service.setSources(userId: 'me', forcedKeys: const {}, deviceIds: const {});
      service.setView(filter: const Panorama360Filter(), traitsOf: _noTraits);
      async.elapse(Duration.zero);

      final timeline = TimelineService(service.timelineQuery);
      async.flushMicrotasks();

      expect(timeline.origin, TimelineOrigin.panorama360);
      expect(timeline.totalAssets, 3);
      List<BaseAsset>? page;
      unawaited(timeline.loadAssets(0, 2).then((assets) => page = assets));
      async.flushMicrotasks();
      expect(page, [photo.asset, video.asset]);

      service.setView(
        filter: const Panorama360Filter(kinds: {Panorama360Kind.video}),
        traitsOf: _noTraits,
      );
      async.flushMicrotasks();
      expect(timeline.totalAssets, 1);
      expect(timeline.getAssetSafe(0), video.asset);

      unawaited(timeline.dispose());
      unawaited(service.dispose());
    });
  });
}
