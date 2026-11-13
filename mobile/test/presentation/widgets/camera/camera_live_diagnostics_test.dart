// The diagnostics line of a live view that failed: model, firmware, power, the route, the step and the code, in plain
// ASCII, and never a secret.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/presentation/widgets/camera/camera_live_diagnostics.dart';

void main() {
  test('a battery camera that did not wake up', () {
    expect(
      cameraLiveDiagnostics(
        model: 'C410',
        firmware: '1.3.5 Build 260430 Rel.80669n',
        power: 'BATTERY',
        route: TapoLiveRoute.mediaPort,
        hd: false,
        rtspPort: 554,
        mediaPort: 8800,
        failure: const TapoLiveException(TapoLiveStep.connect, TapoErrorKind.unreachable, detail: '192.0.2.30'),
        error: 'the camera does not answer',
      ),
      'C410 | 1.3.5 Build 260430 Rel.80669n | power BATTERY | media port 8800 SD | '
      'failed at connect: unreachable (192.0.2.30)',
    );
  });

  test('RTSP first, then the media port refusing the request', () {
    expect(
      cameraLiveDiagnostics(
        route: TapoLiveRoute.mediaPort,
        hd: true,
        rtspPort: 554,
        mediaPort: 8800,
        rtspError: 'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED',
        failure: const TapoLiveException(TapoLiveStep.request, TapoErrorKind.busy, code: -52405),
      ),
      'model ? | power ? | RTSP 554: ERROR_CODE_IO_NETWORK_CONNECTION_FAILED | media port 8800 HD | '
      'failed at request: busy code -52405',
    );
  });

  test('the player failing on RTSP', () {
    expect(
      cameraLiveDiagnostics(
        model: 'C510W',
        route: TapoLiveRoute.rtsp,
        hd: false,
        rtspPort: 554,
        mediaPort: 8800,
        error: 'ERROR_CODE_TIMEOUT',
      ),
      'C510W | power ? | RTSP 554 SD | failed: ERROR_CODE_TIMEOUT',
    );
  });
}
