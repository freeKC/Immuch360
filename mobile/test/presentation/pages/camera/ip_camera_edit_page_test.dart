// The page that adds a camera of another brand (release 48): the ONVIF cameras found on the network, one tapped fills
// the page; "Read the camera" reads it through ONVIF (the fake camera) and describes its main stream (a fake probe);
// a save keeps the host, the ports and what the camera told in the source, and the password and the stream addresses
// in the secure storage for this device only; a pasted link gives its account to the fields; the failures in words.
// Synthetic values only (addresses in 192.0.2.0/24).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ip_camera_info.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/ip_camera.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/ipcam/camera_address.dart';
import 'package:immich_mobile/infrastructure/ipcam/ip_camera_service.dart';
import 'package:immich_mobile/infrastructure/tapo/rtsp_probe.dart';
import 'package:immich_mobile/presentation/pages/camera/ip_camera_edit.page.dart';
import 'package:immich_mobile/providers/ipcam/ip_camera.provider.dart';

import '../../../infrastructure/ipcam/fake_onvif_camera.dart';
import 'camera_fakes.dart';

const _found = DiscoveredOnvifDevice(
  endpoint: 'urn:uuid:00000000-0000-4000-8000-000000000001',
  host: '192.0.2.50',
  port: 80,
  path: '/onvif/device_service',
  name: 'Porch',
  hardware: 'Cam-1',
);

