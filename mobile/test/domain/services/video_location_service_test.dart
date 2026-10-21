import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/video_location.service.dart';

/// The server as the place step sees it: the states of the assets in order (the last one stays), the places set
class _FakeApi implements VideoLocationApi {
  final states = <String, List<AssetPlaceState?>>{};
  final failures = <String, int>{};
  final asked = <String>[];
  final set = <String, (double, double)>{};
  bool failSet = false;

  @override
  Future<AssetPlaceState?> placeState(String assetId) async {
    asked.add(assetId);
    final remaining = failures[assetId] ?? 0;
    if (remaining > 0) {
      failures[assetId] = remaining - 1;
      throw const SocketException('no network');
    }
    final list = states[assetId];
    if (list == null || list.isEmpty) {
      return null;
    }
    return list.length > 1 ? list.removeAt(0) : list.first;
  }

  @override
  Future<void> setLocation(String assetId, double latitude, double longitude) async {
    if (failSet) {
      throw const SocketException('no network');
    }
    set[assetId] = (latitude, longitude);
  }
}

const AssetPlaceState _notRead = (extracted: false, hasLocation: false);
const AssetPlaceState _readWithout = (extracted: true, hasLocation: false);
const AssetPlaceState _readWith = (extracted: true, hasLocation: true);

void main() {
  late Directory directory;
  late _FakeApi api;
  late DateTime now;
  late List<Duration> waits;

  VideoLocationService service({Duration timeout = const Duration(seconds: 90)}) => VideoLocationService(
    api,
    () async => File('${directory.path}/places.json'),
    timeout: timeout,
    now: () => now,
    delay: (duration) async {
      waits.add(duration);
      now = now.add(duration);
    },
  );

  setUp(() {
    directory = Directory.systemTemp.createTempSync('video_location');
    api = _FakeApi();
    now = DateTime.utc(2026, 10, 21, 15);
    waits = [];
  });

  tearDown(() => directory.deleteSync(recursive: true));

  test('sets the place when the server read the video and found none', () async {
    api.states['v1'] = [_readWithout];

    expect(await service().place('v1', 45.5, 6.5), VideoPlaceOutcome.placed);
    expect(api.set, {'v1': (45.5, 6.5)});
    expect(waits, isEmpty);
  });

  test('changes nothing when the video has a place of its own', () async {
    api.states['v1'] = [_readWith];

    expect(await service().place('v1', 45.5, 6.5), VideoPlaceOutcome.hadOwn);
    expect(api.set, isEmpty);
  });

  test('waits every 3 seconds while the server has not read the video', () async {
    api.states['v1'] = [_notRead, _notRead, _notRead, _readWithout];

    expect(await service().place('v1', 45.5, 6.5), VideoPlaceOutcome.placed);
    expect(waits, List.filled(3, const Duration(seconds: 3)));
    expect(api.set, {'v1': (45.5, 6.5)});
  });

  test('asks again after a failed request, as long as the wait lasts', () async {
    api
      ..states['v1'] = [_readWithout]
      ..failures['v1'] = 2;

    expect(await service().place('v1', 45.5, 6.5), VideoPlaceOutcome.placed);
    expect(api.asked, ['v1', 'v1', 'v1']);
  });

  test('a cancelled upload leaves the place to the pending list at once, without waiting for the server', () async {
    api.states['v1'] = [_notRead];
    final stop = Completer<void>();
    final sut = VideoLocationService(
      api,
      () async => File('${directory.path}/places.json'),
      now: () => now,
      // The waits between two looks never end by themselves: only the cancel ends this one
      delay: (_) => Completer<void>().future,
    );

    final outcome = sut.place('v1', 45.5, 6.5, stop: stop.future);
    await pumpEventQueue();
    stop.complete();

    expect(await outcome, VideoPlaceOutcome.pending);
    expect(api.asked, ['v1'], reason: 'the server is not asked again');
    expect((await sut.pending()).single.assetId, 'v1');
  });

  test('leaves the place to the pending list after 90 seconds, and sets it on a later pass', () async {
    api.states['v1'] = [_notRead];
    final sut = service();

    expect(await sut.place('v1', 45.5, 6.5), VideoPlaceOutcome.pending);
    expect(waits.fold(Duration.zero, (sum, wait) => sum + wait), const Duration(seconds: 90));
    expect((await sut.pending()).single.assetId, 'v1');
    expect(api.set, isEmpty);

    // Still not read: kept
    expect(await sut.retryPending(), 0);
    expect(await sut.pending(), hasLength(1));

    api.states['v1'] = [_readWithout];
    expect(await sut.retryPending(), 1);
    expect(api.set, {'v1': (45.5, 6.5)});
    expect(await sut.pending(), isEmpty);
    expect(File('${directory.path}/places.json').existsSync(), isFalse);
  });

  test('the pending list survives a new service, drops assets gone and places too old', () async {
    api.states['v1'] = [_notRead];
    api.states['v2'] = [_notRead];
    await service(timeout: Duration.zero).place('v1', 45.5, 6.5);
    await service(timeout: Duration.zero).place('v2', 44.5, 5.5);
    await service(timeout: Duration.zero).place('v3', 43.5, 4.5).then((outcome) {
      expect(outcome, VideoPlaceOutcome.failed, reason: 'v3 is not on the server');
    });

    final later = service();
    expect((await later.pending()).map((place) => place.assetId), ['v1', 'v2']);
    api.states.remove('v1');
    api.states['v2'] = [_readWith];
    expect(await later.retryPending(), 0);
    expect(await later.pending(), isEmpty, reason: 'v1 is gone, v2 had a place of its own');

    api.states['v4'] = [_notRead];
    await service(timeout: Duration.zero).place('v4', 42.5, 3.5);
    now = now.add(const Duration(days: 31));
    expect(await later.retryPending(), 0);
    expect(await later.pending(), isEmpty, reason: 'waiting for more than 30 days');
  });

  test('keeps the place in the pending list when setting it fails', () async {
    api
      ..states['v1'] = [_readWithout]
      ..failSet = true;
    final sut = service();

    expect(await sut.place('v1', 45.5, 6.5), VideoPlaceOutcome.pending);
    expect(await sut.pending(), hasLength(1));

    api.failSet = false;
    expect(await sut.retryPending(), 1);
    expect(api.set, {'v1': (45.5, 6.5)});
  });

  test('several videos placed at once keep every pending place', () async {
    for (final id in ['a', 'b', 'c']) {
      api.states[id] = [_notRead];
    }
    final sut = service(timeout: Duration.zero);

    await Future.wait([sut.place('a', 1, 1), sut.place('b', 2, 2), sut.place('c', 3, 3)]);

    expect((await sut.pending()).map((place) => place.assetId), unorderedEquals(['a', 'b', 'c']));
  });

  test('a duplicate asset is placed like a new one', () async {
    // The server answers "duplicate" with the id of the asset it had, read long ago
    api.states['old'] = [_readWithout];

    expect(await service().place('old', 45.5, 6.5), VideoPlaceOutcome.placed);
    expect(api.set, {'old': (45.5, 6.5)});
  });
}
