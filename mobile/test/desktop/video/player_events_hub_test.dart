// The handlers of the full screen players' events in one place (player_events_hub.dart, design 1.3): the 360° player
// of the computers reaches the session a phone's native player reaches through the generated channel, and removing
// the handler removes it for both.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/player_events_hub.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';
import 'package:immich_mobile/platform/spherical_video_api.g.dart';

class _Spherical implements SphericalVideoEvents {
  final closings = <(StereoLayout, SphereCoverage)>[];

  @override
  void closed(StereoLayout stereoLayout, SphereCoverage coverage) => closings.add((stereoLayout, coverage));
}

class _Spatial extends Fake implements SpatialVideoEvents {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    PlayerEventsHub.setUpSpherical(null);
    PlayerEventsHub.setUpSpatial(null);
  });

  test('the handler registered is the one the desktop player calls', () {
    final session = _Spherical();
    PlayerEventsHub.setUpSpherical(session);
    PlayerEventsHub.spherical?.closed(StereoLayout.leftRight, SphereCoverage.half);
    expect(session.closings, [(StereoLayout.leftRight, SphereCoverage.half)]);
    PlayerEventsHub.setUpSpherical(null);
    expect(PlayerEventsHub.spherical, isNull);
  });

  test('the Spatial handler is kept the same way', () {
    final session = _Spatial();
    PlayerEventsHub.setUpSpatial(session);
    expect(PlayerEventsHub.spatial, same(session));
  });
}
