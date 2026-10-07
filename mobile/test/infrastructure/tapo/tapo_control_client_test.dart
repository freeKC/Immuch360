// The control API of a camera through the fake camera: the multipleRequest of the read methods, the allowlist, one new
// login when the camera ended the session and never more, a refused password or a lockout remembered and never sent
// again on its own, no login without a pinned certificate outside the test of the camera, the session left for the
// next connection, the answers kept a while, the days and their 31 day chunks, the clips of a day in the camera's zone
// (23 and 25 hour days), paging and the fallbacks of the older listings.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_control_client.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_login.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_session_cache.dart';
import 'package:timezone/data/latest.dart';

import 'fake_tapo_camera.dart';

const _password = 'synthetic-cloud-password';
const _sourceId = '0123456789abcdef';

void main() {
  setUpAll(initializeTimeZones);

  late TapoSessionCache cache;
  setUp(() => cache = TapoSessionCache());

  TapoControlClient client(
    FakeTapoCamera camera, {
    TapoCameraInfo known = const TapoCameraInfo(certificateSha256: fakeCameraCertificate),
    DateTime Function()? clock,
    String sourceId = _sourceId,
    bool trustFirstCertificate = false,
    TapoCertificateReader? certificateReader,
  }) => TapoControlClient(
    sourceId: sourceId,
    host: fakeCameraHost,
    password: _password,
    known: known,
    transport: (host, pin) => camera,
    login: (transport) =>
        TapoLogin(transport, spake2p: (input) async => spake2pClient(input), reloginDelay: Duration.zero),
    cache: cache,
    clock: clock,
    trustFirstCertificate: trustFirstCertificate,
    certificateReader: certificateReader ?? (host) async => fail('no certificate read with a pin'),
  );

  test('reads the details, the card and learns what the login and the camera told', () async {
    final camera = FakeTapoCamera();
    final control = client(camera);
    final details = await control.details();
    expect(details.alias, 'Garden');
    expect(details.model, 'C200');
    expect(details.mac, fakeCameraMac);
    expect(details.zoneId, 'Europe/Brussels');
    final card = await control.cardStatus();
    expect(card.state, TapoCardState.normal);
    expect(card.totalBytes, 119453777920);
    expect(card.usedBytes, 119453777920 - 124926940);
    expect(card.oldestRecording, DateTime.utc(2026, 5, 23, 9, 18, 8));
    expect(control.info.protocol, TapoLoginProtocol.v4);
    expect(control.info.passcode, TapoPasscodeHash.md5);
    expect(control.info.model, 'C200');
    expect(control.info.zoneId, 'Europe/Brussels');
    expect(control.info.certificateSha256, fakeCameraCertificate);
    expect(control.isVerified, isTrue);
    // Both methods in one request
    expect(camera.calls.take(2), ['getDeviceInfo', 'getTimezone']);
  });

  test('refuses a method that is not a read method before anything is sent', () async {
    final camera = FakeTapoCamera();
    final control = client(camera);
    expect(() => control.call([(method: 'setLocalCtrl', params: const {})]), throwsArgumentError);
    expect(camera.bodies, isEmpty);
  });

  test('logs in once more when the camera ended the session, and only once', () async {
    final camera = FakeTapoCamera();
    final control = client(camera);
    await control.cardStatus();
    camera.killSession();
    await control.cardStatus(refresh: true);
    expect(camera.logins, 2);

    // Ended again right after each login: the request fails after one new login, never a third one
    final stubborn = FakeTapoCamera()..refuseRequests = true;
    final other = client(stubborn, sourceId: 'fedcba9876543210');
    await expectLater(other.cardStatus(), throwsA(isA<TapoCameraException>().having((e) => e.code, 'code', -40401)));
    expect(stubborn.logins, 2);
  });

  test('tries once more after a network failure, then tells the camera unreachable', () async {
    final camera = FakeTapoCamera()..failNextPosts = 1;
    await client(camera).details();
    expect(camera.logins, 1);

    final silent = FakeTapoCamera()..failNextPosts = 10;
    await expectLater(
      client(silent, sourceId: 'fedcba9876543210').details(),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.unreachable)),
    );
  });

  test('does not try a refused password again until the user asks again', () async {
    final camera = FakeTapoCamera(cloudPassword: 'another');
    final control = client(camera);
    await expectLater(
      control.details(),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.wrongPassword)),
    );
    expect(camera.shares, 2);
    // The other calls of the camera page, and a connection opened again for the same camera and password
    await expectLater(
      control.days(),
      throwsA(isA<TapoCameraException>().having((e) => e.attemptsLeft, 'attempts left', 3)),
    );
    await expectLater(control.ensureLoggedIn(), throwsA(isA<TapoCameraException>()));
    await expectLater(client(camera).cardStatus(), throwsA(isA<TapoCameraException>()));
    expect(camera.shares, 2);
    expect(camera.bodies, hasLength(2 + 2 + 1));

    // Retry or "Test the camera": once more, and remembered again
    control.forgetRefusals();
    await expectLater(control.details(), throwsA(isA<TapoCameraException>()));
    await expectLater(control.days(), throwsA(isA<TapoCameraException>()));
    expect(camera.shares, 4);

    // Another password is another login
    camera.cloudPassword = _password;
    final other = TapoControlClient(
      sourceId: _sourceId,
      host: fakeCameraHost,
      password: 'another',
      known: const TapoCameraInfo(certificateSha256: fakeCameraCertificate),
      transport: (host, pin) => camera,
      login: (transport) =>
          TapoLogin(transport, spake2p: (input) async => spake2pClient(input), reloginDelay: Duration.zero),
      cache: cache,
    );
    await expectLater(other.details(), throwsA(isA<TapoCameraException>()));
    expect(camera.shares, 6);
  });

  test('shares one login between the calls made at once with a refused password', () async {
    final camera = FakeTapoCamera(cloudPassword: 'another');
    final control = client(camera);
    final results = await Future.wait([
      control.details().then<Object?>((_) => null, onError: (Object error) => error),
      control.cardStatus().then<Object?>((_) => null, onError: (Object error) => error),
      control.days().then<Object?>((_) => null, onError: (Object error) => error),
      control.ensureLoggedIn().then<Object?>((_) => null, onError: (Object error) => error),
    ]);
    expect(results, everyElement(isA<TapoCameraException>()));
    expect(camera.shares, 2);
  });

  test('remembers a lockout with the minutes left, never asking the camera on its own', () async {
    var now = DateTime.utc(2026, 9, 19, 10);
    final camera = FakeTapoCamera()
      ..lockout = {
        'error_code': -40404,
        'error_info': {'failedAttempts': 5, 'remainAttempts': 0, 'lockedMinute': 30},
      };
    final control = client(camera, clock: () => now);
    await expectLater(
      control.details(),
      throwsA(isA<TapoCameraException>().having((e) => e.lockedMinutes, 'minutes', 30)),
    );
    final sent = camera.bodies.length;
    now = now.add(const Duration(minutes: 10, seconds: 30));
    await expectLater(
      control.cardStatus(),
      throwsA(
        isA<TapoCameraException>()
            .having((e) => e.kind, 'kind', TapoErrorKind.locked)
            .having((e) => e.lockedMinutes, 'minutes', 20),
      ),
    );
    now = now.add(const Duration(minutes: 30));
    await expectLater(
      control.cardStatus(),
      throwsA(isA<TapoCameraException>().having((e) => e.lockedMinutes, 'minutes', isNull)),
    );
    expect(camera.bodies, hasLength(sent));
  });

  test('logs in without a pinned certificate only for the test of the camera', () async {
    final camera = FakeTapoCamera();
    final read = <String>[];
    final control = client(
      camera,
      known: const TapoCameraInfo(),
      certificateReader: (host) async {
        read.add(host);
        return fakeCameraCertificate;
      },
    );
    // The certificate shown, for the user to accept; nothing sent to the camera
    await expectLater(
      control.details(),
      throwsA(
        isA<TapoCameraException>()
            .having((e) => e.kind, 'kind', TapoErrorKind.certificateChanged)
            .having((e) => e.certificateSha256, 'certificate', fakeCameraCertificate),
      ),
    );
    expect(read, [fakeCameraHost]);
    expect(camera.bodies, isEmpty);
    expect(control.isVerified, isFalse);

    // A camera that does not answer
    final silent = client(
      camera,
      known: const TapoCameraInfo(),
      sourceId: 'fedcba9876543210',
      certificateReader: (host) async => null,
    );
    await expectLater(
      silent.details(),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.unreachable)),
    );
    expect(camera.bodies, isEmpty);

    // "Test the camera" trusts the first certificate, and keeps it
    final tester = client(camera, known: const TapoCameraInfo(), trustFirstCertificate: true);
    await tester.details();
    expect(tester.info.certificateSha256, fakeCameraCertificate);
    expect(tester.isVerified, isTrue);
  });

  test('leaves its session to the next connection of the same camera and password', () async {
    final camera = FakeTapoCamera();
    final first = client(camera);
    await first.check();
    first.close();
    final second = client(camera);
    await second.days();
    expect(camera.logins, 1);
    expect(second.info.protocol, TapoLoginProtocol.v4);
    expect(second.info.model, 'C200');
  });

  test('keeps the answers a while: the card 30 s, the days 120 s, the clips of a day 20 s', () async {
    var now = DateTime.utc(2026, 9, 19, 10);
    final camera = FakeTapoCamera();
    final control = client(camera, clock: () => now);
    await control.cardStatus();
    await control.cardStatus();
    expect(camera.calls.where((call) => call == 'getSdCardStatus'), hasLength(1));
    now = now.add(const Duration(seconds: 31));
    await control.cardStatus();
    expect(camera.calls.where((call) => call == 'getSdCardStatus'), hasLength(2));
    await control.days();
    now = now.add(const Duration(seconds: 100));
    await control.days();
    expect(camera.calls.where((call) => call == 'searchDateWithVideo'), hasLength(1));
    await control.days(refresh: true);
    expect(camera.calls.where((call) => call == 'searchDateWithVideo'), hasLength(2));
  });

  test('lists the days newest first, in one request, then 31 days at a time on -71105', () async {
    final now = DateTime.utc(2026, 9, 19, 10);
    final camera = FakeTapoCamera();
    expect(await client(camera, clock: () => now).days(), ['2026-09-18', '2026-09-17']);
    expect(camera.calls.where((call) => call == 'searchDateWithVideo'), hasLength(1));

    final ranges = <(String, String)>[];
    final full = FakeTapoCamera(
      methods: {
        ...defaultFakeMethods(),
        'searchDateWithVideo': (params) {
          final query = ((params['playback']! as Map)['search_year_utility'] as Map).cast<String, Object?>();
          final range = ('${query['start_date']}', '${query['end_date']}');
          ranges.add(range);
          if (ranges.length == 1) {
            return -71105;
          }
          return {
            'playback': {
              'search_results': [
                {
                  'search_results_1': {'date': range.$2},
                },
              ],
            },
          };
        },
      },
    );
    final days = await client(full, clock: () => now, sourceId: 'fedcba9876543210').days();
    // The span of 731 days: the wide request, then 24 chunks of 31 days, the newest first
    expect(ranges.first, ('20240919', '20260920'));
    expect(ranges[1], ('20260821', '20260920'));
    expect(ranges[2], ('20260721', '20260820'));
    expect(ranges.length, 1 + 24);
    expect(days.first, '2026-09-20');
    expect(days, orderedEquals([...days]..sort((a, b) => b.compareTo(a))));
  });

  test('lists the days when the card asked at the same time fails', () async {
    final camera = FakeTapoCamera(methods: {...defaultFakeMethods(), 'getSdCardStatus': (_) => -40106});
    final control = client(camera, clock: () => DateTime.utc(2026, 9, 19, 10));
    // As the camera page does: the details and the card, and the days, which wait for the card for its oldest day
    final details = control.details();
    final card = control.cardStatus();
    final days = control.days();
    await details;
    await expectLater(card, throwsA(isA<TapoCameraException>()));
    expect(await days, ['2026-09-18', '2026-09-17']);
  });

  test('bounds a day in the camera zone, also on the days of the clock changes', () async {
    final zone = TapoZone.of('Europe/Brussels');
    expect(zone.startOfDay(2026, 9, 18), DateTime.utc(2026, 9, 17, 22));
    // 23 hours on 2026-03-29, 25 hours on 2026-10-25
    expect(zone.startOfDay(2026, 3, 30).difference(zone.startOfDay(2026, 3, 29)), const Duration(hours: 23));
    expect(zone.startOfDay(2026, 10, 26).difference(zone.startOfDay(2026, 10, 25)), const Duration(hours: 25));
    expect(zone.dayOf(DateTime.utc(2026, 9, 17, 22, 30)), '2026-09-18');
    // A zone the data does not know: its standard offset; nothing: the zone of the device
    expect(
      TapoZone.of('Nowhere/Unknown', offsetText: 'UTC+01:00').startOfDay(2026, 7, 1),
      DateTime.utc(2026, 6, 30, 23),
    );
  });

  test('lists the clips of a day with the bounds of the zone, oldest first, with their kind and path', () async {
    final camera = FakeTapoCamera();
    final clips = await client(camera).clips('2026-09-18');
    expect(clips.map((clip) => clip.path), [
      '/2026-09-18/1789683060-1789683144.mov',
      '/2026-09-18/1789700000-1789700060.mov',
      '/2026-09-18/1789750000-1789750600.mov',
    ]);
    expect(clips.map((clip) => clip.kind), [TapoClipKind.motion, TapoClipKind.person, TapoClipKind.continuous]);
    expect(clips.first.duration, const Duration(seconds: 84));
    expect(clips.first.start, DateTime.utc(2026, 9, 17, 22, 11));
  });

  test('pages the clips while the camera says to be continued', () async {
    final many = [for (var i = 0; i < 250; i++) (1789683000 + i * 100, 1789683000 + i * 100 + 30, '2')];
    final camera = FakeTapoCamera(methods: defaultFakeMethods(clipsByDay: {'2026-09-18': many}));
    final clips = await client(camera).clips('2026-09-18');
    expect(clips, hasLength(250));
    expect(camera.calls.where((call) => call == 'searchVideoWithUTC'), hasLength(3));
  });

  test('asks with the user id on -71103 and with the legacy listing on a playback 1 camera', () async {
    final asked = <Map>[];
    final methods = defaultFakeMethods();
    final utc = methods['searchVideoWithUTC']!;
    final camera = FakeTapoCamera(
      methods: {
        ...methods,
        'getUserID': (_) => {'user_id': 1},
        'searchVideoWithUTC': (params) {
          final query = (params['playback']! as Map)['search_video_with_utc'] as Map;
          asked.add(query);
          return query.containsKey('player_id') ? -71103 : utc(params);
        },
      },
    );
    expect(await client(camera).clips('2026-09-18'), hasLength(3));
    expect(asked.first['player_id'], tapoPlayerId(_sourceId));
    expect(asked.last['id'], 1);

    final legacy = FakeTapoCamera(
      methods: {
        ...defaultFakeMethods(playback: 1),
        'getUserID': (_) => {'user_id': 1},
        'searchVideoOfDay': (params) => {
          'playback': {
            'search_video_results': [
              {
                'search_video_results_1': {'startTime': 1789683060, 'endTime': 1789683144, 'vedio_type': 7},
              },
            ],
          },
        },
      },
    );
    final clips = await client(legacy, sourceId: 'fedcba9876543210').clips('2026-09-18');
    expect(clips.single.kind, TapoClipKind.babyCry);
  });

  test('derives a stable player id of 32 upper case hex digits per camera', () {
    expect(tapoPlayerId(_sourceId), matches(RegExp(r'^[0-9A-F]{32}$')));
    expect(tapoPlayerId(_sourceId), tapoPlayerId(_sourceId));
    expect(tapoPlayerId('fedcba9876543210'), isNot(tapoPlayerId(_sourceId)));
  });

  test('reads a camera without a memory card', () async {
    final camera = FakeTapoCamera(
      methods: {
        ...defaultFakeMethods(),
        'getSdCardStatus': (_) => {
          'harddisk_manage': {'hd_info': <Object>[]},
        },
      },
    );
    expect((await client(camera).cardStatus()).state, TapoCardState.absent);
  });
}
