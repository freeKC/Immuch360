// The page that adds, edits and removes a camera: the cameras found on the network (with the login they announce), at
// least one secret, "Test the camera" once per press with the id the camera will have, what the test learned saved
// with it, the certificate pinned at a save without a test, the secrets stored for this device only, the certificate
// change asked to the user, and the fields reached with a remote.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/presentation/pages/camera/camera_edit.page.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_text_entry.widget.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/routing/router.dart';

import 'camera_fakes.dart';

const _foundCamera = DiscoveredServer(
  host: cameraHost,
  displayName: 'Tapo C510W',
  type: NetworkSourceType.tapo,
  port: 443,
  useTls: true,
  origin: DiscoveryOrigin.tdp,
  discoveryId: cameraMac,
  camera: TapoCameraInfo(protocol: TapoLoginProtocol.v4),
);

const _foundShare = DiscoveredServer(
  host: '192.0.2.10',
  displayName: 'NAS',
  type: NetworkSourceType.smb,
  port: 445,
  origin: DiscoveryOrigin.scan,
);

const _learned = TapoCameraInfo(
  model: 'C510W',
  firmware: '1.3.4',
  protocol: TapoLoginProtocol.v4,
  passcode: TapoPasscodeHash.md5,
  zoneId: 'Europe/Brussels',
  certificateSha256: '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff',
);

