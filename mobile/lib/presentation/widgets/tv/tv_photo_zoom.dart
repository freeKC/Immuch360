import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';
import 'package:immich_mobile/widgets/photo_view/src/utils/photo_view_utils.dart';

/// The zoom of a photo with a remote control, which has no pinch: the zoom keys of a remote (or the Zoom in button of
/// the bottom bar of a TV) zoom by [tvPhotoZoomStep] around the middle of the screen, up to [tvPhotoMaxZoom] times the
/// whole photo, and the arrows move a zoomed photo by [tvPhotoPanShare] of the screen per press. All of it on the
/// controller of the photo, which keeps its pinch and double tap. After the remote zoom and pan of mlc70's Android TV
/// fork.

/// Zooms the photo on screen in ([zoomIn]) or out by one step, as a zoom key of a remote does: the Zoom in button of
/// the bottom bar of a TV, which the asset viewer takes
class TvPhotoZoomIntent extends Intent {
  const TvPhotoZoomIntent({required this.zoomIn});

  final bool zoomIn;
}

/// The factor of one press of a zoom key
const tvPhotoZoomStep = 1.25;

/// At most this many times the whole photo, within the largest scale of the viewer
const tvPhotoMaxZoom = 8.0;

/// What one press of an arrow moves a zoomed photo by, a share of the screen
const tvPhotoPanShare = 0.1;

/// How many times the whole photo [controller] shows, 1 when whole or not laid out yet
double tvPhotoZoomOf(PhotoViewControllerBase controller) {
  final initial = controller.scaleBoundaries?.initialScale;
  final scale = controller.scale;
  return initial == null || initial <= 0 || scale == null ? 1 : scale / initial;
}

/// Whether [controller] shows its photo zoomed in
bool tvPhotoZoomed(PhotoViewControllerBase controller) => tvPhotoZoomOf(controller) > 1.001;

/// Zooms in ([zoomIn]) or out by one step around the middle of the screen, never below the whole photo: back there
/// the photo is centred again. Whether the zoom changed.
bool tvPhotoZoomBy(PhotoViewControllerBase controller, {required bool zoomIn}) {
  final bounds = controller.scaleBoundaries;
  if (bounds == null) {
    return false;
  }
  final initial = bounds.initialScale;
  final scale = controller.scale ?? initial;
  final most = math.max(initial, math.min(bounds.maxScale, initial * tvPhotoMaxZoom));
  final next = (scale * (zoomIn ? tvPhotoZoomStep : 1 / tvPhotoZoomStep)).clamp(initial, most);
  if ((next - scale).abs() < 1e-9) {
    return false;
  }
  if (next <= initial * 1.001) {
    tvPhotoZoomReset(controller);
    return true;
  }
  // The point of the photo in the middle of the screen stays there
  final position = controller.position * (next / scale);
  controller.updateMultiple(scale: next, position: _clamped(bounds, next, position));
  return true;
}

/// Moves a zoomed photo by one press of an arrow towards [direction] (x right, y down: what comes into view), within
/// its edges. Whether it moved: not at an edge, nor when whole.
bool tvPhotoPan(PhotoViewControllerBase controller, Offset direction) {
  final bounds = controller.scaleBoundaries;
  final scale = controller.scale;
  if (bounds == null || scale == null || !tvPhotoZoomed(controller)) {
    return false;
  }
  final step = Offset(
    -direction.dx * bounds.outerSize.width * tvPhotoPanShare,
    -direction.dy * bounds.outerSize.height * tvPhotoPanShare,
  );
  final position = _clamped(bounds, scale, controller.position + step);
  if (position == controller.position) {
    return false;
  }
  controller.updateMultiple(position: position);
  return true;
}

/// The whole photo again, centred
void tvPhotoZoomReset(PhotoViewControllerBase controller) {
  final initial = controller.scaleBoundaries?.initialScale;
  if (initial != null) {
    controller.updateMultiple(scale: initial, position: Offset.zero);
  }
}

/// [position] within the edges of the photo at [scale]: no black past them
Offset _clamped(ScaleBoundaries bounds, double scale, Offset position) {
  final x = math.max(0.0, (bounds.childSize.width * scale - bounds.outerSize.width) / 2);
  final y = math.max(0.0, (bounds.childSize.height * scale - bounds.outerSize.height) / 2);
  return Offset(position.dx.clamp(-x, x), position.dy.clamp(-y, y));
}
