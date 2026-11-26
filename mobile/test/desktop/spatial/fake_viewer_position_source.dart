import 'dart:async';

import 'package:immich_mobile/desktop/spatial/viewer_position.dart';

/// A source the tests feed by hand, or from a recorded track
class FakeViewerPositionSource implements ViewerPositionSource {
  FakeViewerPositionSource({this.kind = ViewerPositionKind.head, this.followTime = Duration.zero});

  @override
  final ViewerPositionKind kind;

  @override
  final Duration followTime;

  final _controller = StreamController<ViewerPosition>.broadcast(sync: true);
  ViewerPosition? _latest;
  int recenters = 0;
  bool closed = false;

  @override
  Stream<ViewerPosition> get positions => _controller.stream;

  @override
  ViewerPosition? get latest => _latest;

  void add(ViewerPosition position) {
    _latest = position;
    _controller.add(position);
  }

  /// A recorded track: (milliseconds, x, confidence) triples, sent in order
  void play(List<(int, double, double)> track) {
    for (final (ms, x, confidence) in track) {
      add(
        ViewerPosition(
          x: x,
          y: 0,
          timestamp: Duration(milliseconds: ms),
          confidence: confidence,
        ),
      );
    }
  }

  @override
  void recenter() => recenters++;

  @override
  Future<void> close() async {
    closed = true;
    await _controller.close();
  }
}
