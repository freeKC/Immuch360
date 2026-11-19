// The relief strength and the first view chosen on a relief of the immersive viewer of the Meta Quest become the AI
// settings of the app (GitHub issue 19, point 4), through ImmersiveEvents.reliefSettingsChanged.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/relief_strength.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';

void main() {
  late List<(ReliefStrength, ReliefViewMode?)> stored;
  late ImmersiveSession session;

  setUp(() {
    stored = [];
    session = ImmersiveSession(onReliefSettingsChanged: (strength, mode) async => stored.add((strength, mode)));
  });

  test('a strength chosen in the viewer is stored, the first view only when 3D or 2.5D was chosen', () async {
    final openingId = session.start(null);
    session.reliefSettingsChanged(openingId, 'strong', null);
    session.reliefSettingsChanged(openingId, 'subtle', 'mesh25d');
    session.reliefSettingsChanged(openingId, 'normal', 'stereo');
    await Future<void>.delayed(Duration.zero);
    expect(stored, [
      (ReliefStrength.strong, null),
      (ReliefStrength.subtle, ReliefViewMode.mesh25d),
      (ReliefStrength.normal, ReliefViewMode.stereo),
    ]);
  });

  test('an opening no longer followed still counts: the press was the user\'s', () async {
    final first = session.start(null);
    session.start(null);
    session.reliefSettingsChanged(first, 'strong', null);
    await Future<void>.delayed(Duration.zero);
    expect(stored, [(ReliefStrength.strong, null)]);
  });

  test('a strength this build does not know changes nothing, an unknown mode leaves the first view', () async {
    final openingId = session.start(null);
    session.reliefSettingsChanged(openingId, 'extreme', 'stereo');
    session.reliefSettingsChanged(openingId, 'strong', '2d');
    await Future<void>.delayed(Duration.zero);
    expect(stored, [(ReliefStrength.strong, null)]);
  });

  test('a failed write is only logged, and without a store nothing happens', () async {
    final failing = ImmersiveSession(onReliefSettingsChanged: (_, _) async => throw StateError('no database'));
    failing.reliefSettingsChanged(1, 'strong', 'stereo');
    ImmersiveSession().reliefSettingsChanged(1, 'strong', 'stereo');
    await Future<void>.delayed(Duration.zero);
  });
}
