import 'package:flutter/material.dart';

/// The Back button of the app bar of a page whose PopScope keeps the Back key of a remote for its own overlays (the
/// controls, the app bar that has the focus): the default button goes through Navigator.maybePop, which that PopScope
/// takes for the Back key, so OK on the button would not leave the page. This one leaves it. Null where the app bar
/// would show none (a page nothing is under), the close button of a full screen dialog where it would show that.
Widget? remoteBackButton(BuildContext context) {
  final route = ModalRoute.of(context);
  if (route == null || !route.impliesAppBarDismissal) {
    return null;
  }
  void leave() => Navigator.of(context).pop();
  return route.fullscreenDialog ? CloseButton(onPressed: leave) : BackButton(onPressed: leave);
}
