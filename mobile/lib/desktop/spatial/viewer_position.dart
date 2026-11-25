// The viewpoint of a Spatial 2.5D view on the computers, shared by the photo page and the video route: where the
// viewer's eye is, from the left of the picture to its right. The inputs write it (the head through the webcam, the
// mouse over the picture, the automatic sway, the arrow keys and the slider); the pages read it at each frame and hand
// it to their shader or to the video renderer. Nothing else crosses between the two: the camera, its consent and its
// lifecycle stay behind a ViewerPositionSource.

import 'package:flutter/foundation.dart';

/// What moves the viewpoint
enum ViewerInput {
  /// The head, followed through the webcam
  head,

  /// The mouse pointer over the picture
  mouse,

  /// A slow back and forth that needs no input
  sway,

  /// The arrow keys and the slider only
  keys,
}

/// One viewpoint: [x] from [ViewerPosition.min] (the eye at the left) to [ViewerPosition.max], 0.5 straight on
@immutable
class ViewerPosition {
  const ViewerPosition({this.x = centreX, this.input = ViewerInput.keys, this.tracking = false});

  /// Straight on, the keys input
  static const centre = ViewerPosition();

  static const double centreX = 0.5;

  /// The viewpoint never goes further out than this, as on the phones
  static const double min = 0.15;
  static const double max = 0.85;

  final double x;

  /// The input that gave [x]
  final ViewerInput input;

  /// The head input sees a face now; false for the other inputs and while the face is lost
  final bool tracking;

  /// [value] kept within [min] and [max] (0.5 for a value that is not a number)
  static double clampX(double value) => value.isNaN ? centreX : value.clamp(min, max).toDouble();

  ViewerPosition copyWith({double? x, ViewerInput? input, bool? tracking}) => ViewerPosition(
    x: x == null ? this.x : clampX(x),
    input: input ?? this.input,
    tracking: tracking ?? this.tracking,
  );

  @override
  bool operator ==(Object other) =>
      other is ViewerPosition && other.x == x && other.input == input && other.tracking == tracking;

  @override
  int get hashCode => Object.hash(x, input, tracking);

  @override
  String toString() => 'ViewerPosition(${x.toStringAsFixed(3)}, ${input.name}${tracking ? ', tracking' : ''})';
}

/// Gives the viewpoint of one Spatial 2.5D view. The page reads [position] at each frame (from a Ticker) and forwards
/// the mouse and the keys; the listeners hear the changes of input and of tracking, not each new position.
abstract interface class ViewerPositionSource implements Listenable {
  /// The viewpoint now
  ViewerPosition get position;

  /// The mouse over the picture, [fraction] from 0 (its left edge) to 1; used by the mouse input
  void pointer(double fraction);

  /// The arrow keys or the slider moved the viewpoint by [delta]; used by the keys input
  void step(double delta);

  /// The viewpoint straight on again; with the head, the next face sets the middle
  void recenter();
}