void main() {
  late CameraTestStorage storage;
  late List<TapoTestRequest> requests;
  late List<TapoTestResult> results;

  Future<TapoTestResult> tester(TapoTestRequest request) async {
    requests.add(request);
    return results.isEmpty ? const TapoTestResult() : results.removeAt(0);
  }

  tearDown(() => storage.dispose());

  Future<void> pump(
    WidgetTester tester_, {
    NetworkSource? source,
    bool tv = false,
    TapoCertificateReader? certificateReader,
  }) async {
    await pumpCameraApp(
      tester_,
      home: CameraEditPage(source: source),
      overrides: [
        ...storage.overrides,
        ...cameraOverrides(tester: tester, found: [_foundCamera, _foundShare], certificateReader: certificateReader),
        if (tv) tvModeProvider.overrideWith((ref) => true),
      ],
    );
  }

  setUp(() {
    requests = [];
    results = [];
  });

  testWidgets('shows the cameras found on the network only, and fills the page with the one tapped', (tester_) async {
    storage = await CameraTestStorage.create();
    await pump(tester_);
    expect(find.text('Tapo C510W'), findsOneWidget);
    expect(find.text('NAS'), findsNothing);
    await tester_.tap(find.text('Tapo C510W'));
    await tester_.pumpAndSettle();
    expect(find.widgetWithText(TextField, cameraHost), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Tapo C510W'), findsOneWidget);
  });

  testWidgets('asks for at least one of the two secrets', (tester_) async {
    storage = await CameraTestStorage.create();
    await pump(tester_);
    await tester_.enterText(find.byKey(const Key('camera_host')), cameraHost);
    await tester_.pumpAndSettle();
    await tester_.tap(find.byKey(const Key('camera_test')));
    await tester_.pumpAndSettle();
    expect(find.byKey(const Key('camera_needs_a_password')), findsOneWidget);
    expect(requests, isEmpty);
    await tester_.ensureVisible(find.byKey(const Key('camera_save')));
    await tester_.tap(find.byKey(const Key('camera_save')));
    await tester_.pumpAndSettle();
    expect(storage.storedSources, isEmpty);
  });

  testWidgets('tests the camera once per press, with the id it will have, and saves what the test learned', (
    tester_,
  ) async {
    storage = await CameraTestStorage.create();
    results.add(
      const TapoTestResult(
        details: TapoCameraDetails(alias: 'Garden', model: 'C510W', firmware: '1.3.4', mac: cameraMac),
        card: TapoCardStatus(state: TapoCardState.normal, status: 'normal', usedBytes: 1 << 30, totalBytes: 1 << 34),
        info: _learned,
        live: TapoLiveProbe(video: 'H264', audio: 'PCMA'),
      ),
    );
    await pump(tester_);
    await tester_.tap(find.text('Tapo C510W'));
    await tester_.pumpAndSettle();
    await tester_.enterText(find.byKey(const Key('camera_name')), '');
    await tester_.enterText(find.byKey(const Key('camera_cloud_password')), cameraCloudPassword);
    await tester_.enterText(find.byKey(const Key('camera_account_user')), 'viewer');
    await tester_.enterText(find.byKey(const Key('camera_account_password')), cameraAccountPassword);
    await tester_.pumpAndSettle();
    await tester_.ensureVisible(find.byKey(const Key('camera_test')));
    await tester_.tap(find.byKey(const Key('camera_test')));
    await tester_.pumpAndSettle();

    expect(requests, hasLength(1));
    final request = requests.single;
    expect(request.host, cameraHost);
    // What the camera announced leads its first login
    expect(request.known?.protocol, TapoLoginProtocol.v4);
    expect(request.cloudPassword, cameraCloudPassword);
    expect(request.cameraUser, 'viewer');
    expect(request.cameraPassword, cameraAccountPassword);
    expect(request.sourceId, matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(find.text('Recordings: C510W, firmware 1.3.4'), findsOneWidget);
    expect(find.text('Live view: H264, sound PCMA'), findsOneWidget);
    expect(find.byKey(const Key('camera_card_badge')), findsOneWidget);
    // The name of the camera in the Tapo app
    expect(find.widgetWithText(TextField, 'Garden'), findsOneWidget);

    await tester_.ensureVisible(find.byKey(const Key('camera_save')));
    await tester_.tap(find.byKey(const Key('camera_save')));
    await tester_.pumpAndSettle();
    final saved = storage.storedSources.single;
    expect(saved.id, request.sourceId);
    expect(saved.type, NetworkSourceType.tapo);
    expect(saved.name, 'Garden');
    expect(saved.host, cameraHost);
    expect(saved.username, 'viewer');
    expect(saved.discoveryId, cameraMac);
    expect(saved.camera, _learned);
    expect(storage.secureStorage.values[saved.secretKey], cameraCloudPassword);
    expect(storage.secureStorage.values[saved.cameraSecretKey], cameraAccountPassword);
    expect(storage.secureStorage.writtenDeviceOnly, {saved.secretKey, saved.cameraSecretKey});
  });

  testWidgets('pins the certificate the camera shows when saved without a test, and only then', (tester_) async {
    storage = await CameraTestStorage.create();
    final read = <String>[];
    const shown = 'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100';
    await pump(
      tester_,
      certificateReader: (host) async {
        read.add(host);
        return shown;
      },
    );
    await tester_.enterText(find.byKey(const Key('camera_host')), cameraHost);
    await tester_.enterText(find.byKey(const Key('camera_cloud_password')), cameraCloudPassword);
    await tester_.pumpAndSettle();
    await tester_.ensureVisible(find.byKey(const Key('camera_save')));
    await tester_.tap(find.byKey(const Key('camera_save')));
    await tester_.pumpAndSettle();
    expect(read, [cameraHost]);
    expect(storage.storedSources.single.camera?.certificateSha256, shown);
    expect(requests, isEmpty);
  });

  testWidgets('keeps the certificate a test pinned, without reading it again at the save', (tester_) async {
    storage = await CameraTestStorage.create(sources: [cameraSource(camera: _learned)]);
    final read = <String>[];
    await pump(
      tester_,
      source: cameraSource(camera: _learned),
      certificateReader: (host) async {
        read.add(host);
        return 'ab' * 32;
      },
    );
    await tester_.pumpAndSettle();
    await tester_.ensureVisible(find.byKey(const Key('camera_save')));
    await tester_.tap(find.byKey(const Key('camera_save')));
    await tester_.pumpAndSettle();
    expect(read, isEmpty);
    expect(storage.storedSources.single.camera?.certificateSha256, _learned.certificateSha256);
  });

  testWidgets('tells a refused password with the tries left, and never tries it again on its own', (tester_) async {
    storage = await CameraTestStorage.create();
    results.add(
      const TapoTestResult(
        recordingsError: TapoCameraException(TapoErrorKind.wrongPassword, code: -40401, attemptsLeft: 3),
      ),
    );
    await pump(tester_);
    await tester_.enterText(find.byKey(const Key('camera_host')), cameraHost);
    await tester_.enterText(find.byKey(const Key('camera_cloud_password')), 'wrong');
    await tester_.pumpAndSettle();
    await tester_.ensureVisible(find.byKey(const Key('camera_test')));
    await tester_.tap(find.byKey(const Key('camera_test')));
    await tester_.pumpAndSettle();
    expect(find.textContaining('The camera refused the password'), findsOneWidget);
    expect(find.textContaining('3 tries left before the camera locks.'), findsOneWidget);
    await tester_.pump(const Duration(seconds: 5));
    expect(requests, hasLength(1));
  });

  testWidgets('asks before trusting another certificate, then tests with it', (tester_) async {
    storage = await CameraTestStorage.create(sources: [cameraSource(camera: _learned)]);
    const changed = 'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100';
    results
      ..add(
        const TapoTestResult(
          recordingsError: TapoCameraException(TapoErrorKind.certificateChanged, certificateSha256: changed),
        ),
      )
      ..add(const TapoTestResult(info: _learned));
    await pump(tester_, source: cameraSource(camera: _learned));
    await tester_.ensureVisible(find.byKey(const Key('camera_test')));
    await tester_.tap(find.byKey(const Key('camera_test')));
    await tester_.pumpAndSettle();
    expect(
      find.text(
        'The camera at $cameraHost shows another certificate than before. Continue only if you reset or replaced it.',
      ),
      findsWidgets,
    );
    await tester_.tap(find.byKey(const Key('camera_certificate_continue')));
    await tester_.pumpAndSettle();
    expect(requests, hasLength(2));
    expect(requests.first.known?.certificateSha256, _learned.certificateSha256);
    expect(requests.last.known?.certificateSha256, changed);
  });

  testWidgets('loads the stored secrets of a camera and removes it after a confirmation', (tester_) async {
    final source = cameraSource();
    storage = await CameraTestStorage.create(sources: [source]);
    await pump(tester_, source: source);
    expect(find.text('Garden'), findsWidgets);
    expect(find.text('No Tapo camera found on this network.'), findsNothing);
    await tester_.ensureVisible(find.byKey(const Key('camera_remove')));
    await tester_.tap(find.byKey(const Key('camera_remove')));
    await tester_.pumpAndSettle();
    expect(find.textContaining('Its passwords and the videos fetched from it are deleted'), findsOneWidget);
    await tester_.tap(find.text('Remove'));
    await tester_.pumpAndSettle();
    expect(storage.storedSources, isEmpty);
    expect(storage.secureStorage.values, isEmpty);
  });

  testWidgets('with a remote, every field opens the text dialog and the page holds the focus', (tester_) async {
    storage = await CameraTestStorage.create();
    await pump(tester_, tv: true);
    expect(find.byType(TvTextEntry), findsNWidgets(5));
    expect(find.text('Press OK to type'), findsNWidgets(5));
    final focused = FocusManager.instance.primaryFocus;
    expect(focused, isNotNull);
    expect(focused!.context?.findAncestorWidgetOfExactType<CameraEditPage>(), isNotNull);
    // The discovery ends
    await tester_.pump(const Duration(seconds: 2));
  });

  group('leaving with unsaved changes', () {
    final discardTitle = find.text('Discard the changes?');

    /// The page over a stub, so that leaving it can be seen
    Future<void> pumpOver(WidgetTester tester_, {NetworkSource? source}) async {
      final router = await pumpCameraApp(
        tester_,
        home: const Scaffold(body: Text('cameras list')),
        overrides: [
          ...storage.overrides,
          ...cameraOverrides(tester: tester, found: const []),
        ],
        pages: {
          CameraEditRoute.name: (data) {
            final args = data.argsAs<CameraEditRouteArgs>(orElse: () => const CameraEditRouteArgs());
            return CameraEditPage(source: args.source, server: args.server);
          },
        },
      );
      unawaited(router.push(CameraEditRoute(source: source)));
      await tester_.pumpAndSettle();
    }

    Future<void> close(WidgetTester tester_) async {
      await tester_.tap(find.byType(CloseButton));
      await tester_.pumpAndSettle();
    }

    testWidgets('asks before a typed address is lost', (tester_) async {
      storage = await CameraTestStorage.create();
      await pumpOver(tester_);
      await tester_.enterText(find.byKey(const Key('camera_host')), '192.0.2.99');
      await tester_.pump();

      await close(tester_);
      expect(discardTitle, findsOneWidget);
      await tester_.tap(find.byKey(const Key('form_discard_changes_keep')));
      await tester_.pumpAndSettle();
      expect(find.widgetWithText(TextField, '192.0.2.99'), findsOneWidget);

      await close(tester_);
      await tester_.tap(find.byKey(const Key('form_discard_changes_discard')));
      await tester_.pumpAndSettle();
      expect(find.text('cameras list'), findsOneWidget);
      expect(storage.storedSources, isEmpty);
    });

    testWidgets('a stored camera left as it was, its passwords read, leaves at once', (tester_) async {
      final source = cameraSource();
      storage = await CameraTestStorage.create(sources: [source]);
      await pumpOver(tester_, source: source);

      await close(tester_);

      expect(discardTitle, findsNothing);
      expect(find.text('cameras list'), findsOneWidget);
    });
  });
}
