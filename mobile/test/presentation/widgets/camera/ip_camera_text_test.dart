// The reasons of the live view of a camera of another brand read into causes: Media3's error code names (Android, the
// TV, the Quest), FFmpeg's lines on a computer, the Dart playlist's reasons on iPhone and iPad.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/ip_camera.dart';
import 'package:immich_mobile/presentation/widgets/camera/camera_live_hls.dart';
import 'package:immich_mobile/presentation/widgets/camera/ip_camera_text.dart';

void main() {
  IpCameraErrorKind? kind(String? reason, {bool hasAccount = true}) =>
      ipCameraLiveCause(reason, hasAccount: hasAccount)?.kind;

  test('an account refused, or asked for when none was given', () {
    expect(kind(cameraLiveRefused), IpCameraErrorKind.wrongPassword);
    expect(
      kind('rtsp://<url>: Server returned 401 Unauthorized (authorization failed)'),
      IpCameraErrorKind.wrongPassword,
    );
    expect(kind('Server returned 401', hasAccount: false), IpCameraErrorKind.needsAccount);
  });

  test('a codec the device does not play', () {
    expect(kind(cameraLiveH265), IpCameraErrorKind.codecNotPlayableHere);
    expect(kind('ERROR_CODE_DECODING_FORMAT_UNSUPPORTED'), IpCameraErrorKind.codecNotPlayableHere);
    expect(ipCameraLiveCause('ERROR_CODE_DECODER_INIT_FAILED', hasAccount: true)!.detail, isEmpty);
  });

  test('nothing answers, a wrong path, TCP refused', () {
    expect(kind('ERROR_CODE_IO_NETWORK_CONNECTION_FAILED'), IpCameraErrorKind.unreachable);
    expect(kind(cameraLiveUnreachable), IpCameraErrorKind.unreachable);
    expect(kind('Connection to tcp://192.0.2.5:554 failed: Connection refused'), IpCameraErrorKind.unreachable);
    expect(kind('method DESCRIBE failed: 404 Not Found'), IpCameraErrorKind.noProfile);
    expect(kind('method SETUP failed: 461 Unsupported transport'), IpCameraErrorKind.other);
  });

  test('anything else is shown as it came', () {
    expect(kind(null), isNull);
    expect(kind('something new'), isNull);
  });
}
