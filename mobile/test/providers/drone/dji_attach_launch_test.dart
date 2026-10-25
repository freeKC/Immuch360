// The plug of a DJI remote that brought the app forward: the decision reads the whole stack of the root router, so that
// a plug answered while the live screen is open opens nothing more, then or after the pilot leaves it (review of 24
// October 2026, finding 1).

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_tile.widget.dart';
import 'package:immich_mobile/providers/drone/dji_attach_launch.provider.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/routing/router.dart';

import '../../presentation/pages/drone/dji_link_fakes.dart';

void main() {
  test('the app still on its start waits for the router', () {
    expect(djiAttachLaunchStep(const []), DjiAttachLaunchStep.wait);
    expect(djiAttachLaunchStep([SplashScreenRoute.name]), DjiAttachLaunchStep.wait);
    expect(djiAttachLaunchStep([LoginRoute.name]), DjiAttachLaunchStep.wait);
  });

  test('past the start with no live screen, the live screen opens', () {
    expect(djiAttachLaunchStep([TabShellRoute.name]), DjiAttachLaunchStep.open);
    // The tab shell under another page is still past the start: the router does not call it active, the stack does
    expect(djiAttachLaunchStep([TabShellRoute.name, NetworkSharesRoute.name]), DjiAttachLaunchStep.open);
  });

  test('a live screen anywhere in the stack ends the plug, visible or under Diagnostics', () {
    expect(
      djiAttachLaunchStep([TabShellRoute.name, NetworkSharesRoute.name, DjiLiveRoute.name]),
      DjiAttachLaunchStep.done,
    );
    expect(
      djiAttachLaunchStep([TabShellRoute.name, NetworkSharesRoute.name, DjiLiveRoute.name, DjiLinkRoute.name]),
      DjiAttachLaunchStep.done,
    );
  });

  group('the entry for the cable, told at each start and resume', () {
    /// What the native side is told when the app comes to the front
    Future<List<bool>> told({required bool enabled, required bool receiverOnly, bool supported = true}) async {
      final api = FakeDjiLinkApi();
      final container = ProviderContainer(
        overrides: [
          djiLinkApiProvider.overrideWithValue(api),
          djiLinkSupportedProvider.overrideWithValue(supported),
          djiLinkEnabledProvider.overrideWithValue(enabled),
          djiReceiverOnlyProvider.overrideWithValue(receiverOnly),
          isHorizonOsProvider.overrideWith((ref) async => receiverOnly),
        ],
      );
      addTearDown(container.dispose);
      await container.read(djiAttachLaunchProvider).check();
      return api.liveSettingSets;
    }

    test('a phone with the DJI live video on offers it: by default the first plug opens the live screen', () async {
      expect(await told(enabled: true, receiverOnly: false), [true]);
    });

    test('with the DJI live video off, or on a TV or the Quest, which only watch, it is never offered', () async {
      expect(await told(enabled: false, receiverOnly: false), [false]);
      expect(await told(enabled: true, receiverOnly: true), [false]);
    });

    test('off Android, where there is no DJI link, nothing is told at each start and resume', () async {
      expect(await told(enabled: false, receiverOnly: false, supported: false), isEmpty);
    });
  });
}
