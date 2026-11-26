// Spatial 2.5D on the computers (release 53): the contract between the sources of the viewer's position and the views
// that follow it. Sources: the mouse, the automatic sway and the keys (lot feat-25d-photos-53), a fake one in the
// tests, the head tracked by the webcam (lot feat-25d-tracker-53). Views: the 2.5D photo page, later the 2.5D video.
//
// This file is shared word for word by both lots of release 53: whichever changes it changes it in both, or the merge
// will tell. Pure Dart, without Flutter, so that the tracker package may copy it too.
//
// The view does the rest: the sensitivity, "Reverse direction", the limits of the viewpoint, and the glide back to the
// centre when no one is seen (confidence 0) all happen on its side, the same for every source.

/// Where the eyes of the viewer are, as one source saw them at one time
class ViewerPosition {
  const ViewerPosition({required this.x, required this.y, required this.timestamp, required this.confidence});

  /// No one seen at [timestamp]: the view glides back to its centre
  const ViewerPosition.lost(this.timestamp) : x = 0, y = 0, confidence = 0;

  /// Across the screen, as the viewer sees it (a webcam's mirror image already turned back): -1 at the left end of the
  /// range the source covers, 1 at the right end, 0 in the middle. Values beyond are allowed; the view clamps.
  final double x;

  /// Up and down, -1 at the top, 1 at the bottom, 0 in the middle. The views of release 53 move sideways only.
  final double y;

  /// When the position was true (the capture of the webcam frame, the pointer event), on a monotonic clock that is
  /// the same for every position of one source. Only differences between timestamps mean something.
  final Duration timestamp;

  /// From 0 (no one seen: the view glides back to its centre) to 1 (sure)
  final double confidence;

  /// Whether someone was seen
  bool get seen => confidence > 0;

  @override
  bool operator ==(Object other) =>
      other is ViewerPosition &&
      other.x == x &&
      other.y == y &&
      other.timestamp == timestamp &&
      other.confidence == confidence;

  @override
  int get hashCode => Object.hash(x, y, timestamp, confidence);

  @override
  String toString() => 'ViewerPosition($x, $y, ${timestamp.inMicroseconds} us, $confidence)';
}

/// What moves the view, as the settings name it
enum ViewerPositionKind {
  /// The head, tracked by the webcam (lot feat-25d-tracker-53)
  head,

  /// The pointer over the picture
  mouse,

  /// A slow back and forth, with no input
  sway,

  /// The left and right arrows only
  keys,
}

/// A source of positions of the viewer
abstract interface class ViewerPositionSource {
  /// Which kind of source this is
  ViewerPositionKind get kind;

  /// The positions, in the order of their timestamps; a broadcast stream, closed by [close]
  Stream<ViewerPosition> get positions;

  /// The last position sent, null before the first
  ViewerPosition? get latest;

  /// How long the view takes to follow a jump of the position (the time constant of its smoothing):
  /// [Duration.zero] for a source that smooths its positions itself, as the head tracker does
  Duration get followTime;

  /// The viewer's present position becomes the centre (the R key)
  void recenter();

  /// Stops the source for good (the webcam closes); [positions] closes
  Future<void> close();
}
