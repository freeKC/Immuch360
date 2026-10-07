// The sentences of the failures of a camera and the labels of the memory card and the clips.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/presentation/widgets/camera/camera_badges.widget.dart';

import '../../pages/camera/camera_fakes.dart';

void main() {
  testWidgets('puts each failure of a camera into words', (tester) async {
    late BuildContext context;
    await pumpCameraApp(
      tester,
      home: Builder(
        builder: (built) {
          context = built;
          return const SizedBox.shrink();
        },
      ),
      overrides: cameraOverrides(),
    );
    String text(Object error) => cameraErrorText(context, error, host: cameraHost);

    expect(
      text(const TapoCameraException(TapoErrorKind.wrongPassword, attemptsLeft: 1)),
      'The camera refused the password. Each wrong try counts, and after a few the camera locks for a while. '
      '1 try left before the camera locks.',
    );
    expect(
      text(const TapoCameraException(TapoErrorKind.wrongPassword)),
      'The camera refused the password. Each wrong try counts, and after a few the camera locks for a while.',
    );
    expect(
      text(const TapoCameraException(TapoErrorKind.locked, lockedMinutes: 30)),
      'The camera is locked after too many wrong passwords. Try again in 30 minutes.',
    );
    expect(
      text(const TapoCameraException(TapoErrorKind.locked)),
      'The camera is locked after too many wrong passwords. Try again later.',
    );
    expect(text(const TapoCameraException(TapoErrorKind.unreachable)), 'The camera does not answer at $cameraHost.');
    expect(
      text(const TapoCameraException(TapoErrorKind.unsupported, code: -40209, detail: 'pake_register')),
      'This camera answers in a way this app does not know yet (pake_register -40209).',
    );
    expect(text(const TapoCameraException(TapoErrorKind.h265)), contains('H.265'));
    expect(text(const TapoCameraException(TapoErrorKind.mediaLocked)), contains('Third-Party Compatibility'));
    expect(text(const TapoCameraException(TapoErrorKind.notOwner)), contains('owns it'));
    expect(text(const TapoCameraException(TapoErrorKind.busy)), contains('busy'));
    expect(text(const NetworkFileSystemException('closed')), 'Connection failed: closed');
    expect(cameraClipKindText(context, TapoClipKind.babyCry), 'Baby crying');
  });

  testWidgets('tells the state of the memory card', (tester) async {
    await pumpCameraApp(
      tester,
      home: const Column(
        children: [
          CameraCardBadge(
            card: TapoCardStatus(state: TapoCardState.absent, status: ''),
          ),
          CameraCardBadge(
            card: TapoCardStatus(state: TapoCardState.other, status: 'formatting'),
          ),
          CameraCardBadge(
            card: TapoCardStatus(
              state: TapoCardState.normal,
              status: 'normal',
              usedBytes: 1 << 30,
              totalBytes: 1 << 31,
            ),
          ),
        ],
      ),
      overrides: cameraOverrides(),
    );
    expect(find.text('No memory card'), findsOneWidget);
    expect(find.text('Memory card: formatting'), findsOneWidget);
    expect(find.text('Memory card: 1.0 GiB used of 2.0 GiB'), findsOneWidget);
  });
}
