// One eye of a 3D video shown flat (flat_eye_view.dart, parity lot L02): the part of the frame each eye takes in each
// layout, and the frame laid out at its size, cut to the eye and fitted to the window, letterboxed, on a stand in for
// the texture of the video; the whole frame letterboxed while the video output has no size yet.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/flat_eye_view.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:media_kit_video/sphere.dart' show PluginEye;

void main() {
  test('each eye of each layout, and none for a mono frame', () {
    expect(flatEyeCrop(StereoLayout.mono, PluginEye.left), isNull);
    expect(flatEyeCrop(StereoLayout.leftRight, PluginEye.left), (
      alignment: Alignment.topLeft,
      widthFactor: 0.5,
      heightFactor: 1.0,
    ));
    expect(flatEyeCrop(StereoLayout.leftRight, PluginEye.right)!.alignment, Alignment.topRight);
    expect(flatEyeCrop(StereoLayout.topBottom, PluginEye.left), (
      alignment: Alignment.topLeft,
      widthFactor: 1.0,
      heightFactor: 0.5,
    ));
    expect(flatEyeCrop(StereoLayout.topBottom, PluginEye.right)!.alignment, Alignment.bottomLeft);
  });

  group('the view, in an 800 by 600 window', () {
    const frameKey = Key('frame');
    final fits = <BoxFit>[];

    Future<Rect> frameOf(WidgetTester tester, Rect? frame, StereoLayout layout, PluginEye eye) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      fits.clear();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: FlatEyeView(
            frame: ValueNotifier(frame),
            crop: flatEyeCrop(layout, eye)!,
            video: (fit) {
              fits.add(fit);
              return const SizedBox.expand(key: frameKey);
            },
          ),
        ),
      );
      return tester.getRect(find.byKey(frameKey));
    }

    testWidgets('side by side: the left eye fills the width, the right half of the frame beyond the window', (
      tester,
    ) async {
      // Two eyes of 1920 by 1080: an eye of 16:9 letterboxed in 800 by 600 is 800 by 450, 75 from the top
      final left = await frameOf(tester, const Rect.fromLTWH(0, 0, 3840, 1080), StereoLayout.leftRight, PluginEye.left);
      expect(left, const Rect.fromLTWH(0, 75, 1600, 450));
      expect(fits, [BoxFit.fill], reason: 'the texture fills the box of its frame');
      final right = await frameOf(
        tester,
        const Rect.fromLTWH(0, 0, 3840, 1080),
        StereoLayout.leftRight,
        PluginEye.right,
      );
      expect(right, const Rect.fromLTWH(-800, 75, 1600, 450));
    });

    testWidgets('over-under: the top eye, the frame twice as high as the eye', (tester) async {
      final top = await frameOf(tester, const Rect.fromLTWH(0, 0, 1920, 2160), StereoLayout.topBottom, PluginEye.left);
      expect(top, const Rect.fromLTWH(0, 75, 800, 900));
      final bottom = await frameOf(
        tester,
        const Rect.fromLTWH(0, 0, 1920, 2160),
        StereoLayout.topBottom,
        PluginEye.right,
      );
      expect(bottom, const Rect.fromLTWH(0, -375, 800, 900));
    });

    testWidgets('before the first frame, the whole video letterboxed', (tester) async {
      final whole = await frameOf(tester, const Rect.fromLTWH(0, 0, 1, 1), StereoLayout.leftRight, PluginEye.left);
      expect(whole, const Rect.fromLTWH(0, 0, 800, 600));
      expect(fits, [BoxFit.contain]);
      await frameOf(tester, null, StereoLayout.leftRight, PluginEye.left);
      expect(fits, [BoxFit.contain]);
    });
  });
}
