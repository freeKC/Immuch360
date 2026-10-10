// The signal a full screen player of the computers raises when its route closes (desktop design 1.3).
//
// On a phone the viewer's player is suspended while the native 360° player is open and comes back on
// AppLifecycleState.resumed, which closing that player brings about. On a computer the 360° player is a route of the
// window: closing it changes no lifecycle, and resumed comes instead at every focus change of the window, while the
// player may still be open. The viewer and the network page therefore end their suspension when this signal changes,
// with the code they run on resumed on a phone.

import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Counts the closings of the computers' full screen players: listeners react to each change
class ExternalPlayerClosed extends Notifier<int> {
  @override
  int build() => 0;

  /// A full screen player closed
  void raise() => state++;
}

final externalPlayerClosedProvider = NotifierProvider<ExternalPlayerClosed, int>(ExternalPlayerClosed.new);
