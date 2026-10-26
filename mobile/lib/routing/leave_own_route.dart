// Back on the safety notice of the drone pages leaves the page under the notice. A key pressed while that page opened
// could have opened another page over it (the Drone tile on the emulator, 26 October): a pop would close that one and
// leave the page under the notice there.

import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';

/// Takes the page of [context] out of its navigator, whether it is the top route or under another one. A page of the
/// router leaves the router's stack, which the navigator follows; any other route leaves its navigator.
void leaveOwnRoute(BuildContext context) {
  final route = ModalRoute.of(context);
  if (route == null || route.isCurrent) {
    Navigator.of(context).pop();
    return;
  }
  final page = route.settings;
  final router = page is AutoRoutePage ? page.routeData.router : null;
  if (page is AutoRoutePage && router is StackRouter) {
    router.removeRoute(page.routeData);
  } else {
    Navigator.of(context).removeRoute(route);
  }
}
