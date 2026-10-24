// The plug of a DJI remote that brought the app forward: the decision reads the whole stack of the root router, so that
// a plug answered while the live screen is open opens nothing more, then or after the pilot leaves it (review of 24
// October 2026, finding 1).

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/providers/drone/dji_attach_launch.provider.dart';
import 'package:immich_mobile/routing/router.dart';

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
}
