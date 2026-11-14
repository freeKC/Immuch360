// The page of a camera of another brand (release 48): the live tile plays the stored stream addresses through the
// same live view API as Tapo (Media3 on Android, the TV and the Quest), the sub stream first on a phone; a UniFi
// Protect RTSPS link plays on the console's plain port; another RTSPS link is told to play on a computer only; a
// camera restored without its stream addresses says so; a failure of the player is told in the words of its cause.
// Synthetic values only (addresses in 192.0.2.0/24).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/ip_camera_info.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/infrastructure/ipcam/camera_address.dart';
import 'package:immich_mobile/platform/camera_live_api.g.dart';
import 'package:immich_mobile/presentation/pages/camera/ip_camera.page.dart';
import 'package:immich_mobile/providers/tapo/tapo_camera.provider.dart';

import 'camera_fakes.dart';

const _id = 'a1b2c3d4e5f60718';

NetworkSource _source({IpCameraInfo? info, String host = '192.0.2.50'}) => NetworkSource(
  id: _id,
  type: NetworkSourceType.ipCamera,
  name: 'Porch',
  host: host,
  username: 'onvif',
  ipCamera:
      info ??
      const IpCameraInfo(
        kind: IpCameraKind.onvif,
        onvifPort: 80,
        manufacturer: 'Example',
        model: 'Cam-1',
        firmware: '1.0.0',
        main: IpCameraStreamInfo(profileToken: 'main', codec: 'H264', width: 1920, height: 1080),
        sub: IpCameraStreamInfo(profileToken: 'sub', codec: 'H264', width: 640, height: 360),
      ),
);

void main() {
  late CameraTestStorage storage;
  late FakeCameraLiveApi live;

  setUp(() => live = FakeCameraLiveApi());
  tearDown(() => storage.dispose());

  Future<void> pump(WidgetTester tester, {NetworkSource? source, IpCameraStreams? streams}) async {
    storage = await CameraTestStorage.create(
      sources: [source ?? _source()],
      cloudPassword: 'synthetic-pw',
      accountPassword: streams?.encode(),
    );
    await pumpCameraApp(
      tester,
      home: const IpCameraPage(sourceId: _id),
      overrides: [
        ...storage.overrides,
        ...cameraOverrides(live: live),
      ],
    );
    await tester.pumpAndSettle();
  }

  testWidgets('plays the sub stream with the account through the live view API, and tells the camera', (tester) async {
    await pump(
      tester,
      streams: const IpCameraStreams(main: '/live/main', sub: '/live/sub'),
    );
    final (_, source) = live.sources.single;
    expect(source.url, 'rtsp://192.0.2.50:554/live/sub');
    expect(source.username, 'onvif');
    expect(source.password, 'synthetic-pw');
    expect(source.isHls, isFalse);
    expect(find.byKey(const Key('ip_camera_model')), findsOneWidget);
    expect(find.text('Main stream H.264 1920 x 1080, sub stream H.264 640 x 360'), findsOneWidget);
  });

  testWidgets('a UniFi Protect RTSPS link plays on the plain port, without the SRTP request', (tester) async {
    await pump(
      tester,
      source: _source(
        info: const IpCameraInfo(kind: IpCameraKind.rtsp, rtspPort: unifiRtspsPort, secure: true),
      ),
      streams: const IpCameraStreams(main: '/SyntheticTok3n?enableSrtp'),
    );
    expect(live.sources.single.$2.url, 'rtsp://192.0.2.50:7447/SyntheticTok3n');
  });

  testWidgets('another RTSPS link: played on a computer only, said so here', (tester) async {
    await pump(
      tester,
      source: _source(info: const IpCameraInfo(kind: IpCameraKind.rtsp, rtspPort: 322, secure: true)),
      streams: const IpCameraStreams(main: '/front'),
    );
    expect(live.sources, isEmpty);
    expect(find.byKey(const Key('camera_live_secure_not_here')), findsOneWidget);
  });

  testWidgets('restored without its stream addresses: said so, nothing played', (tester) async {
    await pump(tester);
    expect(live.sources, isEmpty);
    expect(find.byKey(const Key('ip_camera_no_streams')), findsOneWidget);
  });

  testWidgets('a failure of the player in the words of its cause', (tester) async {
    await pump(tester, streams: const IpCameraStreams(main: '/live/main'));
    ProviderScope.containerOf(tester.element(find.byType(IpCameraPage)))
        .read(cameraLiveEventsProvider)
        .stateChanged(cameraViewId, CameraLiveState.failed, 'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED', false);
    await tester.pumpAndSettle();
    expect(find.textContaining('Nothing answers at 192.0.2.50'), findsOneWidget);
  });
}