void main() {
  late CameraTestStorage storage;
  late FakeOnvifCamera camera;
  late List<String> probed;
  late TapoLiveProbe Function() probeAnswer;

  tearDown(() => storage.dispose());

  setUp(() {
    camera = FakeOnvifCamera();
    probed = [];
    probeAnswer = () => const TapoLiveProbe(video: 'H264', audio: 'PCMA');
  });

  Future<void> pump(WidgetTester tester, {NetworkSource? source}) async {
    final service = IpCameraService(
      post: camera.post,
      localAddresses: () async => ['192.0.2.2'],
      discover: ({required localAddresses, unicastHosts = const []}) => Stream.fromIterable([_found]),
      probe: (address, user, password) async {
        probed.add('${address.url} ${user.isEmpty ? '' : user}');
        return probeAnswer();
      },
    );
    await pumpCameraApp(
      tester,
      home: IpCameraEditPage(source: source),
      overrides: [...storage.overrides, ipCameraServiceProvider.overrideWithValue(service)],
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('a camera found by ONVIF: read, then saved with its secrets on this device only', (tester) async {
    storage = await CameraTestStorage.create(cloudPassword: null, accountPassword: null);
    await pump(tester);
    expect(find.text('Porch'), findsOneWidget);
    await tester.tap(find.text('Porch'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '192.0.2.50'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('ip_camera_user')), camera.user);
    await tester.enterText(find.byKey(const Key('ip_camera_password')), camera.password);
    await tester.pumpAndSettle();

    await tapKey(tester, 'ip_camera_read');
    expect(find.byKey(const Key('ip_camera_device')), findsOneWidget);
    expect(find.byKey(const Key('ip_camera_profiles')), findsOneWidget);
    expect(find.byKey(const Key('ip_camera_stream')), findsOneWidget);
    expect(find.byKey(const Key('ip_camera_error')), findsNothing);
    // The main stream described once, on the host of the source, with the account
    expect(probed, ['rtsp://192.0.2.50:554/live/main ${camera.user}']);

    await tapKey(tester, 'ip_camera_save');
    final saved = storage.storedSources.single;
    expect(saved.type, NetworkSourceType.ipCamera);
    expect(saved.host, '192.0.2.50');
    expect(saved.username, camera.user);
    expect(saved.discoveryId, _found.endpoint);
    final info = saved.ipCamera!;
    expect(info.kind, IpCameraKind.onvif);
    expect(info.onvifPort, 80);
    expect(info.rtspPort, 554);
    expect(info.main!.codec, 'H264');
    expect(info.main!.width, 1920);
    expect(info.sub!.height, 360);
    // Nothing of the streams or the account in the stored source
    final json = NetworkSource.encodeList([saved]);
    expect(json, isNot(contains('/live/')));
    expect(json, isNot(contains(camera.password)));
    final secrets = storage.secureStorage;
    expect(secrets.values[saved.secretKey], camera.password);
    final streams = IpCameraStreams.decode(secrets.values[saved.cameraSecretKey])!;
    expect(streams.main, '/live/main');
    expect(streams.sub, '/live/sub');
    expect(streams.snapshot, 'http://192.0.2.50/snapshot.jpg');
    expect(secrets.writtenDeviceOnly, containsAll([saved.secretKey, saved.cameraSecretKey]));
  });

  testWidgets('a pasted link: its account goes to the fields, the address keeps the link without it', (tester) async {
    storage = await CameraTestStorage.create(cloudPassword: null, accountPassword: null);
    await pump(tester);
    await tester.enterText(
      find.byKey(const Key('ip_camera_address')),
      'rtsp://admin:pa%40ss@192.0.2.60:8554/cam/realmonitor?channel=1&subtype=0',
    );
    await tester.pumpAndSettle();
    await tapKey(tester, 'ip_camera_read');
    expect(find.widgetWithText(TextField, 'admin'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'rtsp://192.0.2.60:8554/cam/realmonitor?channel=1&subtype=0'),
      findsOneWidget,
    );
    expect(probed, ['rtsp://192.0.2.60:8554/cam/realmonitor?channel=1&subtype=0 admin']);
    await tapKey(tester, 'ip_camera_save');
    final saved = storage.storedSources.single;
    expect(saved.ipCamera!.kind, IpCameraKind.rtsp);
    expect(saved.ipCamera!.rtspPort, 8554);
    expect(saved.host, '192.0.2.60');
    expect(storage.secureStorage.values[saved.secretKey], 'pa@ss');
    expect(
      IpCameraStreams.decode(storage.secureStorage.values[saved.cameraSecretKey])!.main,
      '/cam/realmonitor?channel=1&subtype=0',
    );
  });

  testWidgets('the failures in words: an account asked for, a codec this device does not play', (tester) async {
    storage = await CameraTestStorage.create(cloudPassword: null, accountPassword: null);
    await pump(tester);
    await tester.enterText(find.byKey(const Key('ip_camera_address')), '192.0.2.50');
    await tester.pumpAndSettle();
    // No account typed: the fake camera wants its UsernameToken
    await tapKey(tester, 'ip_camera_read');
    expect(find.byKey(const Key('ip_camera_error')), findsOneWidget);
    expect(find.textContaining('asks for an account'), findsOneWidget);
    expect(probed, isEmpty);

    await tester.enterText(find.byKey(const Key('ip_camera_user')), camera.user);
    await tester.enterText(find.byKey(const Key('ip_camera_password')), camera.password);
    probeAnswer = () => const TapoLiveProbe(video: 'JPEG');
    await tester.pumpAndSettle();
    await tapKey(tester, 'ip_camera_read');
    // MJPEG on a phone: told, the camera still readable on a computer
    expect(find.textContaining('does not play MJPEG'), findsOneWidget);
  });

  testWidgets('a link that is no address is refused before anything is sent', (tester) async {
    storage = await CameraTestStorage.create(cloudPassword: null, accountPassword: null);
    await pump(tester);
    await tester.enterText(find.byKey(const Key('ip_camera_address')), 'http//nope');
    await tester.pumpAndSettle();
    await tapKey(tester, 'ip_camera_read');
    expect(find.textContaining('Type an address'), findsOneWidget);
    expect(camera.requests, isEmpty);
    expect(probed, isEmpty);
  });

  testWidgets('a camera behind a stream that needs an account: needsAccount from the RTSP side too', (tester) async {
    storage = await CameraTestStorage.create(cloudPassword: null, accountPassword: null);
    await pump(tester);
    probeAnswer = () =>
        throw const TapoCameraException(TapoErrorKind.wrongPassword, code: 401, detail: rtspNeedsAccount);
    await tester.enterText(find.byKey(const Key('ip_camera_address')), 'rtsp://192.0.2.70:8554/front');
    await tester.pumpAndSettle();
    await tapKey(tester, 'ip_camera_read');
    expect(find.textContaining('asks for an account'), findsOneWidget);
    await tapKey(tester, 'ip_camera_save');
    expect(storage.storedSources, isEmpty);
  });
}
