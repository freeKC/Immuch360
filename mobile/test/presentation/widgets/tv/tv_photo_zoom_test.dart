// The zoom of a photo with a remote control (tv_photo_zoom.dart): one step of 1.25 around the middle of the screen, up
// to 8 times the whole photo, never below it, where the photo is centred again; the arrows move a zoomed photo by a
// tenth of the screen, within its edges.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_photo_zoom.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';
import 'package:immich_mobile/widgets/photo_view/src/utils/photo_view_utils.dart';

/// A 1920 x 1080 photo on a 960 x 540 screen: whole at a scale of 0.5
PhotoViewController photo() => PhotoViewController(initialScale: 0.5)
  ..scaleBoundaries = const ScaleBoundaries(
    PhotoViewComputedScale.contained,
    12.0,
    PhotoViewComputedScale.contained,
    Size(960, 540),
    Size(1920, 1080),
  );

void main() {
  test('zooms by one step, up to 8 times the whole photo', () {
    final controller = photo();
    expect(tvPhotoZoomed(controller), isFalse);

    expect(tvPhotoZoomBy(controller, zoomIn: true), isTrue);
    expect(tvPhotoZoomOf(controller), closeTo(1.25, 1e-9));
    expect(tvPhotoZoomed(controller), isTrue);

    var steps = 1;
    while (tvPhotoZoomBy(controller, zoomIn: true)) {
      steps++;
    }
    expect(tvPhotoZoomOf(controller), closeTo(tvPhotoMaxZoom, 1e-9));
    expect(steps, 10, reason: '1.25 to the ninth power is below 8, the tenth step stops there');
  });

  test('zooming out stops at the whole photo, centred again', () {
    final controller = photo();
    tvPhotoZoomBy(controller, zoomIn: true);
    tvPhotoZoomBy(controller, zoomIn: true);
    tvPhotoPan(controller, const Offset(1, 0));
    expect(controller.position, isNot(Offset.zero));

    expect(tvPhotoZoomBy(controller, zoomIn: false), isTrue);
    expect(tvPhotoZoomBy(controller, zoomIn: false), isTrue);
    expect(tvPhotoZoomed(controller), isFalse);
    expect(controller.scale, 0.5);
    expect(controller.position, Offset.zero);
    expect(tvPhotoZoomBy(controller, zoomIn: false), isFalse, reason: 'never below the whole photo');
  });

  test('a zoom keeps the point in the middle of the screen there', () {
    final controller = photo();
    controller.updateMultiple(scale: 1.0, position: const Offset(-96, 40));

    tvPhotoZoomBy(controller, zoomIn: true);

    expect(controller.scale, 1.25);
    expect(controller.position.dx, closeTo(-120, 1e-9));
    expect(controller.position.dy, closeTo(50, 1e-9));
  });

  test('the arrows move a zoomed photo by a tenth of the screen, up to its edges', () {
    final controller = photo();
    expect(tvPhotoPan(controller, const Offset(1, 0)), isFalse, reason: 'a whole photo does not move');

    // Twice the whole photo: 1920 x 1080 on screen, its edges 480 and 270 away
    controller.updateMultiple(scale: 1.0);
    expect(tvPhotoPan(controller, const Offset(1, 0)), isTrue);
    expect(controller.position, const Offset(-96, 0), reason: 'more of the right side comes into view');
    expect(tvPhotoPan(controller, const Offset(0, -1)), isTrue);
    expect(controller.position, const Offset(-96, 54), reason: 'more of the top');

    var presses = 0;
    while (tvPhotoPan(controller, const Offset(1, 0))) {
      presses++;
    }
    expect(controller.position.dx, -480);
    expect(presses, 4);
  });

  test('reset shows the whole photo, centred', () {
    final controller = photo()..updateMultiple(scale: 2.0, position: const Offset(100, -50));

    tvPhotoZoomReset(controller);

    expect(controller.scale, 0.5);
    expect(controller.position, Offset.zero);
  });

  test('a photo not laid out yet neither zooms nor moves', () {
    final controller = PhotoViewController();

    expect(tvPhotoZoomBy(controller, zoomIn: true), isFalse);
    expect(tvPhotoPan(controller, const Offset(1, 0)), isFalse);
    expect(tvPhotoZoomOf(controller), 1);
  });
}
