// The page of a camera: the live tile (the camera account through the API, the SD stream on a phone, HD in full screen,
// the sound, the Live badge, Back leaving full screen first), the model and the memory card, the days by month, the
// cache, what a login learned saved with the camera, a new certificate asked to the user, a camera found again at a new
// address (asked to the user when no certificate was pinned yet), Retry asking the camera again after a refusal,
// nothing read without the TP-Link password, and the live view announced for later on iPhone and on a computer.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/domain/services/network_source_relocator.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/platform/camera_live_api.g.dart';
import 'package:immich_mobile/presentation/pages/camera/camera.page.dart';
import 'package:immich_mobile/providers/network/network_discovery.provider.dart';
import 'package:immich_mobile/providers/tapo/tapo_camera.provider.dart';

import 'camera_fakes.dart';

class _FakeRelocator extends NetworkSourceRelocator {
  _FakeRelocator(this.result) : super(NetworkDiscoveryService(probes: const []));

  final NetworkSource? result;
  int calls = 0;

  @override
  Future<NetworkSource?> relocate(NetworkSource source, {Duration timeout = const Duration(seconds: 5)}) async {
    calls++;
    return result;
  }
}

const _pin = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

void main() {
  late CameraTestStorage storage;
  late FakeTapoRecordings recordings;
  late FakeCameraLiveApi live;

  setUp(() {
    recordings = FakeTapoRecordings();
    live = FakeCameraLiveApi();
  });

  tearDown(() => storage.dispose());

  Future<void> pump(
    WidgetTester tester, {
    NetworkSource? source,
    String? cloudPassword = cameraCloudPassword,
    String? accountPassword = cameraAccountPassword,
    _FakeRelocator? relocator,
    Future<String?> Function(String host)? certificateReader,
    void Function(String sourceId)? forgetRefusals,
  }) async {
    storage = await CameraTestStorage.create(
      sources: [source ?? cameraSource()],
      cloudPassword: cloudPassword,
      accountPassword: accountPassword,
    );
    await pumpCameraApp(
      tester,
      home: const CameraPage(sourceId: cameraId),
      overrides: [
        ...storage.overrides,
        ...cameraOverrides(
          recordings: recordings,
          live: live,
          certificateReader: certificateReader,
          forgetRefusals: forgetRefusals,
        ),
        if (relocator != null) networkSourceRelocatorProvider.overrideWithValue(relocator),
      ],
    );
  }

  testWidgets('plays the SD stream with the camera account, muted, through the live view API', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('camera_platform_view')), findsOneWidget);
    final (viewId, source) = live.sources.single;
    expect(viewId, cameraViewId);
    expect(source.url, 'rtsp://$cameraHost:554/stream2');
    expect(source.username, 'viewer');
    expect(source.password, cameraAccountPassword);
    expect(source.isHls, isFalse);
    expect(live.mutes.single, (cameraViewId, true));
    expect(find.text('Connecting to the camera'), findsOneWidget);

    ref(tester).read(cameraLiveEventsProvider).stateChanged(cameraViewId, CameraLiveState.playing, null, true);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('camera_live_badge')), findsOneWidget);
    expect(find.text('Connecting to the camera'), findsNothing);

    await tester.tap(find.byKey(const Key('camera_live_sound')));
    await tester.pumpAndSettle();
    expect(live.mutes.last, (cameraViewId, false));
  });

  testWidgets('says when the device cannot play the sound', (tester) async {
    await pump(tester);
    ref(tester).read(cameraLiveEventsProvider).stateChanged(cameraViewId, CameraLiveState.playing, null, false);
    await tester.pumpAndSettle();
    final button = tester.widget<IconButton>(find.byKey(const Key('camera_live_sound')));
    expect(button.onPressed, isNull);
    expect(button.tooltip, 'No sound on this device');
  });

  testWidgets('goes full screen in HD, and Back leaves full screen first', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('camera_live_full_screen')));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsNothing);
    expect(live.sources.last.$2.url, 'rtsp://$cameraHost:554/stream1');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(CameraPage), findsOneWidget);
    expect(live.sources.last.$2.url, 'rtsp://$cameraHost:554/stream2');
  });

  testWidgets('asks for the camera account when there is none', (tester) async {
    await pump(tester, source: cameraSource(username: ''), accountPassword: null);
    expect(find.text('Add the camera account to see the live view.'), findsOneWidget);
    expect(live.sources, isEmpty);
  });

  testWidgets('tells that the live view comes later on iPhone and iPad', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await pump(tester);
      expect(find.byKey(const Key('camera_live_later')), findsOneWidget);
      expect(live.sources, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('tells that the live view comes later on a computer, without an Android view', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pump(tester);
      expect(find.byKey(const Key('camera_live_later')), findsOneWidget);
      expect(find.text('The live view comes to Immuch360 Desktop in a later version.'), findsOneWidget);
      expect(find.byType(PlatformViewLink), findsNothing);
      expect(find.byKey(const Key('camera_platform_view')), findsNothing);
      expect(find.byKey(const Key('camera_live_full_screen')), findsNothing);
      expect(live.sources, isEmpty);
      // The recordings stay
      expect(find.byKey(const Key('camera_day_2026-09-18')), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('shows the model, the memory card and the days by month; a day opens its page', (tester) async {
    await pump(tester);
    expect(find.text('C200, firmware 1.4.6'), findsOneWidget);
    expect(find.text('Memory card: 64.0 GiB used of 128.0 GiB'), findsOneWidget);
    expect(find.text('September 2026'), findsOneWidget);
    expect(find.text('August 2026'), findsOneWidget);
    expect(find.byKey(const Key('camera_day_2026-09-18')), findsOneWidget);
    expect(find.text('Friday, September 18, 2026'), findsOneWidget);
    await tester.tap(find.byKey(const Key('camera_day_2026-09-17')));
    await tester.pumpAndSettle();
    expect(find.text('day $cameraId 2026-09-17'), findsOneWidget);
  });

  testWidgets('reads nothing from the camera without the TP-Link password', (tester) async {
    await pump(tester, cloudPassword: null);
    expect(find.byKey(const Key('camera_recordings_needs_password')), findsOneWidget);
    expect(recordings.detailsCalls, 0);
    expect(recordings.daysRefreshes, isEmpty);
  });

  testWidgets('refreshes the days from the app bar, and clears the cache', (tester) async {
    recordings.cacheSize = 5 * 1024 * 1024;
    await pump(tester);
    expect(find.text('5.0 MiB of videos on this device'), findsOneWidget);
    await tester.tap(find.byKey(const Key('camera_refresh')));
    await tester.pumpAndSettle();
    expect(recordings.daysRefreshes, contains(true));
    await tester.tap(find.byKey(const Key('camera_cache')));
    await tester.pumpAndSettle();
    expect(recordings.cleared, 1);
    expect(find.byKey(const Key('camera_cache')), findsNothing);
  });

  testWidgets('says when the card holds nothing', (tester) async {
    recordings.daysList = const [];
    await pump(tester);
    expect(find.byKey(const Key('camera_days_empty')), findsOneWidget);
  });

  testWidgets('saves what the connection learned of the camera', (tester) async {
    recordings.info = const TapoCameraInfo(
      model: 'C200',
      firmware: '1.4.7',
      zoneId: 'Europe/Brussels',
      protocol: TapoLoginProtocol.v4,
      passcode: TapoPasscodeHash.sha256,
      certificateSha256: _pin,
    );
    await pump(tester);
    final saved = storage.storedSources.single.camera!;
    expect(saved.firmware, '1.4.7');
    expect(saved.protocol, TapoLoginProtocol.v4);
    expect(saved.passcode, TapoPasscodeHash.sha256);
    expect(saved.certificateSha256, _pin);
  });

  testWidgets('asks before keeping a new certificate', (tester) async {
    const changed = 'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100';
    recordings.daysError = const TapoCameraException(TapoErrorKind.certificateChanged, certificateSha256: changed);
    await pump(
      tester,
      source: cameraSource(camera: const TapoCameraInfo(certificateSha256: _pin)),
    );
    expect(
      find.text(
        'The camera at $cameraHost shows another certificate than before. Continue only if you reset or replaced it.',
      ),
      findsWidgets,
    );
    await tester.tap(find.byKey(const Key('camera_certificate_continue')));
    await tester.pumpAndSettle();
    expect(storage.storedSources.single.camera?.certificateSha256, changed);
  });

  testWidgets(
    'finds a camera that moved by its MAC address and keeps the new address when its certificate is the same',
    (tester) async {
      recordings.daysError = const TapoCameraException(TapoErrorKind.unreachable);
      final source = cameraSource(camera: const TapoCameraInfo(certificateSha256: _pin));
      final relocator = _FakeRelocator(source.copyWith(host: '192.0.2.31'));
      final asked = <String>[];
      await pump(
        tester,
        source: source,
        relocator: relocator,
        certificateReader: (host) async {
          asked.add(host);
          // The camera answers at its new address
          recordings.daysError = null;
          return _pin;
        },
      );
      expect(relocator.calls, 1);
      expect(asked, ['192.0.2.31']);
      expect(storage.storedSources.single.host, '192.0.2.31');
      expect(find.text('The camera does not answer at 192.0.2.31.'), findsNothing);
    },
  );

  testWidgets('asks before moving a camera whose certificate was never pinned', (tester) async {
    recordings.daysError = const TapoCameraException(TapoErrorKind.unreachable);
    final source = cameraSource(camera: const TapoCameraInfo());
    await pump(
      tester,
      source: source,
      relocator: _FakeRelocator(source.copyWith(host: '192.0.2.31')),
      certificateReader: (host) async => _pin,
    );
    expect(
      find.text(
        'The camera at 192.0.2.31 shows another certificate than before. Continue only if you reset or replaced it.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('camera_certificate_continue')));
    await tester.pumpAndSettle();
    expect(storage.storedSources.single.host, '192.0.2.31');
    expect(storage.storedSources.single.camera?.certificateSha256, _pin);
  });

  testWidgets('asks the camera again on Retry after a refused password', (tester) async {
    recordings.daysError = const TapoCameraException(TapoErrorKind.wrongPassword, attemptsLeft: 3);
    final forgotten = <String>[];
    await pump(tester, forgetRefusals: forgotten.add);
    expect(find.byKey(const Key('camera_days_error')), findsOneWidget);
    // Refreshing alone does not ask the camera again: the refusal stays remembered
    await tester.tap(find.byKey(const Key('camera_refresh')));
    await tester.pumpAndSettle();
    expect(forgotten, isEmpty);
    recordings.daysError = null;
    await tester.tap(find.byKey(const Key('camera_days_retry')));
    await tester.pumpAndSettle();
    expect(forgotten, [cameraId]);
    expect(find.byKey(const Key('camera_day_2026-09-18')), findsOneWidget);
  });

  testWidgets('does not move a camera to an address that shows another certificate without the user', (tester) async {
    recordings.daysError = const TapoCameraException(TapoErrorKind.unreachable);
    final source = cameraSource(camera: const TapoCameraInfo(certificateSha256: _pin));
    await pump(
      tester,
      source: source,
      relocator: _FakeRelocator(source.copyWith(host: '192.0.2.31')),
      certificateReader: (host) async => 'ab' * 32,
    );
    expect(
      find.text(
        'The camera at 192.0.2.31 shows another certificate than before. Continue only if you reset or replaced it.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(storage.storedSources.single.host, cameraHost);
    expect(find.text('The camera does not answer at $cameraHost.'), findsOneWidget);
  });
}

/// The provider container of the app under test
ProviderContainer ref(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(CameraPage)));
