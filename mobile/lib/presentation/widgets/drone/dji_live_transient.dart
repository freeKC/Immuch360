// The warnings drawn over the drone's picture come and go (FreeKC's rule of 25 October): "Watching only", the observer
// rule, the state of the reception, "Look at the drone and fly with the remote", "This device cannot keep up" and the
// like appear, stay five seconds and fade out. A key or a tap brings them back for five seconds, and a warning that
// changes kind shows again by itself. What stays: the flight values, the delay line, the safety notice of the session
// (it is a dialog, read once) and an error that needs an action until it is resolved, among them the one line that says
// no picture shows while the picture is missing. Nothing here reaches the remote or the drone.

import 'dart:async';

import 'package:flutter/material.dart';

/// A warning fades in over this, when it appears or comes back
const djiTransientFadeIn = Duration(milliseconds: 250);

/// A warning is shown this long in all, its fade in included
const djiTransientHold = Duration(seconds: 5);

/// Then it fades out over this
const djiTransientFadeOut = Duration(milliseconds: 800);

/// The opacity of a warning [since] it was last shown (it appeared, changed kind, or a key or a tap brought it back):
/// 0 to 1 over [djiTransientFadeIn], 1 until [djiTransientHold], 1 to 0 over [djiTransientFadeOut], then 0. [keep]: an
/// error that needs an action, always 1.
double djiTransientOpacity(Duration since, {bool keep = false}) {
  if (keep) {
    return 1;
  }
  final ms = since.inMicroseconds / 1000;
  final fadeIn = djiTransientFadeIn.inMilliseconds;
  final hold = djiTransientHold.inMilliseconds;
  final fadeOut = djiTransientFadeOut.inMilliseconds;
  if (ms < 0) {
    return 0;
  }
  if (ms < fadeIn) {
    return ms / fadeIn;
  }
  if (ms <= hold) {
    return 1;
  }
  if (ms < hold + fadeOut) {
    return 1 - (ms - hold) / fadeOut;
  }
  return 0;
}

/// A warning shows again by itself when its kind changes ("connecting" to "lost", a picture that stops), not when a
/// number in it changes ("trying again in 3.2 s", then 3.1 s)
bool djiTransientShowsAgain(Object? before, Object? now) => before != now;

/// What brings the warnings of a screen back: a key on a TV or a tap on a phone or in the Quest's window calls
/// [recall]. Every [DjiTransient] under a [DjiTransientScope] with this hears it.
class DjiTransientRecall extends ChangeNotifier {
  int _count = 0;

  /// How many times the warnings were brought back, for the tests
  int get count => _count;

  void recall() {
    _count += 1;
    notifyListeners();
  }
}

/// The screen's [DjiTransientRecall], for the warnings under it
class DjiTransientScope extends InheritedNotifier<DjiTransientRecall> {
  const DjiTransientScope({super.key, required DjiTransientRecall recall, required super.child})
    : super(notifier: recall);

  static DjiTransientRecall? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DjiTransientScope>()?.notifier;
}

/// A warning that comes and goes, as [djiTransientOpacity] says: shown for [djiTransientHold], faded out, then gone
/// from the layout ([collapse]) so that the plate under it shrinks; back when [kind] changes or the screen's recall is
/// called. Brought back while it fades, it goes back to full from where it is, never from nothing, and stays
/// [djiTransientHold] from then. [keep] holds it.
class DjiTransient extends StatefulWidget {
  const DjiTransient({super.key, required this.kind, required this.child, this.keep = false, this.collapse = true});

  /// What the warning says, in kind: a new kind shows it again
  final Object? kind;
  final Widget child;

  /// An error that needs an action: it stays until resolved
  final bool keep;

  /// Once faded out, it takes no room
  final bool collapse;

  @override
  State<DjiTransient> createState() => _DjiTransientState();
}

class _DjiTransientState extends State<DjiTransient> with SingleTickerProviderStateMixin {
  late final AnimationController _fade;
  Timer? _hold;
  DjiTransientRecall? _recall;
  int _recalls = 0;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(vsync: this, duration: djiTransientFadeIn, reverseDuration: djiTransientFadeOut)
      ..addStatusListener((status) {
        if (status == AnimationStatus.dismissed && mounted && !widget.keep && !_gone) {
          setState(() => _gone = true);
        }
      });
    if (widget.keep) {
      _fade.value = 1;
    } else {
      _show();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final recall = DjiTransientScope.of(context);
    if (!identical(recall, _recall)) {
      _recall = recall;
      _recalls = recall?.count ?? 0;
    } else if (recall != null && recall.count != _recalls) {
      // The scope rebuilt this warning because a key or a tap brought the warnings back
      _recalls = recall.count;
      if (!widget.keep) {
        _show();
      }
    }
  }

  @override
  void didUpdateWidget(DjiTransient oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.keep) {
      _hold?.cancel();
      _fade.value = 1;
      _gone = false;
    } else if (oldWidget.keep || djiTransientShowsAgain(oldWidget.kind, widget.kind)) {
      _show();
    }
  }

  @override
  void dispose() {
    _hold?.cancel();
    _fade.dispose();
    super.dispose();
  }

  /// In from where it is, then out after [djiTransientHold]
  void _show() {
    _gone = false;
    _hold?.cancel();
    _hold = Timer(djiTransientHold, () {
      if (mounted && !widget.keep) {
        unawaited(_fade.reverse());
      }
    });
    unawaited(_fade.forward());
  }

  @override
  Widget build(BuildContext context) {
    if (_gone && widget.collapse) {
      return const SizedBox.shrink();
    }
    return FadeTransition(opacity: _fade, child: widget.child);
  }
}
