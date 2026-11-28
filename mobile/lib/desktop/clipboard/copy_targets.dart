// Where Control C (Command C on macOS) copies on a computer: the viewer shown copies its photo or video, a grid shown
// its selection (lib/desktop/selection). Each registers here while it is built; the shell (DesktopShell) asks the one
// in front, never under a dialog or a menu, and never while a text field has the keyboard, which keeps its own copy.

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

/// A page that Control C copies from
abstract interface class DesktopCopyTarget {
  /// Whether it is the one shown: its route on top, its tab the active one
  bool get isFront;

  /// Copies what it shows or what is selected in it; nothing when nothing is
  Future<void> copy();
}

/// The pages that can copy now; the one in front gets Control C
abstract final class DesktopCopyTargets {
  static final List<DesktopCopyTarget> _targets = [];

  static void register(DesktopCopyTarget target) {
    _targets
      ..remove(target)
      ..add(target);
  }

  static void unregister(DesktopCopyTarget target) => _targets.remove(target);

  /// The page shown, the last one registered when two are
  static DesktopCopyTarget? get active => _targets.reversed.firstWhereOrNull((target) => target.isFront);

  @visibleForTesting
  static int get length => _targets.length;
}
